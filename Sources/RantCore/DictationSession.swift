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
  /// Chooses the writing style from where the user is typing.
  ///
  /// Carried as a resolver rather than a resolved instruction because the decision
  /// depends on the app and site, and those are only known once the context has been
  /// captured — which happens inside the session, after these settings were built.
  /// While this was nil the Styles screen had no effect on anything.
  public var styleResolver: StyleResolver?

  /// Chooses the whole pipeline shape from where the user is typing.
  ///
  /// A mode overrides the settings it names and leaves the rest alone, which is why it
  /// is applied here rather than merged into preferences: "Terminal mode uses no
  /// cleanup" should not permanently change the user's cleanup setting.
  public var modeResolver: ModeResolver?

  /// Applies `mode`'s configuration over these settings.
  ///
  /// Only the fields the mode actually specifies. A mode with no `styleName` must not
  /// clear a style the resolver would otherwise have chosen — an override that also
  /// silently unsets everything it does not mention is not an override.
  func applying(_ mode: Mode) -> DictationSettings {
    var copy = self
    let configuration = mode.configuration
    copy.cleanupLevel = configuration.cleanupLevel
    copy.contextSettings = configuration.contextSettings
    if let language = configuration.languageCode { copy.languageCode = language }
    if let styleName = configuration.styleName,
      let style = styleResolver?.style(named: styleName)
    {
      copy.styleInstruction = style.instructions
    }
    // The mode's own prompt is appended rather than replacing the style, so a mode can
    // add an instruction without discarding the voice the user chose.
    if let prompt = configuration.prompt, !prompt.isEmpty {
      copy.styleInstruction = [copy.styleInstruction, prompt]
        .compactMap { $0 }
        .joined(separator: " ")
    }
    return copy
  }

  public init(
    cleanupLevel: CleanupLevel = .medium,
    styleInstruction: String? = nil,
    languageCode: String? = nil,
    preferLocalCleanup: Bool = false,
    localOnly: Bool = false,
    contextSettings: ContextSettings = .default,
    retainAudio: Bool = false,
    styleResolver: StyleResolver? = nil,
    modeResolver: ModeResolver? = nil
  ) {
    self.styleResolver = styleResolver
    self.modeResolver = modeResolver
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
  /// The mode this recording is running under, decided when it started.
  private var activeMode: Mode?
  private var startedAt: ContinuousClock.Instant?

  /// Observers for the overlay.
  private var stateObservers: [@Sendable (DictationState) -> Void] = []
  private var partialObservers: [@Sendable (String) -> Void] = []

  /// Optional live transcription, for the words-as-you-speak preview.
  ///
  /// Separate from `transcriber` because streaming is genuinely optional: the
  /// on-device engine does not stream, and the overlay has to work without it. When
  /// present it drives the preview only — the final text still comes from the
  /// synchronous provider, so a dropped websocket costs a preview rather than a
  /// dictation.
  private let streamer: (any StreamingTranscriptionProvider)?
  private var liveStream: TranscriptionStream?
  private var streamPump: Task<Void, Never>?
  private var partialReader: Task<Void, Never>?
  /// Audio already handed to the stream. Kept because draining the capture for the
  /// stream would otherwise take those samples out of the final recording.
  private var streamedAudio = Data()

  public init(
    audio: any AudioCaptureProvider,
    transcriber: any TranscriptionProvider,
    injector: any TextInjector,
    context: any ContextProvider = StaticContextProvider(.empty),
    store: (any TranscriptStore)? = nil,
    enhancer: (any EnhancementProvider)? = nil,
    vocabulary: VocabularyApplier = VocabularyApplier(),
    streamer: (any StreamingTranscriptionProvider)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.audio = audio
    self.transcriber = transcriber
    self.injector = injector
    self.context = context
    self.store = store
    self.enhancer = enhancer
    self.vocabulary = vocabulary
    self.streamer = streamer
    self.now = now
  }

  /// Called with interim text while the user is still speaking.
  public func observePartials(_ observer: @escaping @Sendable (String) -> Void) {
    partialObservers.append(observer)
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
    var captured = await context.capture(settings: captureSettings)

    // Which mode applies is decided from the app and site, and a mode can carry its
    // own context rules. Those rules have to govern what is *collected*, not merely
    // what is used, so when they differ the context is captured again under them —
    // otherwise "this mode reads nothing about what I am doing" would be a claim about
    // a value that had already been gathered.
    activeMode = settings.modeResolver?.resolve(context: captured)
    if let mode = activeMode, mode.configuration.contextSettings != captureSettings {
      captured = await context.capture(settings: mode.configuration.contextSettings)
    }
    capturedContext = captured

    if !settings.localOnly {
      await transcriber.warmUp()
      await openLiveStream(settings: settings)
    }
  }

  // MARK: - Live preview

  /// Opens the streaming session and starts pumping audio into it.
  ///
  /// Entirely best-effort. Every failure path here leaves the dictation working: the
  /// user loses the words-as-they-speak preview and still gets their transcript from
  /// the synchronous provider at the end.
  private func openLiveStream(settings: DictationSettings) async {
    guard let streamer else { return }
    streamedAudio = Data()
    do {
      let stream = try await streamer.stream(
        context: capturedContext,
        options: TranscriptionOptions(
          cleanupLevel: settings.cleanupLevel,
          languageCode: settings.languageCode))
      liveStream = stream

      partialReader = Task { [weak self] in
        do {
          for try await partial in stream.partials {
            await self?.emit(partial: partial.text)
          }
        } catch {
          await self?.noteStreamFailure(error)
        }
      }

      streamPump = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled else { return }
          await self?.pumpAudioToStream()
        }
      }
    } catch {
      log.warning("live preview unavailable: \(error.localizedDescription)")
      liveStream = nil
    }
  }

  private func pumpAudioToStream() async {
    guard let liveStream, state == .listening else { return }
    let chunk = await audio.drain()
    guard !chunk.isEmpty else { return }
    // Kept, because draining took these samples out of what `stop()` will return.
    streamedAudio.append(chunk.pcm)
    await liveStream.send(chunk.pcm)
  }

  private func emit(partial: String) {
    guard !partial.isEmpty else { return }
    for observer in partialObservers { observer(partial) }
  }

  private func noteStreamFailure(_ error: any Error) {
    log.warning("live preview ended: \(error.localizedDescription)")
    liveStream = nil
  }

  /// Ends the streaming session and returns the audio it consumed, so the final
  /// transcription still sees the whole recording.
  private func closeLiveStream() async -> Data {
    // Nothing streamed, nothing to reclaim. Without this the capture is drained on
    // every dictation even with no streaming provider, which happens to work only
    // because the drained bytes are put back a line later — the sort of accident that
    // survives until somebody reorders two statements.
    guard liveStream != nil || !streamedAudio.isEmpty else { return Data() }
    streamPump?.cancel()
    streamPump = nil
    // Anything recorded since the last pump belongs to the recording too.
    let remainder = await audio.drain()
    streamedAudio.append(remainder.pcm)
    await liveStream?.finish()
    partialReader?.cancel()
    partialReader = nil
    liveStream = nil
    let consumed = streamedAudio
    streamedAudio = Data()
    return consumed
  }

  /// Stop capturing and run the rest of the pipeline.
  @discardableResult
  public func stopAndTranscribe(settings: DictationSettings = .default) async -> DictationOutcome? {
    guard state == .listening else { return nil }
    // Order matters: the stream is closed first so the samples it consumed come back
    // and can be put in front of whatever is left. Reversing these two lines silently
    // truncates every dictation to its last quarter-second.
    let streamed = await closeLiveStream()
    let tail = await audio.stop()
    let buffer =
      streamed.isEmpty
      ? tail
      : AudioBuffer(pcm: streamed + tail.pcm, sampleRate: tail.sampleRate)
    return await run(buffer: buffer, context: capturedContext, settings: settings)
  }

  /// Throw the recording away. Nothing is transcribed, stored, or inserted.
  public func cancel() async {
    currentTask?.cancel()
    currentTask = nil
    // Terminate the streaming session properly rather than dropping the socket: a
    // provider that is billing by the second keeps billing until it times out.
    _ = await closeLiveStream()
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
    buffer: AudioBuffer, context capturedContext: TranscriptionContext,
    settings incoming: DictationSettings
  ) async -> DictationOutcome? {
    var latency = LatencyBreakdown()
    let began = ContinuousClock.now

    // The mode chosen at the start of the recording, not re-resolved here. A mode that
    // switched off context capture would otherwise leave an empty context that resolves
    // to a *different* mode, and the dictation would run under rules the user never
    // selected.
    let mode = activeMode ?? incoming.modeResolver?.resolve(context: capturedContext)
    let settings = mode.map { incoming.applying($0) } ?? incoming
    if let mode { log.info("mode: \(mode.name)") }

    // A recording with nothing in it should not cost a network request or produce an
    // empty history row.
    guard !AudioMath.isEffectivelySilent(buffer) else {
      log.info("recording was silent; nothing to transcribe")
      setState(.idle)
      return nil
    }

    setState(.transcribing)
    // The style depends on where the user is typing, so it can only be chosen once the
    // context has been captured — which is here, not when the settings were assembled.
    // An explicit `styleInstruction` still wins: that is the one-off override.
    let style = settings.styleInstruction ?? settings.styleResolver?
      .resolve(context: capturedContext).instructions
    let options = TranscriptionOptions(
      cleanupLevel: settings.cleanupLevel,
      styleInstruction: style,
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
        InjectionRequest(
          text: finalText,
          target: mode?.configuration.outputTarget ?? .cursor,
          context: capturedContext))
      log.info("injection: \(String(describing: injection))")
      // Auto-send is the mode's, and deliberately after a successful injection: a
      // Return pressed when nothing was inserted sends whatever was already there.
      if mode?.configuration.autoSend == true {
        await injector.pressReturn()
      }
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
