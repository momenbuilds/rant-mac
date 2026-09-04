import XCTest

@testable import RantCore

/// The on-device provider's job is mostly to refuse.
///
/// It advertises `sendsAudioOffDevice = false`, which is what puts "Audio stays on this
/// Mac" next to it in Settings and what lets local-only mode select it. Every test here
/// is about that claim holding when the machine cannot actually honour it — because the
/// failure that matters is not an error message, it is a user being told their audio
/// stayed local while it did not.
final class AppleSpeechTests: XCTestCase {

  private actor FakeRecogniser: OnDeviceRecognising {
    var authorization: SpeechAuthorization
    var onDevice: Bool
    var transcript: String
    var failure: Error?
    private(set) var transcribeCalls = 0
    private(set) var authorizationRequests = 0
    private(set) var lastSampleRate: Int?

    init(
      authorization: SpeechAuthorization = .authorized,
      onDevice: Bool = true,
      transcript: String = "hello from this mac",
      failure: Error? = nil
    ) {
      self.authorization = authorization
      self.onDevice = onDevice
      self.transcript = transcript
      self.failure = failure
    }

    func supportsOnDeviceRecognition(languageCode: String?) async -> Bool { onDevice }
    func authorizationStatus() async -> SpeechAuthorization { authorization }

    func requestAuthorization() async -> SpeechAuthorization {
      authorizationRequests += 1
      // Granting on request is the interesting case: undetermined must become a prompt,
      // not a refusal.
      if authorization == .undetermined { authorization = .authorized }
      return authorization
    }

    func transcribeOnDevice(
      pcm16: Data, sampleRate: Int, languageCode: String?
    ) async throws -> String {
      transcribeCalls += 1
      lastSampleRate = sampleRate
      if let failure { throw failure }
      return transcript
    }
  }

  private func audio(_ bytes: Int = 3200) -> AudioBuffer {
    AudioBuffer(pcm: Data(repeating: 7, count: bytes), sampleRate: 16_000)
  }

  private func transcribe(
    _ provider: AppleSpeechProvider, language: String? = nil
  ) async throws -> TranscriptionResult {
    try await provider.transcribe(
      audio(), context: nil,
      options: TranscriptionOptions(languageCode: language))
  }

  // MARK: - The privacy claim

  func testItDeclaresThatAudioStaysOnTheMachine() {
    XCTAssertFalse(AppleSpeechProvider(recogniser: FakeRecogniser()).sendsAudioOffDevice)
  }

  func testItTranscribesWhenPermittedAndAvailableOnDevice() async throws {
    let recogniser = FakeRecogniser(transcript: "the quick brown fox")
    let result = try await transcribe(AppleSpeechProvider(recogniser: recogniser))
    XCTAssertEqual(result.raw, "the quick brown fox")
    XCTAssertEqual(result.provider, "apple-on-device")
    await AsyncAssertEqual(await recogniser.transcribeCalls, 1)
  }

  /// The load-bearing test. When the recogniser cannot work without a network, the
  /// provider must stop — not hand the audio to Apple's servers, which is what the
  /// framework would happily do if the flag were left off.
  func testItRefusesRatherThanRecognisingOverTheNetwork() async {
    let recogniser = FakeRecogniser(onDevice: false)
    let provider = AppleSpeechProvider(recogniser: recogniser)
    do {
      _ = try await transcribe(provider, language: "en")
      XCTFail("expected a refusal when on-device recognition is unavailable")
    } catch {
      XCTAssertEqual(
        error as? TranscriptionError, .onDeviceRecognitionUnavailable("en"))
    }
    let calls = await recogniser.transcribeCalls
    XCTAssertEqual(calls, 0, "no audio may be handed over once the check has failed")
  }

  func testDeniedPermissionIsReportedAndNoAudioIsSent() async {
    let recogniser = FakeRecogniser(authorization: .denied)
    do {
      _ = try await transcribe(AppleSpeechProvider(recogniser: recogniser))
      XCTFail("expected a refusal when speech recognition is denied")
    } catch {
      XCTAssertEqual(error as? TranscriptionError, .speechRecognitionDenied)
    }
    let calls = await recogniser.transcribeCalls
    XCTAssertEqual(calls, 0)
  }

  func testRestrictedPermissionIsAlsoARefusal() async {
    let recogniser = FakeRecogniser(authorization: .restricted)
    do {
      _ = try await transcribe(AppleSpeechProvider(recogniser: recogniser))
      XCTFail("expected a refusal when speech recognition is restricted")
    } catch {
      XCTAssertEqual(error as? TranscriptionError, .speechRecognitionDenied)
    }
  }

  /// Undetermined is not a refusal: it is a question nobody has asked yet.
  func testUndeterminedPermissionPromptsRatherThanFailing() async throws {
    let recogniser = FakeRecogniser(authorization: .undetermined)
    let result = try await transcribe(AppleSpeechProvider(recogniser: recogniser))
    XCTAssertEqual(result.raw, "hello from this mac")
    let requests = await recogniser.authorizationRequests
    XCTAssertEqual(requests, 1)
  }

  func testEmptyAudioIsRejectedBeforeAnythingElseHappens() async {
    let recogniser = FakeRecogniser()
    let provider = AppleSpeechProvider(recogniser: recogniser)
    do {
      _ = try await provider.transcribe(
        AudioBuffer(pcm: Data(), sampleRate: 16_000), context: nil, options: .default)
      XCTFail("expected empty audio to be rejected")
    } catch {
      XCTAssertEqual(error as? TranscriptionError, .audioEmpty)
    }
    let requests = await recogniser.authorizationRequests
    XCTAssertEqual(requests, 0, "an empty recording should not raise a permission prompt")
  }

  func testTheSampleRateReachesTheRecogniserUnchanged() async throws {
    let recogniser = FakeRecogniser()
    let provider = AppleSpeechProvider(recogniser: recogniser)
    _ = try await provider.transcribe(
      AudioBuffer(pcm: Data(repeating: 3, count: 960), sampleRate: 48_000),
      context: nil, options: .default)
    let rate = await recogniser.lastSampleRate
    XCTAssertEqual(rate, 48_000)
  }

  // MARK: - Settings → Speech "Test connection"

  func testReachabilityPassesWhenTheRecogniserIsUsable() async throws {
    try await AppleSpeechProvider(recogniser: FakeRecogniser()).checkReachability()
  }

  func testReachabilityFailsForTheSameReasonsTranscriptionWould() async {
    do {
      try await AppleSpeechProvider(recogniser: FakeRecogniser(onDevice: false))
        .checkReachability()
      XCTFail("expected the connection test to fail when on-device is unavailable")
    } catch {
      XCTAssertNotNil(error as? TranscriptionError)
    }
  }

  func testRefusalsAreNotOfferedAsRetryable() {
    XCTAssertFalse(TranscriptionError.speechRecognitionDenied.isRetryable)
    XCTAssertFalse(TranscriptionError.onDeviceRecognitionUnavailable("en").isRetryable)
  }

  func testRefusalsExplainThemselvesToTheUser() {
    XCTAssertTrue(
      TranscriptionError.speechRecognitionDenied.errorDescription?
        .contains("System Settings") ?? false)
    XCTAssertTrue(
      TranscriptionError.onDeviceRecognitionUnavailable("Klingon").errorDescription?
        .contains("Klingon") ?? false)
  }

  // MARK: - Format conversion

  func testPCMConvertsToABufferOfTheRightLength() throws {
    let samples = 800
    let data = Data(repeating: 0, count: samples * 2)
    let buffer = try XCTUnwrap(
      SystemOnDeviceRecogniser.buffer(from: data, sampleRate: 16_000))
    XCTAssertEqual(Int(buffer.frameLength), samples)
    XCTAssertEqual(buffer.format.sampleRate, 16_000)
    XCTAssertEqual(buffer.format.channelCount, 1)
  }

  func testEmptyOrNonsenseAudioProducesNoBuffer() {
    XCTAssertNil(SystemOnDeviceRecogniser.buffer(from: Data(), sampleRate: 16_000))
    XCTAssertNil(
      SystemOnDeviceRecogniser.buffer(from: Data(repeating: 1, count: 64), sampleRate: 0))
  }

  private func AsyncAssertEqual<T: Equatable>(
    _ value: @autoclosure () async -> T, _ expected: T,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    let actual = await value()
    XCTAssertEqual(actual, expected, file: file, line: line)
  }
}
