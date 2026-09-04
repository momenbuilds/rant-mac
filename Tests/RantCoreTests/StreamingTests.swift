import XCTest

@testable import RantCore

/// A streaming session bills for as long as it is open, and a socket that is merely
/// dropped stays open on the provider's side until it times out. So the behaviour
/// these tests care most about is not the happy path — it is that `Terminate` goes
/// out on every way of ending, cancellation included.
///
/// The handshake URL gets the same scrutiny as the synchronous provider's multipart
/// body, for the same reason: a mistyped query parameter is a silent 400 that reaches
/// the user as "streaming does not work" with nothing in the log to explain it.
final class StreamingTests: XCTestCase {

  // MARK: - Doubles

  actor FakeWebSocketChannel: WebSocketChannel {
    private var pending: [Result<WebSocketMessage, Error>] = []
    private var waiter: CheckedContinuation<Result<WebSocketMessage, Error>, Never>?
    private(set) var sent: [WebSocketMessage] = []
    private(set) var closeCount = 0
    private var isClosed = false

    func send(_ message: WebSocketMessage) async throws {
      if isClosed { throw URLError(.networkConnectionLost) }
      sent.append(message)
    }

    func receive() async throws -> WebSocketMessage {
      if !pending.isEmpty { return try pending.removeFirst().get() }
      let result = await withCheckedContinuation { continuation in
        waiter = continuation
      }
      return try result.get()
    }

    func close() {
      guard !isClosed else { return }
      isClosed = true
      closeCount += 1
      deliver(.failure(URLError(.cancelled)))
    }

    // MARK: driving the fake

    func push(_ message: WebSocketMessage) { deliver(.success(message)) }
    func pushText(_ text: String) { deliver(.success(.text(text))) }
    func fail(with error: Error) { deliver(.failure(error)) }

    private func deliver(_ result: Result<WebSocketMessage, Error>) {
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: result)
      } else {
        pending.append(result)
      }
    }

    var sentTexts: [String] {
      sent.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }
    var sentBinaries: [Data] {
      sent.compactMap { if case .binary(let data) = $0 { data } else { nil } }
    }
    var terminateCount: Int {
      sentTexts.filter { $0 == StreamingSession.terminateMessage }.count
    }
  }

  actor FakeWebSocketConnector: WebSocketConnecting {
    private var channels: [FakeWebSocketChannel]
    private var connectError: Error?
    private(set) var requests: [URLRequest] = []

    private var connectDelay: Duration

    init(
      channels: [FakeWebSocketChannel] = [],
      connectError: Error? = nil,
      connectDelay: Duration = .zero
    ) {
      self.channels = channels
      self.connectError = connectError
      self.connectDelay = connectDelay
    }

    func connect(to request: URLRequest) async throws -> any WebSocketChannel {
      requests.append(request)
      if connectDelay > .zero { try? await Task.sleep(for: connectDelay) }
      if let connectError { throw connectError }
      if channels.isEmpty { return FakeWebSocketChannel() }
      return channels.removeFirst()
    }

    var connectCount: Int { requests.count }
    var lastRequest: URLRequest? { requests.last }
  }

  actor PartialLog {
    private(set) var partials: [TranscriptionPartial] = []
    private(set) var failure: Error?
    private(set) var isDone = false

    func record(_ partial: TranscriptionPartial) { partials.append(partial) }
    func finish(_ error: Error?) {
      failure = error
      isDone = true
    }
    var texts: [String] { partials.map(\.text) }
  }

  // MARK: - Helpers

  private static let key = "test-key-0123456789abcdef"

  private func provider(
    connector: any WebSocketConnecting,
    key: String? = StreamingTests.key,
    reconnect: ReconnectPolicy = ReconnectPolicy(maximumAttempts: 0)
  ) -> AssemblyAIStreamProvider {
    AssemblyAIStreamProvider(
      keyProvider: { key },
      endpoint: URL(string: "wss://streaming.example.invalid/v3/ws")!,
      connector: connector,
      reconnectPolicy: reconnect,
      terminationGrace: .milliseconds(30))
  }

  private func turn(_ text: String, endOfTurn: Bool) -> String {
    #"{"type":"Turn","turn_order":1,"transcript":"\#(text)","end_of_turn":\#(endOfTurn)}"#
  }

  /// Consumes the stream on a task of its own, recording what comes out.
  private func consume(
    _ stream: TranscriptionStream, into log: PartialLog
  ) -> Task<Void, Never> {
    Task {
      do {
        for try await partial in stream.partials {
          await log.record(partial)
        }
        await log.finish(nil)
      } catch {
        await log.finish(error)
      }
    }
  }

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
  }

  // MARK: - The handshake

  func testTheHandshakeCarriesTheRawApiKeyWithNoBearerPrefix() async throws {
    let connector = FakeWebSocketConnector()
    _ = try await provider(connector: connector).stream(context: nil, options: .default)
    await waitUntil("the socket to be opened") { await connector.connectCount == 1 }
    let request = await connector.lastRequest
    XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), Self.key)
    XCTAssertFalse(
      request?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer") ?? true)
  }

  func testTheHandshakeUrlStatesTheSampleRateEncodingAndSpeechModel() throws {
    let provider = provider(connector: FakeWebSocketConnector())
    let request = provider.makeRequest(context: nil, options: .default, key: Self.key)
    let components = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(components.path, "/v3/ws")
    XCTAssertEqual(items["sample_rate"], "16000")
    XCTAssertEqual(items["encoding"], "pcm_s16le")
    XCTAssertEqual(items["speech_model"], "universal-streaming")
    XCTAssertEqual(items["format_turns"], "true")
  }

  func testTheSampleRateOnTheWireMatchesTheRateTheAudioIsCapturedAt() {
    XCTAssertEqual(AssemblyAIStreamProvider.sampleRate, LocalWhisperProvider.requiredSampleRate)
  }

  func testTheRequestedLanguageReachesTheHandshakeAndIsOtherwiseAbsent() throws {
    let provider = provider(connector: FakeWebSocketConnector())
    let none = provider.makeRequest(context: nil, options: .default, key: Self.key)
    XCTAssertFalse(none.url?.absoluteString.contains("language_code") ?? true)

    let german = provider.makeRequest(
      context: nil, options: TranscriptionOptions(languageCode: "de"), key: Self.key)
    XCTAssertTrue(german.url?.absoluteString.contains("language_code=de") ?? false)
  }

  /// Key terms bias recognition and are allowed out. Everything else Rant knows about
  /// where you are typing is on-device only, and a query string is a very easy place
  /// to leak it by accident.
  func testOnlyDictionaryKeyTermsLeaveTheMachineOnTheHandshakeUrl() throws {
    let context = TranscriptionContext(
      appName: "Slack",
      windowTitle: "SECRET PROJECT — general",
      fieldLabel: "Message to Marcus",
      textBeforeCursor: "Dear Marcus,",
      selectedText: "CONFIDENTIAL SELECTION",
      clipboardText: "CLIPBOARD CONTENTS",
      screenText: "OCR OF THE WHOLE SCREEN",
      keyTerms: ["Supabase"])
    let url = try XCTUnwrap(
      provider(connector: FakeWebSocketConnector())
        .makeRequest(context: context, options: .default, key: Self.key).url
    ).absoluteString

    XCTAssertTrue(url.contains("keyterms_prompt"))
    XCTAssertTrue(url.contains("Supabase"))
    for forbidden in [
      "Slack", "SECRET", "Marcus", "CONFIDENTIAL", "CLIPBOARD", "OCR",
    ] {
      XCTAssertFalse(url.contains(forbidden), "\(forbidden) leaked into the handshake URL")
    }
  }

  func testAMissingKeyIsReportedBeforeAnySocketIsOpened() async {
    let connector = FakeWebSocketConnector()
    await XCTAssertThrowsErrorAsync(
      try await provider(connector: connector, key: nil).stream(context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .apiKeyMissing) }
    let count = await connector.connectCount
    XCTAssertEqual(count, 0)
  }

  // MARK: - Partials

  func testTurnMessagesBecomePartialsAndEndOfTurnMarksThemFinal() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let log = PartialLog()
    let task = consume(stream, into: log)

    await channel.pushText(#"{"type":"Begin","id":"abc"}"#)
    await channel.pushText(turn("we should", endOfTurn: false))
    await channel.pushText(turn("we should ship on Friday", endOfTurn: true))

    await waitUntil("two partials") { await log.partials.count == 2 }
    let partials = await log.partials
    XCTAssertEqual(partials.map(\.text), ["we should", "we should ship on Friday"])
    XCTAssertEqual(partials.map(\.isFinal), [false, true])
    task.cancel()
  }

  /// The server says "still listening" with an empty turn. Yielding that would blank
  /// the overlay in the middle of a sentence.
  func testAnEmptyNonFinalTurnDoesNotBlankTheOverlay() {
    let empty = StreamingSession.decode(.text(turn("", endOfTurn: false)))
    XCTAssertEqual(empty, .ignored)
    let settled = StreamingSession.decode(.text(turn("", endOfTurn: true)))
    XCTAssertEqual(settled, .partial(TranscriptionPartial(text: "", isFinal: true)))
  }

  func testUnknownServerMessageTypesAreIgnoredRatherThanFailingTheSession() {
    XCTAssertEqual(StreamingSession.decode(.text(#"{"type":"SomethingNew"}"#)), .ignored)
    XCTAssertEqual(StreamingSession.decode(.text(#"{"type":"Begin","id":"x"}"#)), .ignored)
  }

  func testAServerErrorFrameBecomesAnErrorRatherThanSilence() {
    XCTAssertEqual(
      StreamingSession.decode(.text(#"{"error":"bad sample rate","status":400}"#)),
      .failure(.http(status: 400, message: "bad sample rate")))
  }

  func testUnreadableServerJsonIsReportedAsMalformed() {
    XCTAssertEqual(StreamingSession.decode(.text("not json at all")), .failure(.malformedResponse))
  }

  // MARK: - Audio

  func testAudioIsSentAsBinaryFramesExactlyAsCaptured() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let frame = Data([0x01, 0x02, 0x03, 0x04])
    await waitUntil("the socket to be ready") { await channel.closeCount == 0 }
    await stream.send(frame)

    await waitUntil("the frame to be sent") { await channel.sentBinaries.count == 1 }
    let binaries = await channel.sentBinaries
    XCTAssertEqual(binaries, [frame])
    let texts = await channel.sentTexts
    XCTAssertTrue(texts.isEmpty, "audio must not be base64'd into a text frame")
  }

  func testAudioIsNoLongerSentOnceTheSessionHasBeenTerminated() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    await stream.finish()
    await waitUntil("terminate to go out") { await channel.terminateCount == 1 }
    await stream.send(Data([0x09, 0x09]))
    let binaries = await channel.sentBinaries
    XCTAssertTrue(binaries.isEmpty, "a terminated session must not keep pushing audio")
  }

  // MARK: - Termination — the expensive one to get wrong

  func testFinishingTheStreamSendsTheTerminationMessage() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let log = PartialLog()
    _ = consume(stream, into: log)

    await stream.finish()
    await waitUntil("terminate to go out") { await channel.terminateCount == 1 }
    let texts = await channel.sentTexts
    XCTAssertEqual(texts, [#"{"type":"Terminate"}"#])
  }

  /// The one that matters most. A cancelled dictation must still close the session,
  /// or the user is billed for a socket nobody is listening to.
  func testTheStreamAlwaysSendsTerminationEvenWhenCancelled() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let log = PartialLog()
    let task = consume(stream, into: log)

    await channel.pushText(turn("half a sentence", endOfTurn: false))
    await waitUntil("the session to be live") { await log.partials.count == 1 }

    task.cancel()

    await waitUntil("terminate to go out despite cancellation") {
      await channel.terminateCount == 1
    }
    await waitUntil("the socket to be closed") { await channel.closeCount >= 1 }
  }

  func testTheServerIsGivenAChanceToFlushItsLastTurnBeforeTheSocketIsClosed() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let log = PartialLog()
    _ = consume(stream, into: log)

    await stream.finish()
    await waitUntil("terminate to go out") { await channel.terminateCount == 1 }
    await channel.pushText(turn("the last words", endOfTurn: true))
    await channel.pushText(#"{"type":"Termination","audio_duration_seconds":2}"#)

    await waitUntil("the stream to end cleanly") { await log.isDone }
    let texts = await log.texts
    XCTAssertEqual(texts, ["the last words"])
    let failure = await log.failure
    XCTAssertNil(failure, "a polite termination is not an error")
  }

  /// Ending a dictation before the handshake completes used to lose the termination
  /// entirely: the socket opened a moment later with nobody left to close it, and the
  /// provider billed it until the session timed out. The most expensive kind of bug —
  /// silent, and only on the short takes people do most.
  func testASessionEndedDuringTheHandshakeStillTerminatesOnceTheSocketOpens() async throws {
    let channel = FakeWebSocketChannel()
    let connector = FakeWebSocketConnector(
      channels: [channel], connectDelay: .milliseconds(40))
    let stream = try await provider(connector: connector).stream(context: nil, options: .default)
    _ = consume(stream, into: PartialLog())

    await stream.finish()  // before the socket is anywhere near open

    await waitUntil("terminate to go out once the socket exists") {
      await channel.terminateCount == 1
    }
  }

  /// The first syllable of every dictation arrives while the socket is still opening.
  func testAudioCapturedBeforeTheSocketOpensIsNotLost() async throws {
    let channel = FakeWebSocketChannel()
    let connector = FakeWebSocketConnector(
      channels: [channel], connectDelay: .milliseconds(40))
    let stream = try await provider(connector: connector).stream(context: nil, options: .default)
    let task = consume(stream, into: PartialLog())

    await stream.send(Data([0x01, 0x02]))
    await stream.send(Data([0x03, 0x04]))

    await waitUntil("the buffered frames to be flushed") {
      await channel.sentBinaries.count == 2
    }
    let binaries = await channel.sentBinaries
    XCTAssertEqual(binaries, [Data([0x01, 0x02]), Data([0x03, 0x04])], "and in order")
    task.cancel()
  }

  func testTerminationIsSentOnlyOnceHoweverManyWaysTheSessionEnds() async throws {
    let channel = FakeWebSocketChannel()
    let stream = try await provider(connector: FakeWebSocketConnector(channels: [channel]))
      .stream(context: nil, options: .default)
    let task = consume(stream, into: PartialLog())

    await stream.finish()
    await stream.finish()
    task.cancel()
    await waitUntil("terminate to go out") { await channel.terminateCount >= 1 }
    try? await Task.sleep(for: .milliseconds(100))
    let count = await channel.terminateCount
    XCTAssertEqual(count, 1, "a second Terminate lands on a closed socket and throws")
  }

  // MARK: - Failure and reconnection

  func testARejectedKeyEndsTheSessionRatherThanBeingRetried() async throws {
    let connector = FakeWebSocketConnector(connectError: TranscriptionError.unauthorized)
    let stream = try await provider(
      connector: connector, reconnect: ReconnectPolicy(maximumAttempts: 3, baseDelay: .milliseconds(1))
    ).stream(context: nil, options: .default)
    let log = PartialLog()
    _ = consume(stream, into: log)

    await waitUntil("the stream to fail") { await log.isDone }
    let failure = await log.failure
    XCTAssertEqual(failure as? TranscriptionError, .unauthorized)
    let attempts = await connector.connectCount
    XCTAssertEqual(attempts, 1, "retrying a rejected key just spends time")
  }

  func testADroppedSocketIsReconnectedAndPartialsResume() async throws {
    let first = FakeWebSocketChannel()
    let second = FakeWebSocketChannel()
    let connector = FakeWebSocketConnector(channels: [first, second])
    let stream = try await provider(
      connector: connector,
      reconnect: ReconnectPolicy(maximumAttempts: 2, baseDelay: .milliseconds(1))
    ).stream(context: nil, options: .default)
    let log = PartialLog()
    let task = consume(stream, into: log)

    await first.pushText(turn("before the drop", endOfTurn: false))
    await waitUntil("the first partial") { await log.partials.count == 1 }

    await first.fail(with: URLError(.networkConnectionLost))
    await waitUntil("a second socket") { await connector.connectCount == 2 }

    await second.pushText(turn("after the drop", endOfTurn: true))
    await waitUntil("the second partial") { await log.partials.count == 2 }
    let texts = await log.texts
    XCTAssertEqual(texts, ["before the drop", "after the drop"])
    task.cancel()
  }

  func testGivingUpOnReconnectionSurfacesTheOriginalNetworkError() async throws {
    let channel = FakeWebSocketChannel()
    let connector = FakeWebSocketConnector(channels: [channel])
    let stream = try await provider(
      connector: connector, reconnect: ReconnectPolicy.none
    ).stream(context: nil, options: .default)
    let log = PartialLog()
    _ = consume(stream, into: log)

    await channel.fail(with: URLError(.networkConnectionLost))
    await waitUntil("the stream to fail") { await log.isDone }
    let failure = await log.failure
    XCTAssertTrue((failure as? TranscriptionError)?.isRetryable ?? false)
  }

  func testReconnectDelaysGrowAndAreCapped() {
    let policy = ReconnectPolicy(
      maximumAttempts: 6, baseDelay: .milliseconds(100), maximumDelay: .milliseconds(800))
    XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(100))
    XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(200))
    XCTAssertEqual(policy.delay(forAttempt: 3), .milliseconds(400))
    XCTAssertEqual(policy.delay(forAttempt: 4), .milliseconds(800))
    XCTAssertEqual(
      policy.delay(forAttempt: 9), .milliseconds(800), "the cap must actually cap")
  }

  func testCloseCodesAreTranslatedIntoSomethingTheUserCanActOn() {
    XCTAssertEqual(AssemblyAIStreamProvider.error(forCloseCode: 4001), .unauthorized)
    XCTAssertEqual(AssemblyAIStreamProvider.error(forCloseCode: 4029), .rateLimited)
    XCTAssertEqual(AssemblyAIStreamProvider.error(forCloseCode: 1000), .cancelled)
    guard case .network = AssemblyAIStreamProvider.error(forCloseCode: 1006) else {
      return XCTFail("an unexplained close should be retryable")
    }
  }
}
