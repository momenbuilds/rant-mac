import Foundation

/// Audio, ready to transcribe.
public struct AudioBuffer: Equatable, Sendable {
  /// Raw little-endian signed 16-bit mono samples — the format every provider we
  /// support either wants directly or can convert from cheaply.
  public var pcm: Data
  public var sampleRate: Int

  public init(pcm: Data, sampleRate: Int = 16_000) {
    self.pcm = pcm
    self.sampleRate = sampleRate
  }

  /// Duration in milliseconds. 16-bit mono, so two bytes per sample.
  public var durationMilliseconds: Int {
    guard sampleRate > 0 else { return 0 }
    return (pcm.count / 2) * 1000 / sampleRate
  }

  public var isEmpty: Bool { pcm.count < 2 }
}

/// The result of transcribing one utterance.
public struct TranscriptionResult: Equatable, Sendable {
  /// What was actually said, as the model heard it. Never rewritten.
  public var raw: String
  /// The provider's cleaned-up version, when it produced one. Nil means the caller
  /// should apply its own cleanup to `raw`.
  public var cleaned: String?
  /// Identifier of the provider that produced this, for the history row.
  public var provider: String
  /// Detected or configured language, when the provider reports one.
  public var language: String?
  /// Milliseconds from request start to usable result.
  public var latencyMilliseconds: Int?
  /// Set when a requested server-side cleanup failed but the verbatim text is still
  /// good — degraded, not broken.
  public var cleanupFailure: String?

  public init(
    raw: String,
    cleaned: String? = nil,
    provider: String,
    language: String? = nil,
    latencyMilliseconds: Int? = nil,
    cleanupFailure: String? = nil
  ) {
    self.raw = raw
    self.cleaned = cleaned
    self.provider = provider
    self.language = language
    self.latencyMilliseconds = latencyMilliseconds
    self.cleanupFailure = cleanupFailure
  }

  /// The text to work with: the provider's cleanup if it produced usable output,
  /// otherwise the verbatim transcript. Whitespace-only cleanup counts as unusable —
  /// a blank rewrite must never throw away a good transcript.
  public var best: String {
    if let cleaned, !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return cleaned
    }
    return raw
  }

  public var isEmpty: Bool {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (cleaned?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }
}

/// What a request asks the provider to do beyond "transcribe this".
public struct TranscriptionOptions: Equatable, Sendable {
  public var cleanupLevel: CleanupLevel
  /// Extra style instruction appended to the cleanup instruction — the active
  /// writing style's wording.
  public var styleInstruction: String?
  /// BCP-47 language code, or nil to let the provider detect.
  public var languageCode: String?
  /// Turns off any server-side rewrite even when the level would request one; used
  /// when the user has chosen to do cleanup locally.
  public var allowProviderCleanup: Bool

  public init(
    cleanupLevel: CleanupLevel = .medium,
    styleInstruction: String? = nil,
    languageCode: String? = nil,
    allowProviderCleanup: Bool = true
  ) {
    self.cleanupLevel = cleanupLevel
    self.styleInstruction = styleInstruction
    self.languageCode = languageCode
    self.allowProviderCleanup = allowProviderCleanup
  }

  public static let `default` = TranscriptionOptions()
}

/// Anything that can turn recorded audio into text.
public protocol TranscriptionProvider: Sendable {
  /// Stable identifier stored on history rows, e.g. `assemblyai`.
  var identifier: String { get }
  var displayName: String { get }
  /// True when using this provider sends audio off the machine. Drives the privacy
  /// indicator, and drives the refusal in local-only mode.
  var sendsAudioOffDevice: Bool { get }
  /// Longest single utterance this provider accepts, if it has a limit.
  var maximumUtteranceSeconds: Int? { get }

  func transcribe(
    _ audio: AudioBuffer,
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionResult

  /// Called when recording *starts*, so a provider can pay connection setup before
  /// there is audio to send. Optional; the default does nothing.
  func warmUp() async

  /// A cheap round trip that proves credentials and reachability, for the
  /// "Test connection" button in settings.
  func checkReachability() async throws
}

extension TranscriptionProvider {
  public func warmUp() async {}
  public var maximumUtteranceSeconds: Int? { nil }
}

/// A partial result from a provider that streams.
public struct TranscriptionPartial: Equatable, Sendable {
  public var text: String
  /// True when the provider considers this turn settled.
  public var isFinal: Bool

  public init(text: String, isFinal: Bool) {
    self.text = text
    self.isFinal = isFinal
  }
}

/// A provider that can emit text while the user is still speaking.
///
/// Kept separate from `TranscriptionProvider` because streaming is genuinely
/// optional: the local provider does not do it, and the overlay must work without
/// it. See `docs/DECISIONS.md` D-003 for why Rant can run both a streaming provider
/// for display and a synchronous one for the final text.
public protocol StreamingTranscriptionProvider: Sendable {
  var identifier: String { get }

  /// Opens a session. Audio is pushed in through the returned handle; partials come
  /// out of the stream. Cancelling the task closes the session.
  func stream(
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionStream
}

/// A live transcription session.
public struct TranscriptionStream: Sendable {
  public let partials: AsyncThrowingStream<TranscriptionPartial, Error>
  /// Push audio. Safe to call from the capture callback.
  public let send: @Sendable (Data) async -> Void
  /// Politely end the session so the provider stops billing and flushes its last turn.
  public let finish: @Sendable () async -> Void

  public init(
    partials: AsyncThrowingStream<TranscriptionPartial, Error>,
    send: @escaping @Sendable (Data) async -> Void,
    finish: @escaping @Sendable () async -> Void
  ) {
    self.partials = partials
    self.send = send
    self.finish = finish
  }
}

/// Errors any provider can raise, in the words the UI shows the user.
public enum TranscriptionError: Error, Equatable, LocalizedError {
  case apiKeyMissing
  case unauthorized
  case rateLimited
  case audioTooLong(seconds: Int, limit: Int)
  case audioEmpty
  case network(String)
  case http(status: Int, message: String?)
  case malformedResponse
  case cancelled
  case modelUnavailable(String)
  /// The user chose local-only and something asked to go to the network.
  case localOnlyViolation(provider: String)

  public var errorDescription: String? {
    switch self {
    case .apiKeyMissing:
      "No API key yet. Add one in Settings → Speech."
    case .unauthorized:
      "That API key was rejected. Check it in Settings → Speech."
    case .rateLimited:
      "Your speech provider is rate limiting. Try again in a moment."
    case .audioTooLong(let seconds, let limit):
      "That was \(seconds)s and the limit is \(limit)s. Try shorter takes, or switch on streaming."
    case .audioEmpty:
      "Nothing was recorded."
    case .network(let detail):
      "Could not reach the speech provider. \(detail)"
    case .http(let status, let message):
      message.map { "Speech provider error \(status): \($0)" } ?? "Speech provider error \(status)."
    case .malformedResponse:
      "The speech provider sent something unreadable."
    case .cancelled:
      "Cancelled."
    case .modelUnavailable(let name):
      "The local model \(name) is not downloaded yet."
    case .localOnlyViolation(let provider):
      "\(provider) needs the network, and Rant is set to local only. Nothing was sent."
    }
  }

  /// Whether offering "Retry" makes sense — a bad key will not fix itself.
  public var isRetryable: Bool {
    switch self {
    case .network, .rateLimited, .http, .malformedResponse: true
    case .apiKeyMissing, .unauthorized, .audioTooLong, .audioEmpty, .cancelled,
      .modelUnavailable, .localOnlyViolation:
      false
    }
  }
}
