import XCTest
@testable import RantCore

/// A wrong header or a mistyped config key is a silent 400 in production and a
/// confusing error for the user. These tests assert on the bytes we put on the wire,
/// using a fake transport — no network, no API key, no spend.
final class AssemblyAITests: XCTestCase {

  private func provider(
    transport: any HTTPTransport, key: String? = "test-key-0123456789abcdef"
  ) -> AssemblyAIProvider {
    AssemblyAIProvider(
      keyProvider: { key },
      baseURL: URL(string: "https://dictation.example.invalid")!,
      transport: transport)
  }

  private func audio(ms: Int = 500) -> AudioBuffer {
    AudioBuffer(pcm: Data(count: 16_000 / 1000 * ms * 2), sampleRate: 16_000)
  }

  private func config(
    _ provider: AssemblyAIProvider,
    context: TranscriptionContext? = nil,
    options: TranscriptionOptions = .default,
    settings: ContextSettings = .default
  ) throws -> [String: Any] {
    let data = try provider.makeConfig(
      audio: audio(), context: context, options: options, contextSettings: settings)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - Request construction

  func testRequestUsesTheRawKeyWithNoBearerPrefix() async throws {
    let transport = FakeHTTPTransport(json: #"{"text":"hello"}"#)
    _ = try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                   "test-key-0123456789abcdef")
  }

  func testRequestPostsToTheTranscribePath() async throws {
    let transport = FakeHTTPTransport(json: #"{"text":"hello"}"#)
    _ = try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
    XCTAssertEqual(transport.lastRequest?.url?.absoluteString,
                   "https://dictation.example.invalid/transcribe")
  }

  func testMultipartBodyFramesAudioAndConfigCorrectly() throws {
    let p = provider(transport: FakeHTTPTransport(json: "{}"))
    let body = p.multipartBody(pcm: Data([1, 2, 3, 4]), config: Data(#"{"a":1}"#.utf8), boundary: "B")
    let text = String(decoding: body, as: UTF8.self)

    XCTAssertTrue(text.hasPrefix("--B\r\n"))
    XCTAssertTrue(text.contains(
      "Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\nContent-Type: audio/pcm\r\n\r\n"))
    XCTAssertTrue(text.contains(
      "Content-Disposition: form-data; name=\"config\"\r\nContent-Type: application/json\r\n\r\n"))
    XCTAssertTrue(text.hasSuffix("--B--\r\n"), "the closing boundary needs its trailing dashes")
    XCTAssertTrue(body.range(of: Data([1, 2, 3, 4])) != nil, "the audio bytes must survive verbatim")
  }

  // MARK: - Config

  func testConfigAlwaysStatesTheAudioFormat() throws {
    let json = try config(provider(transport: FakeHTTPTransport(json: "{}")))
    XCTAssertEqual(json["sample_rate"] as? Int, 16_000)
    XCTAssertEqual(json["channels"] as? Int, 1)
  }

  /// Sending `[]` and omitting the key are different requests. Empty means "no prior
  /// dialogue", and the key should simply be absent.
  func testEmptySteeringFieldsAreOmittedRatherThanSentAsEmptyArrays() throws {
    let json = try config(provider(transport: FakeHTTPTransport(json: "{}")))
    XCTAssertNil(json["conversation_context"])
    XCTAssertNil(json["word_boost"])
  }

  func testCleanupBlockCarriesTheInstructionForTheChosenLevel() throws {
    let json = try config(
      provider(transport: FakeHTTPTransport(json: "{}")),
      options: TranscriptionOptions(cleanupLevel: .medium))
    let llm = try XCTUnwrap(json["llm"] as? [String: Any])
    let instruction = try XCTUnwrap(llm["instruction"] as? String)
    XCTAssertTrue(instruction.contains("filler"))
    XCTAssertTrue(instruction.contains("transcribing, not replying"),
                  "the model must be told not to answer the content")
  }

  func testCleanupBlockIsAbsentWhenCleanupIsOff() throws {
    for options in [
      TranscriptionOptions(cleanupLevel: .none),
      TranscriptionOptions(cleanupLevel: .medium, allowProviderCleanup: false),
    ] {
      let json = try config(provider(transport: FakeHTTPTransport(json: "{}")), options: options)
      XCTAssertNil(json["llm"], "no rewrite should be requested for \(options)")
    }
  }

  func testStyleInstructionIsAppendedToTheCleanupInstruction() throws {
    let json = try config(
      provider(transport: FakeHTTPTransport(json: "{}")),
      options: TranscriptionOptions(cleanupLevel: .medium, styleInstruction: "Be terse."))
    let llm = try XCTUnwrap(json["llm"] as? [String: Any])
    XCTAssertTrue(try XCTUnwrap(llm["instruction"] as? String).contains("Be terse."))
  }

  func testContextTurnsAndKeyTermsReachTheWire() throws {
    let context = TranscriptionContext(
      textBeforeCursor: "Dear Marcus,",
      recentDictations: ["Let us ship on Friday."],
      keyTerms: ["Supabase", "Cloudflare"])
    let json = try config(provider(transport: FakeHTTPTransport(json: "{}")), context: context)
    XCTAssertEqual(json["conversation_context"] as? [String],
                   ["Let us ship on Friday.", "Dear Marcus,"])
    XCTAssertEqual(json["word_boost"] as? [String], ["Supabase", "Cloudflare"])
  }

  // MARK: - The privacy boundary

  /// The heart of the privacy claim: app name, window title, field label, selection,
  /// clipboard, OCR and IDE symbols are on-device signals. None of them may appear
  /// in an outbound request.
  func testOnDeviceOnlyContextNeverReachesTheWire() throws {
    let context = TranscriptionContext(
      appBundleID: "com.tinyspeck.slackmacgap",
      appName: "Slack",
      windowTitle: "SECRET PROJECT — general",
      browserHost: "mail.google.com",
      fieldLabel: "Message to Marcus",
      textBeforeCursor: "hello",
      selectedText: "CONFIDENTIAL SELECTION",
      clipboardText: "CLIPBOARD CONTENTS",
      screenText: "OCR OF THE WHOLE SCREEN",
      developerSymbols: ["secretFunctionName"],
      recentDictations: ["hello"])
    let data = try provider(transport: FakeHTTPTransport(json: "{}"))
      .makeConfig(audio: audio(), context: context, options: .default)
    let wire = String(decoding: data, as: UTF8.self)

    for forbidden in [
      "Slack", "SECRET PROJECT", "mail.google.com", "Message to Marcus",
      "CONFIDENTIAL SELECTION", "CLIPBOARD CONTENTS", "OCR OF THE WHOLE SCREEN",
      "secretFunctionName", "com.tinyspeck.slackmacgap",
    ] {
      XCTAssertFalse(wire.contains(forbidden), "\(forbidden) leaked into the request body")
    }
  }

  func testCredentialShapedContextIsRedactedBeforeSending() throws {
    let context = TranscriptionContext(
      textBeforeCursor: "export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345")
    let data = try provider(transport: FakeHTTPTransport(json: "{}"))
      .makeConfig(audio: audio(), context: context, options: .default)
    let wire = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(wire.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
    XCTAssertTrue(wire.contains("redacted"))
  }

  func testNoContextIsSentWhenTheUserForbidsCloudContext() throws {
    var settings = ContextSettings.default
    settings.allowSendingToCloud = false
    let context = TranscriptionContext(
      textBeforeCursor: "the text around my cursor", recentDictations: ["a previous sentence"])
    let json = try config(
      provider(transport: FakeHTTPTransport(json: "{}")), context: context, settings: settings)
    XCTAssertNil(json["conversation_context"])
  }

  func testNothingIsSentFromASecureField() throws {
    let context = TranscriptionContext(
      isSecureField: true, textBeforeCursor: "hunter2", recentDictations: ["prior"])
    let json = try config(provider(transport: FakeHTTPTransport(json: "{}")), context: context)
    XCTAssertNil(json["conversation_context"])
  }

  func testExcludedApplicationsContributeNoContext() throws {
    let context = TranscriptionContext(
      appBundleID: "com.1password.1password", textBeforeCursor: "vault entry")
    let json = try config(provider(transport: FakeHTTPTransport(json: "{}")), context: context)
    XCTAssertNil(json["conversation_context"])
  }

  // MARK: - Responses

  func testCleanedTextIsPreferredButRawIsAlwaysKept() async throws {
    let transport = FakeHTTPTransport(
      json: #"{"text":"um so we should ship","llm_response":"We should ship."}"#)
    let result = try await provider(transport: transport)
      .transcribe(audio(), context: nil, options: .default)
    XCTAssertEqual(result.raw, "um so we should ship")
    XCTAssertEqual(result.cleaned, "We should ship.")
    XCTAssertEqual(result.best, "We should ship.")
  }

  /// A failed rewrite must degrade to the verbatim transcript, never strand the
  /// utterance. A blank rewrite counts as failed.
  func testAFailedOrBlankRewriteFallsBackToTheVerbatimTranscript() async throws {
    for json in [
      #"{"text":"the real words","llm_response":null,"llm_error":"timeout"}"#,
      #"{"text":"the real words","llm_response":"   "}"#,
    ] {
      let result = try await provider(transport: FakeHTTPTransport(json: json))
        .transcribe(audio(), context: nil, options: .default)
      XCTAssertEqual(result.best, "the real words")
    }
  }

  func testLatencyIsRecorded() async throws {
    let result = try await provider(transport: FakeHTTPTransport(json: #"{"text":"hi"}"#))
      .transcribe(audio(), context: nil, options: .default)
    XCTAssertNotNil(result.latencyMilliseconds)
  }

  // MARK: - Errors

  func testMissingKeyIsReportedBeforeAnyNetworkCall() async {
    let transport = FakeHTTPTransport(json: "{}")
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport, key: nil)
        .transcribe(audio(), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .apiKeyMissing) }
    XCTAssertEqual(transport.requestCount, 0, "we must not spend a request without a key")
  }

  func testUnauthorizedIsDistinctFromAGenericFailureSoTheUiCanSayFixYourKey() async {
    for status in [401, 403] {
      let transport = FakeHTTPTransport(json: #"{"detail":"nope"}"#, status: status)
      await XCTAssertThrowsErrorAsync(
        try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
      ) {
        XCTAssertEqual($0 as? TranscriptionError, .unauthorized)
        XCTAssertFalse(($0 as? TranscriptionError)?.isRetryable ?? true,
                       "retrying a rejected key is pointless")
      }
    }
  }

  func testRateLimitingIsRetryable() async {
    let transport = FakeHTTPTransport(json: "{}", status: 429)
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    ) {
      XCTAssertEqual($0 as? TranscriptionError, .rateLimited)
      XCTAssertTrue(($0 as? TranscriptionError)?.isRetryable ?? false)
    }
  }

  func testServerErrorMessageIsSurfaced() async {
    let transport = FakeHTTPTransport(json: #"{"message":"audio too quiet"}"#, status: 400)
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    ) {
      XCTAssertEqual($0 as? TranscriptionError, .http(status: 400, message: "audio too quiet"))
    }
  }

  /// A captive portal or a proxy returns HTML, not our JSON. Showing the first part
  /// of it beats showing a bare status code.
  func testNonJsonErrorBodiesStillProduceSomethingDiagnosable() {
    let message = AssemblyAIProvider.errorMessage(from: Data("<html>502 Bad Gateway</html>".utf8))
    XCTAssertEqual(message, "<html>502 Bad Gateway</html>")
  }

  func testMalformedSuccessBodyIsAnError() async {
    let transport = FakeHTTPTransport(json: #"{"unexpected":true}"#)
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .malformedResponse) }
  }

  func testEmptyRecordingIsRejectedLocally() async {
    let transport = FakeHTTPTransport(json: "{}")
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport)
        .transcribe(AudioBuffer(pcm: Data()), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .audioEmpty) }
    XCTAssertEqual(transport.requestCount, 0)
  }

  func testOverlyLongAudioIsRejectedLocallyWithTheLimitNamed() async {
    let transport = FakeHTTPTransport(json: "{}")
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport)
        .transcribe(audio(ms: 130_000), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .audioTooLong(seconds: 130, limit: 120)) }
    XCTAssertEqual(transport.requestCount, 0, "no point uploading audio we know is too long")
  }

  func testNetworkFailureIsReportedAsRetryable() async {
    let transport = FakeHTTPTransport(failure: URLError(.notConnectedToInternet))
    await XCTAssertThrowsErrorAsync(
      try await provider(transport: transport).transcribe(audio(), context: nil, options: .default)
    ) { XCTAssertTrue(($0 as? TranscriptionError)?.isRetryable ?? false) }
  }

  // MARK: - Warm up

  func testWarmUpSendsAnUnauthenticatedRequestToTheHostRoot() async {
    let transport = FakeHTTPTransport(json: "{}", status: 404)
    await provider(transport: transport).warmUp()
    XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://dictation.example.invalid")
    XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
    XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                 "the warm-up must not carry the key")
  }
}

/// XCTest has no async throwing assertion built in.
func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ inspect: (Error) -> Void = { _ in }
) async {
  do {
    _ = try await expression()
    XCTFail("expected an error but none was thrown", file: file, line: line)
  } catch {
    inspect(error)
  }
}
