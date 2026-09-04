import Foundation

/// Whether the user has let this Mac's speech recogniser be used at all.
public enum SpeechAuthorization: Equatable, Sendable {
  case authorized
  case denied
  case restricted
  case undetermined
}

/// The seam between `AppleSpeechProvider` and the `Speech` framework.
///
/// The provider's rules — refuse when on-device recognition is unavailable, never fall
/// back to a server — are the part worth testing, and they are testable only if the
/// framework is replaceable. The production conformer is `SystemOnDeviceRecogniser`.
public protocol OnDeviceRecognising: Sendable {
  /// Whether this Mac can run the recogniser for `languageCode` without a network.
  /// False on a locale whose on-device assets macOS has not installed.
  func supportsOnDeviceRecognition(languageCode: String?) async -> Bool
  func authorizationStatus() async -> SpeechAuthorization
  func requestAuthorization() async -> SpeechAuthorization

  /// Transcribe, on device, or throw. Conformers must never satisfy this over the
  /// network — `AppleSpeechProvider` advertises `sendsAudioOffDevice = false`, and that
  /// promise is only as good as this method.
  func transcribeOnDevice(
    pcm16: Data, sampleRate: Int, languageCode: String?
  ) async throws -> String
}

/// Speech-to-text using the recogniser built into macOS, with the network path
/// switched off.
///
/// This is the provider that makes "Local only" a usable mode rather than an off
/// switch. The master prompt (§7) requires at least one *practical* fully-local
/// provider, and the two obvious candidates both fail on the machine Rant is built on:
/// `SpeechAnalyzer` is Apple-Silicon only, and whisper.cpp means vendoring a C library
/// plus a model download the user must sit through before dictating even once. The
/// system recogniser needs neither — the assets are already on the Mac.
///
/// `LocalWhisperProvider` stays beside this one as the seam for whisper.cpp, for
/// somebody who wants a specific model. It is not the provider that ships working.
/// See `docs/DECISIONS.md` D-012.
///
/// The important property here is a negative one: when the recogniser cannot work on
/// device, this throws. It does not quietly let Apple's servers do it. A user who
/// picked the local provider has said something specific about where their voice may
/// go, and a silent server round trip would break that promise while the UI still
/// displayed "Audio stays on this Mac".
public struct AppleSpeechProvider: TranscriptionProvider {
  public let identifier = "apple-on-device"
  public var displayName: String { "On-device — macOS" }
  public let sendsAudioOffDevice = false
  /// No limit worth enforcing: nothing is uploaded and nobody bills per second.
  public let maximumUtteranceSeconds: Int? = nil

  private let recogniser: any OnDeviceRecognising
  private let log = RantLog("AppleSpeech")

  public init(recogniser: any OnDeviceRecognising) {
    self.recogniser = recogniser
  }

  public func transcribe(
    _ audio: AudioBuffer,
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionResult {
    guard !audio.isEmpty else { throw TranscriptionError.audioEmpty }
    try await ensureUsable(languageCode: options.languageCode)

    let started = Date()
    let text = try await recogniser.transcribeOnDevice(
      pcm16: audio.pcm, sampleRate: audio.sampleRate, languageCode: options.languageCode)
    let latency = Int(Date().timeIntervalSince(started) * 1000)

    // Length, never content: the transcript body must not reach the log.
    log.info("on-device transcript ok chars=\(text.count) latencyMs=\(latency)")

    return TranscriptionResult(
      raw: text,
      provider: identifier,
      language: options.languageCode,
      latencyMilliseconds: latency)
  }

  /// Settings → Speech "Test connection", for a provider with nothing to connect to:
  /// the real question is whether the recogniser is permitted and available on device.
  public func checkReachability() async throws {
    try await ensureUsable(languageCode: nil)
  }

  public func warmUp() async {
    _ = await recogniser.authorizationStatus()
  }

  /// The status the Settings row shows, without waiting on anything.
  ///
  /// `ProviderRegistry.Entry` asks for status synchronously, and both underlying
  /// questions — has permission been granted, are the on-device assets present — are
  /// synchronous in the framework too. So the row can say *why* the engine is not
  /// usable rather than claiming it is ready and then failing at the first dictation.
  public static func status(
    authorization: SpeechAuthorization, supportsOnDevice: Bool
  ) -> ProviderStatus {
    switch authorization {
    case .denied, .restricted:
      return .unavailable("macOS has not allowed Rant to use speech recognition.")
    case .authorized where !supportsOnDevice:
      return .unavailable("This Mac has no on-device speech model for your language.")
    case .authorized, .undetermined:
      // Undetermined is ready, not broken: choosing the engine is what asks the user.
      return .ready
    }
  }

  /// Both preconditions in one place, so `transcribe` and the settings test button can
  /// never disagree about what "ready" means.
  private func ensureUsable(languageCode: String?) async throws {
    var status = await recogniser.authorizationStatus()
    if status == .undetermined {
      status = await recogniser.requestAuthorization()
    }
    guard status == .authorized else {
      throw TranscriptionError.speechRecognitionDenied
    }
    guard await recogniser.supportsOnDeviceRecognition(languageCode: languageCode) else {
      throw TranscriptionError.onDeviceRecognitionUnavailable(
        languageCode ?? Locale.current.identifier)
    }
  }
}
