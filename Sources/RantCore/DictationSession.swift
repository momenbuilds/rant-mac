import Foundation

/// What the overlay is showing.
public enum DictationState: Equatable, Sendable {
  case idle
  case listening
  case transcribing
  case enhancing
  case inserting
  case success(String)
  case failure(String, retryable: Bool)
  case cancelled

  public var isBusy: Bool {
    switch self {
    case .listening, .transcribing, .enhancing, .inserting: true
    case .idle, .success, .failure, .cancelled: false
    }
  }
}

/// Per-stage timing, for the diagnostics view. Never shown in normal use — a
/// dictation app that reports its own latency at you is a dictation app you notice,
/// and the goal is to not be noticed.
public struct LatencyBreakdown: Equatable, Sendable {
  public var captureStartMs: Int?
  public var transcriptionMs: Int?
  public var enhancementMs: Int?
  public var injectionMs: Int?
  public var totalMs: Int?

  public init() {}

  public var stages: [(String, Int)] {
    [
      ("capture start", captureStartMs), ("transcription", transcriptionMs),
      ("enhancement", enhancementMs), ("injection", injectionMs), ("total", totalMs),
    ].compactMap { name, value in value.map { (name, $0) } }
  }
}

/// Everything one dictation produced.
public struct DictationOutcome: Equatable, Sendable {
  public var transcript: Transcript
  public var injection: InjectionOutcome
  public var latency: LatencyBreakdown
}

/// How the pipeline is configured for a given dictation.
public struct DictationSettings: Equatable, Sendable {
  public var cleanupLevel: CleanupLevel
  public var styleInstruction: String?
  public var languageCode: String?
  /// When true, cleanup happens locally and the provider is asked not to rewrite.
  public var preferLocalCleanup: Bool
  /// Refuse anything that would send audio off the machine.
  public var localOnly: Bool
  public var contextSettings: ContextSettings
  public var retainAudio: Bool

  public init(
    cleanupLevel: CleanupLevel = .medium,
    styleInstruction: String? = nil,
    languageCode: String? = nil,
    preferLocalCleanup: Bool = false,
    localOnly: Bool = false,
    contextSettings: ContextSettings = .default,
    retainAudio: Bool = false
  ) {
    self.cleanupLevel = cleanupLevel
    self.styleInstruction = styleInstruction
    self.languageCode = languageCode
    self.preferLocalCleanup = preferLocalCleanup
    self.localOnly = localOnly
    self.contextSettings = contextSettings
    self.retainAudio = retainAudio
  }

  public static let `default` = DictationSettings()
}

/// Runs one dictation from key press to inserted text.
///
/// An actor, because the sequence must not interleave: pressing the trigger twice in
/// quick succession, or cancelling while a transcript is in flight, has to produce
/// one coherent outcome rather than two half-finished ones.
///
/// Every collaborator is a protocol, so the whole pipeline runs in tests with a
/// fixture microphone, a scripted transcriber and a recording injector — no network,
/// no permissions, no audio hardware.
public actor DictationSession {
  private let audio: any AudioCaptureProvider
  private let transcriber: any TranscriptionProvider
  private let injector: any TextInjector
  private let context: any ContextProvider
  private let store: (any TranscriptStore)?
  private let cleaner = TranscriptCleaner()
  private let classifier = SurfaceClassifier()
  private let enhancer: (any EnhancementProvider)?
  private let vocabulary: VocabularyApplier
  private let log = RantLog("Session")
  private let now: @Sendable () -> Date

  public private(set) var state: DictationState = .idle
  /// The most recent successful text, for "paste last".
  public private(set) var lastSuccessfulText: String?
  /// The audio and context of the last failure, so Retry does not need the user to
  /// say it again.
  private var lastFailure: (audio: AudioBuffer, context: TranscriptionContext)?

  private var currentTask: Task<DictationOutcome?, Never>?
  private var capturedContext: TranscriptionContext = .empty
  private var startedAt: ContinuousClock.Instant?

  /// Observers for the overlay.
  private var stateObservers: [@Sendable (DictationState) -> Void] = []

  public init(
    audio: any AudioCaptureProvider,
    transcriber: any TranscriptionProvider,
    injector: any TextInjector,
    context: any ContextProvider = StaticContextProvider(.empty),
    store: (any TranscriptStore)? = nil,
    enhancer: (any EnhancementProvider)? = nil,
    vocabulary: VocabularyApplier = VocabularyApplier(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.audio = audio
    self.transcriber = transcriber
    self.injector = injector
    self.context = context
    self.store = store
    self.enhancer = enhancer
    self.vocabulary = vocabulary
    self.now = now
  }

  public func observeState(_ observer: @escaping @Sendable (DictationState) -> Void) {
    stateObservers.append(observer)
    observer(state)
  }

  private func setState(_ new: DictationState) {
    state = new
    for observer in stateObservers { observer(new) }
  }

  // MARK: - The loop

  /// Begin capturing. Returns as soon as audio is running — the caller (the hotkey
  /// engine) must not be kept waiting, because the overlay is waiting on it.
  public func start(settings: DictationSettings = .default) async {
    guard !state.isBusy else { return }
    startedAt = ContinuousClock.now

    if settings.localOnly, transcriber.sendsAudioOffDevice {
      setState(.failure(
        TranscriptionError.localOnlyViolation(provider: transcriber.displayName)
          .localizedDescription, retryable: false))
      return
    }

    do {
      try await audio.start()
      setState(.listening)
    } catch {
      setState(.failure(error.localizedDescription, retryable: false))
      return
    }

    // Context capture and connection warm-up happen *after* audio is running, so
    // neither can delay the first sample. Both are best-effort.
    let captureSettings = settings.contextSettings
    capturedContext = await context.capture(settings: captureSettings)
    if !settings.localOnly {
      await transcriber.warmUp()
    }
  }

  /// Stop capturing and run the rest of the pipeline.
  @discardableResult
  public func stopAndTranscribe(settings: DictationSettings = .default) async -> DictationOutcome? {
    guard state == .listening else { return nil }
    let buffer = await audio.stop()
    return await run(buffer: buffer, context: capturedContext, settings: settings)
  }

  /// Throw the recording away. Nothing is transcribed, stored, or inserted.
  public func cancel() async {
    currentTask?.cancel()
    currentTask = nil
    await audio.cancel()
    setState(.cancelled)
    setState(.idle)
  }

  /// Re-run the last failed dictation without asking the user to repeat themselves.
  @discardableResult
  public func retryLast(settings: DictationSettings = .default) async -> DictationOutcome? {
    guard let failure = lastFailure else { return nil }
    return await run(buffer: failure.audio, context: failure.context, settings: settings)
  }

  /// Put the most recent successful transcript back on the clipboard / at the cursor.
  @discardableResult
  public func pasteLast() async -> InjectionOutcome? {
    guard let text = lastSuccessfulText else { return nil }
    return try? await injector.inject(InjectionRequest(text: text, context: nil))
  }

  // MARK: - Pipeline

  private func run(
    buffer: AudioBuffer, context capturedContext: TranscriptionContext, settings: DictationSettings
  ) async -> DictationOutcome? {
    var latency = LatencyBreakdown()
    let began = ContinuousClock.now

    // A recording with nothing in it should not cost a network request or produce an
    // empty history row.
    guard !AudioMath.isEffectivelySilent(buffer) else {
      log.info("recording was silent; nothing to transcribe")
      setState(.idle)
      return nil
    }

    setState(.transcribing)
    let options = TranscriptionOptions(
      cleanupLevel: settings.cleanupLevel,
      styleInstruction: settings.styleInstruction,
      languageCode: settings.languageCode,
      allowProviderCleanup: !settings.preferLocalCleanup)

    let result: TranscriptionResult
    do {
      let transcribeStart = ContinuousClock.now
      result = try await transcriber.transcribe(
        buffer, context: capturedContext, options: options)
      latency.transcriptionMs = Int((ContinuousClock.now - transcribeStart) / .milliseconds(1))
    } catch {
      // Keep the audio so Retry can reuse it. Losing a recording to a flaky network
      // is the failure users remember.
      lastFailure = (buffer, capturedContext)
      let retryable = (error as? TranscriptionError)?.isRetryable ?? true
      log.error("transcription failed (retryable: \(retryable))")
      setState(.failure(error.localizedDescription, retryable: retryable))
      return nil
    }

    guard !result.isEmpty else {
      log.info("provider returned nothing usable")
      setState(.idle)
      return nil
    }

    // Local cleanup runs when the provider did not clean, or when the user asked for
    // cleanup to stay on the machine.
    var finalText = result.best
    if settings.preferLocalCleanup || result.cleaned == nil {
      finalText = cleaner.clean(finalText, level: settings.cleanupLevel)
    }
    // Dictionary replacements and snippets are always local and always last, so they
    // win over whatever the model produced.
    finalText = vocabulary.apply(to: finalText)

    var enhanced = false
    if let enhancer, settings.cleanupLevel == .high {
      setState(.enhancing)
      let enhanceStart = ContinuousClock.now
      if let improved = try? await enhancer.enhance(
        finalText, instruction: settings.cleanupLevel.rewriteInstruction ?? "",
        context: capturedContext)
      {
        finalText = improved
        enhanced = true
      }
      latency.enhancementMs = Int((ContinuousClock.now - enhanceStart) / .milliseconds(1))
    }

    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      setState(.idle)
      return nil
    }

    setState(.inserting)
    let injectStart = ContinuousClock.now
    let injection: InjectionOutcome
    do {
      injection = try await injector.inject(
        InjectionRequest(text: finalText, context: capturedContext))
      log.info("injection: \(String(describing: injection))")
    } catch {
      log.error("injection failed: \(error.localizedDescription)")
      // The text exists and the user earned it — surface the failure but keep the
      // text available rather than discarding it.
      lastSuccessfulText = finalText
      setState(.failure(error.localizedDescription, retryable: false))
      return nil
    }
    latency.injectionMs = Int((ContinuousClock.now - injectStart) / .milliseconds(1))
    latency.totalMs = Int((ContinuousClock.now - began) / .milliseconds(1))

    let surface = classifier.classify(capturedContext)
    let transcript = Transcript(
      createdAt: now(),
      rawText: result.raw,
      finalText: finalText,
      provider: result.provider,
      language: result.language,
      cleanupLevel: settings.cleanupLevel,
      style: settings.styleInstruction == nil ? nil : "custom",
      appBundleID: capturedContext.appBundleID,
      appName: capturedContext.appName,
      browserHost: capturedContext.browserHost,
      category: surface.category,
      durationMilliseconds: buffer.durationMilliseconds,
      enhanced: enhanced)

    var stored = transcript
    if let store {
      stored = (try? store.save(transcript)) ?? transcript
    }

    lastSuccessfulText = finalText
    lastFailure = nil
    setState(.success(finalText))
    setState(.idle)
    log.shape("dictation complete", of: finalText)

    return DictationOutcome(transcript: stored, injection: injection, latency: latency)
  }
}
