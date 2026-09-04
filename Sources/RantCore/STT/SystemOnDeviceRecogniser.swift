import AVFoundation
import Foundation
import Speech

/// `OnDeviceRecognising` backed by the `Speech` framework, pinned to on-device.
///
/// Everything here is the boring half of `AppleSpeechProvider`: format conversion and
/// the callback-to-async bridge. The one line that carries the privacy promise is
/// `request.requiresOnDeviceRecognition = true`, together with the check that the
/// recogniser actually supports it — set the flag on a recogniser that does not, and
/// the framework fails the request rather than going to the network, which is the
/// behaviour we want but not a thing to rely on silently.
public final class SystemOnDeviceRecogniser: OnDeviceRecognising, @unchecked Sendable {
  private let log = RantLog("AppleSpeech")

  public init() {}

  private func recogniser(for languageCode: String?) -> SFSpeechRecognizer? {
    // A bare language code ("en") is a valid locale identifier, so the caller does not
    // have to know about regions to ask for English.
    let locale = languageCode.map(Locale.init(identifier:)) ?? Locale.current
    return SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
  }

  public func supportsOnDeviceRecognition(languageCode: String?) async -> Bool {
    guard let recogniser = recogniser(for: languageCode) else { return false }
    return recogniser.supportsOnDeviceRecognition && recogniser.isAvailable
  }

  public func authorizationStatus() async -> SpeechAuthorization {
    Self.map(SFSpeechRecognizer.authorizationStatus())
  }

  public func requestAuthorization() async -> SpeechAuthorization {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: Self.map(status))
      }
    }
  }

  private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorization {
    switch status {
    case .authorized: .authorized
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .undetermined
    @unknown default: .denied
    }
  }

  public func transcribeOnDevice(
    pcm16: Data, sampleRate: Int, languageCode: String?
  ) async throws -> String {
    guard let recogniser = recogniser(for: languageCode), recogniser.isAvailable else {
      throw TranscriptionError.onDeviceRecognitionUnavailable(languageCode ?? "this language")
    }
    guard recogniser.supportsOnDeviceRecognition else {
      throw TranscriptionError.onDeviceRecognitionUnavailable(languageCode ?? "this language")
    }
    guard let buffer = Self.buffer(from: pcm16, sampleRate: sampleRate) else {
      throw TranscriptionError.audioEmpty
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    // Verbatim: Rant does its own cleanup, and a provider that silently punctuates
    // makes the cleanup levels a lie.
    request.taskHint = .dictation
    request.append(buffer)
    request.endAudio()

    return try await withCheckedThrowingContinuation { continuation in
      // The framework calls this handler more than once — a result, then completion —
      // and resuming a continuation twice traps. The box makes the first resume win.
      let settled = Settled()
      recogniser.recognitionTask(with: request) { result, error in
        if let result, result.isFinal {
          if settled.claim() {
            continuation.resume(returning: result.bestTranscription.formattedString)
          }
          return
        }
        if let error {
          if settled.claim() {
            continuation.resume(throwing: Self.translate(error))
          }
          return
        }
      }
    }
  }

  /// One-shot latch guarding the continuation.
  private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if taken { return false }
      taken = true
      return true
    }
  }

  /// The framework reports "no speech" as an error. That is not a failure the user
  /// should see as one — it is an empty recording, which Rant already has words for.
  private static func translate(_ error: Error) -> Error {
    let ns = error as NSError
    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
      return TranscriptionError.audioEmpty
    }
    if ns.code == NSUserCancelledError { return TranscriptionError.cancelled }
    return TranscriptionError.network(ns.localizedDescription)
  }

  /// Rant carries audio as little-endian signed 16-bit mono; the framework wants an
  /// `AVAudioPCMBuffer`. No resampling: the recogniser accepts the rate we captured at.
  static func buffer(from pcm16: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
    guard sampleRate > 0, pcm16.count >= 2 else { return nil }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1,
        interleaved: true)
    else { return nil }

    let frames = AVAudioFrameCount(pcm16.count / 2)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let destination = buffer.int16ChannelData
    else { return nil }
    buffer.frameLength = frames
    pcm16.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      destination[0].withMemoryRebound(to: UInt8.self, capacity: pcm16.count) { bytes in
        bytes.update(from: base.assumingMemoryBound(to: UInt8.self), count: pcm16.count)
      }
    }
    return buffer
  }

  /// Synchronous status for the Settings provider row. See
  /// `AppleSpeechProvider.status(authorization:supportsOnDevice:)`.
  public static func currentStatus(languageCode: String? = nil) -> ProviderStatus {
    let locale = languageCode.map(Locale.init(identifier:)) ?? Locale.current
    let recogniser = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    return AppleSpeechProvider.status(
      authorization: map(SFSpeechRecognizer.authorizationStatus()),
      supportsOnDevice: recogniser?.supportsOnDeviceRecognition ?? false)
  }
}
