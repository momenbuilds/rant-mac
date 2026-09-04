import Foundation
@testable import RantCore

/// A transcription provider that returns whatever the test says it should.
final class ScriptedTranscriber: TranscriptionProvider, @unchecked Sendable {
  let identifier = "scripted"
  let displayName = "Scripted"
  var sendsAudioOffDevice: Bool
  var maximumUtteranceSeconds: Int? { nil }

  private var results: [Result<TranscriptionResult, Error>]
  private let lock = NSLock()
  private(set) var receivedContexts: [TranscriptionContext?] = []
  private(set) var receivedOptions: [TranscriptionOptions] = []
  /// The audio each call was given, so a test can prove nothing was lost on the way.
  private(set) var receivedAudio: [AudioBuffer] = []
  private(set) var warmUpCount = 0

  init(_ results: [Result<TranscriptionResult, Error>], sendsAudioOffDevice: Bool = true) {
    self.results = results
    self.sendsAudioOffDevice = sendsAudioOffDevice
  }

  convenience init(raw: String, cleaned: String? = nil, sendsAudioOffDevice: Bool = true) {
    self.init(
      [.success(TranscriptionResult(raw: raw, cleaned: cleaned, provider: "scripted"))],
      sendsAudioOffDevice: sendsAudioOffDevice)
  }

  convenience init(failure: Error) {
    self.init([.failure(failure)])
  }

  func transcribe(
    _ audio: AudioBuffer, context: TranscriptionContext?, options: TranscriptionOptions
  ) async throws -> TranscriptionResult {
    let result: Result<TranscriptionResult, Error> = lock.withLock {
      receivedContexts.append(context)
      receivedOptions.append(options)
      receivedAudio.append(audio)
      if results.count > 1 { return results.removeFirst() }
      return results.first ?? .failure(TranscriptionError.malformedResponse)
    }
    return try result.get()
  }

  func warmUp() async { lock.withLock { warmUpCount += 1 } }
  func checkReachability() async throws {}
}
