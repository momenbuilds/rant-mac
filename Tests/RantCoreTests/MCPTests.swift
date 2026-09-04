import XCTest

@testable import RantCore

/// The MCP server's tests are mostly promises rather than behaviour.
///
/// Everything here runs against a real in-memory database and the real protocol
/// entry point — strings in, strings out — because the transport is the one part
/// that is genuinely uninteresting, and the parts that matter (consent, redaction,
/// the audit trail, and not falling over when handed rubbish) are all reachable
/// without a socket.
final class MCPTests: XCTestCase {

  // MARK: - Fixtures

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  /// A credential of each recognisable shape, planted in the data the tools read.
  private enum Planted {
    static let apiKey = "sk-liveKEY0123456789abcdefghijklmnop"  // not-a-real-key
    static let awsKey = "AKIAIOSFODNN7EXAMPLE"  // not-a-real-key
    static let jwt =
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    static let audioPath = "/Users/someone/Library/Containers/dev.rant.mac/Data/audio/42.wav"
  }

  private struct StubDictation: MCPDictationControlling {
    let started: Counter
    let stopped: Counter
    func startDictation() async throws { started.bump() }
    func stopDictation() async throws { stopped.bump() }
  }

  /// A counter that can be read after the actor has finished with it.
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  private struct StubContext: MCPContextProviding {
    let context: TranscriptionContext?
    func currentContext() async -> TranscriptionContext? { context }
  }

  private func seed(_ database: Database) throws {
    let store = SQLiteTranscriptStore(database: database)
    try store.save(
      Transcript(
        createdAt: Date(),
        rawText: "deploy the thing",
        finalText: "Deploy the staging box with the key \(Planted.apiKey) and tell Sam.",
        provider: "test", appName: "Ghostty", category: .developer,
        durationMilliseconds: 4_000, audioPath: Planted.audioPath))
    try store.save(
      Transcript(
        createdAt: Date().addingTimeInterval(-60),
        rawText: "grocery list", finalText: "Milk, bread, and a new kettle.",
        provider: "test", appName: "Notes", category: .personal, durationMilliseconds: 3_000))

    try database.run(
      """
      INSERT INTO meetings (started_at, ended_at, title, app_name, summary, action_items,
        decisions, content_hash)
      VALUES (?,?,?,?,?,?,?,?)
      """,
      [
        SQLValue(Date().addingTimeInterval(-3_600)), SQLValue(Date()),
        .text("Deploy planning"), .text("Zoom"),
        .text("We agreed to ship on Thursday. Token \(Planted.jwt)"),
        .text("Sam writes the release notes."), .text("Ship on Thursday."),
        .text("meeting-hash-1"),
      ])
    try database.run(
      """
      INSERT INTO meeting_segments (meeting_id, started_ms, ended_ms, speaker, channel, text)
      VALUES (1, 0, 5000, 'Sam', 'them', ?)
      """, [.text("Let us talk about the deploy schedule.")])
    try database.run(
      """
      INSERT INTO meeting_segments (meeting_id, started_ms, ended_ms, speaker, channel, text)
      VALUES (1, 5000, 9000, 'Me', 'me', ?)
      """, [.text("Agreed, we deploy on Thursday.")])

    try database.run(
      """
      INSERT INTO notes (created_at, updated_at, title, body, pinned, tags, content_hash)
      VALUES (?,?,?,?,0,?,?)
      """,
      [
        SQLValue(Date()), SQLValue(Date()), .text("Deploy runbook"),
        .text("Rotate the credentials first. Old one was \(Planted.awsKey)."),
        .text("ops"), .text("note-hash-1"),
      ])
  }

  private func makeServer(
    _ settings: MCPSettings,
    database: Database,
    dictation: MCPDictationControlling? = nil,
    context: TranscriptionContext? = nil
  ) -> MCPServer {
    MCPServer(
      settings: settings, database: database, dictation: dictation,
      context: context.map { StubContext(context: $0) })
  }

  private func everythingShared(write: Bool = false) -> MCPSettings {
    MCPSettings(
      enabled: true, allowWrite: write, collections: Set(MCPCollection.allCases).subtracting([.control]))
  }

  // MARK: - Calling

  private func send(_ server: MCPServer, _ raw: String) async -> String? {
    await server.handle(raw)
  }

  private func request(
    _ server: MCPServer, method: String, params: JSONValue = .object([:]), id: Int = 1
  ) async throws -> JSONValue {
    let message = JSONValue.object([
      "jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method), "params": params,
    ]).encoded()
    guard let reply = await server.handle(message) else {
      XCTFail("expected a reply to \(method)")
      return .null
    }
    return try JSONValue.parse(reply)
  }

  private func callTool(
    _ server: MCPServer, _ name: String, _ arguments: JSONValue = .object([:])
  ) async throws -> JSONValue {
    try await request(
      server, method: "tools/call",
      params: .object(["name": .string(name), "arguments": arguments]))
  }

  /// The JSON a successful tool call carried, unwrapped from the MCP content block.
  private func payload(_ reply: JSONValue) throws -> JSONValue {
    guard case .array(let content)? = reply["result"]?["content"],
      let text = content.first?["text"]?.stringValue
    else {
      XCTFail("expected tool content, got \(reply.encoded())")
      return .null
    }
    return try JSONValue.parse(text)
  }

  private func errorCode(_ reply: JSONValue) -> Int? {
    reply["error"]?["code"]?.intValue
  }

  /// Every tool, with arguments that would succeed if it were permitted. Used by the
  /// tests that have to sweep the whole surface rather than one tool at a time.
  private var everyCall: [(String, JSONValue)] {
    [
      (MCPTool.searchTranscripts.name, .object(["query": .string("deploy")])),
      (MCPTool.getTranscript.name, .object(["id": .int(1)])),
      (MCPTool.searchMeetings.name, .object(["query": .string("deploy")])),
      (MCPTool.getMeeting.name, .object(["id": .int(1)])),
      (MCPTool.searchNotes.name, .object(["query": .string("deploy")])),
      (MCPTool.getStats.name, .object(["period": .string("all")])),
      (MCPTool.getCurrentContext.name, .object([:])),
      (MCPTool.startDictation.name, .object([:])),
      (MCPTool.stopDictation.name, .object([:])),
    ]
  }

  // MARK: - Off by default

  func testAServerThatWasNeverEnabledAnswersNothing() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(.disabled, database: database)

    for method in ["initialize", "tools/list", "ping"] {
      let reply = await send(server, #"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#)
      XCTAssertNil(reply, "\(method) answered a server that was never enabled")
    }
    for (name, arguments) in everyCall {
      let message = JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
        "params": .object(["name": .string(name), "arguments": arguments]),
      ]).encoded()
      let reply = await send(server, message)
      XCTAssertNil(reply, "\(name) answered a disabled server")
    }
  }

  func testTheDefaultSettingsShareNothingAndAllowNoWrites() {
    XCTAssertFalse(MCPSettings.disabled.enabled)
    XCTAssertFalse(MCPSettings.disabled.allowWrite)
    XCTAssertTrue(MCPSettings.disabled.collections.isEmpty)
    for collection in MCPCollection.allCases {
      XCTAssertFalse(MCPSettings.disabled.allows(collection))
    }
  }

  func testADisabledServerWritesNoAuditRowsBecauseItDoesNotServeRequests() async throws {
    let database = try freshDatabase()
    let server = makeServer(.disabled, database: database)
    _ = await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    XCTAssertEqual(try MCPAudit(database: database).count(), 0)
  }

  func testAServerEnabledAtRuntimeStartsAnsweringAndCanBeSwitchedOffAgain() async throws {
    let database = try freshDatabase()
    let server = makeServer(.disabled, database: database)
    let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let whileOff = await send(server, ping)
    XCTAssertNil(whileOff)

    await server.update(settings: MCPSettings(enabled: true))
    let whileOn = await send(server, ping)
    XCTAssertNotNil(whileOn)

    await server.update(settings: .disabled)
    let afterOff = await send(server, ping)
    XCTAssertNil(afterOff)
  }

  // MARK: - Loopback only

  func testABindAddressThatIsNotLoopbackIsRejected() throws {
    let refused = [
      "0.0.0.0", "::", "192.168.1.24", "10.0.0.5", "8.8.8.8", "example.com",
      "127.0.0.1.example.com", "0177.0.0.1", "", "127.0.0", "::ffff:0:0",
    ]
    for host in refused {
      XCTAssertFalse(MCPBindAddress.isLoopback(host), "\(host) was treated as loopback")
      XCTAssertThrowsError(try MCPBindAddress(host: host, port: 7_373)) { error in
        XCTAssertEqual(error as? MCPBindAddress.Failure, .notLoopback(host))
      }
      XCTAssertThrowsError(try MCPSettings(enabled: true, host: host).bindAddress())
    }
  }

  func testOnlyLoopbackAddressesCanBeBound() throws {
    for host in ["127.0.0.1", "127.1.2.3", "localhost", "::1", " 127.0.0.1 "] {
      XCTAssertTrue(MCPBindAddress.isLoopback(host), "\(host) should be loopback")
      XCTAssertNoThrow(try MCPBindAddress(host: host, port: 7_373))
    }
  }

  func testAnUnusablePortIsRejectedEvenOnLoopback() throws {
    for port in [0, -1, 70_000] {
      XCTAssertThrowsError(try MCPBindAddress(host: "127.0.0.1", port: port)) { error in
        XCTAssertEqual(error as? MCPBindAddress.Failure, .invalidPort(port))
      }
    }
  }

  // MARK: - The tool catalogue

  func testToolsListDescribesEveryToolWithANameDescriptionAndSchema() async throws {
    let database = try freshDatabase()
    let server = makeServer(MCPSettings(enabled: true), database: database)
    let reply = try await request(server, method: "tools/list")

    guard case .array(let tools)? = reply["result"]?["tools"] else {
      return XCTFail("no tools in \(reply.encoded())")
    }
    XCTAssertEqual(tools.count, 9)
    for tool in tools {
      let name = tool["name"]?.stringValue ?? ""
      XCTAssertTrue(name.hasPrefix("rant_"), "unexpected tool name \(name)")
      XCTAssertFalse((tool["description"]?.stringValue ?? "").isEmpty, "\(name) has no description")
      XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object", "\(name) has no schema")
      XCTAssertNotNil(tool["inputSchema"]?["properties"], "\(name) has no schema properties")
    }
    let names = tools.compactMap { $0["name"]?.stringValue }
    XCTAssertEqual(Set(names), Set(MCPTool.all.map(\.name)))
  }

  func testInitializeReportsTheProtocolVersionAndRemembersTheClient() async throws {
    let database = try freshDatabase()
    let server = makeServer(MCPSettings(enabled: true), database: database)
    let reply = try await request(
      server, method: "initialize",
      params: .object(["clientInfo": .object(["name": .string("claude-code")])]))

    XCTAssertEqual(reply["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
    XCTAssertEqual(reply["result"]?["serverInfo"]?["name"]?.stringValue, "rant")

    _ = try await request(server, method: "tools/list")
    let entries = try await server.recentAudit()
    XCTAssertEqual(entries.first?.client, "claude-code")
  }

  // MARK: - Per-collection consent

  func testAToolForADisabledCollectionReturnsAnErrorRatherThanData() async throws {
    let database = try freshDatabase()
    try seed(database)

    let byCollection: [MCPCollection: [(String, JSONValue)]] = [
      .transcripts: [
        (MCPTool.searchTranscripts.name, .object(["query": .string("deploy")])),
        (MCPTool.getTranscript.name, .object(["id": .int(1)])),
      ],
      .meetings: [
        (MCPTool.searchMeetings.name, .object(["query": .string("deploy")])),
        (MCPTool.getMeeting.name, .object(["id": .int(1)])),
      ],
      .notes: [(MCPTool.searchNotes.name, .object(["query": .string("deploy")]))],
      .stats: [(MCPTool.getStats.name, .object([:]))],
      .context: [(MCPTool.getCurrentContext.name, .object([:]))],
    ]

    for (collection, calls) in byCollection {
      // Everything else is shared, so a refusal can only come from this collection.
      var settings = everythingShared()
      settings.collections.remove(collection)
      let server = makeServer(settings, database: database, context: .empty)

      for (name, arguments) in calls {
        let reply = try await callTool(server, name, arguments)
        XCTAssertEqual(
          errorCode(reply), MCPErrorCode.collectionNotEnabled,
          "\(name) answered with \(collection) switched off: \(reply.encoded())")
        XCTAssertNil(reply["result"], "\(name) returned data for a disabled collection")
      }
    }
  }

  func testEachCollectionIsGrantedIndependentlyOfTheOthers() async throws {
    let database = try freshDatabase()
    try seed(database)

    for collection in [MCPCollection.transcripts, .meetings, .notes, .stats, .context] {
      let server = makeServer(
        MCPSettings(enabled: true, collections: [collection]), database: database, context: .empty)

      for (name, arguments) in everyCall {
        guard let tool = MCPTool.named(name) else { return XCTFail("unknown tool \(name)") }
        let reply = try await callTool(server, name, arguments)
        if tool.collection == collection {
          XCTAssertNotNil(reply["result"], "\(name) was refused with \(collection) granted")
        } else {
          XCTAssertNotNil(
            reply["error"], "\(name) answered with only \(collection) granted")
        }
      }
    }
  }

  func testSharingEveryCollectionStillDoesNotGrantWriteAccess() async throws {
    let database = try freshDatabase()
    let started = Counter(), stopped = Counter()
    let server = makeServer(
      everythingShared(), database: database,
      dictation: StubDictation(started: started, stopped: stopped))

    for name in [MCPTool.startDictation.name, MCPTool.stopDictation.name] {
      let reply = try await callTool(server, name)
      XCTAssertEqual(errorCode(reply), MCPErrorCode.writeNotAllowed, "\(name) was not refused")
    }
    XCTAssertEqual(started.count, 0)
    XCTAssertEqual(stopped.count, 0)
  }

  func testWriteToolsRunOnlyOnceWriteAccessIsGrantedSeparately() async throws {
    let database = try freshDatabase()
    let started = Counter(), stopped = Counter()
    let server = makeServer(
      everythingShared(write: true), database: database,
      dictation: StubDictation(started: started, stopped: stopped))

    let startReply = try await callTool(server, MCPTool.startDictation.name)
    XCTAssertNotNil(startReply["result"])
    let stopReply = try await callTool(server, MCPTool.stopDictation.name)
    XCTAssertNotNil(stopReply["result"])
    XCTAssertEqual(started.count, 1)
    XCTAssertEqual(stopped.count, 1)
  }

  func testWriteToolsWithNoDictationControllerFailRatherThanPretendToRecord() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(write: true), database: database)
    let reply = try await callTool(server, MCPTool.startDictation.name)
    XCTAssertEqual(errorCode(reply), MCPErrorCode.internalError)
  }

  func testTheWriteClassIsExactlyTheTwoDictationTools() {
    XCTAssertEqual(
      Set(MCPTool.all.filter(\.isWrite).map(\.name)),
      [MCPTool.startDictation.name, MCPTool.stopDictation.name])
  }

  // MARK: - Reading the user's data

  func testSearchingTranscriptsReturnsMatchingDictationsWithTheirMetadata() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let found = try payload(
      try await callTool(
        server, MCPTool.searchTranscripts.name, .object(["query": .string("kettle")])))
    guard case .array(let results)? = found["results"] else { return XCTFail("no results") }
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?["app"]?.stringValue, "Notes")
    XCTAssertNotNil(results.first?["created_at"]?.stringValue)
  }

  func testGettingATranscriptReturnsItsText() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let hits = try payload(
      try await callTool(
        server, MCPTool.searchTranscripts.name, .object(["query": .string("kettle")])))
    guard case .array(let results)? = hits["results"], let id = results.first?["id"]?.intValue
    else { return XCTFail("no transcript to fetch") }

    let transcript = try payload(
      try await callTool(server, MCPTool.getTranscript.name, .object(["id": .int(id)])))
    XCTAssertEqual(transcript["text"]?.stringValue, "Milk, bread, and a new kettle.")
  }

  func testFetchingATranscriptThatDoesNotExistIsAnErrorNotAnEmptyAnswer() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)
    let reply = try await callTool(
      server, MCPTool.getTranscript.name, .object(["id": .int(99_999)]))
    XCTAssertEqual(errorCode(reply), MCPErrorCode.invalidParams)
  }

  func testAMeetingMatchedByTwoSegmentsIsReturnedOnce() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let found = try payload(
      try await callTool(
        server, MCPTool.searchMeetings.name, .object(["query": .string("deploy")])))
    guard case .array(let results)? = found["results"] else { return XCTFail("no results") }
    XCTAssertEqual(results.count, 1, "both matching segments produced their own meeting")
    XCTAssertEqual(results.first?["title"]?.stringValue, "Deploy planning")
  }

  func testGettingAMeetingIncludesItsSegmentsInOrder() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let meeting = try payload(
      try await callTool(server, MCPTool.getMeeting.name, .object(["id": .int(1)])))
    XCTAssertEqual(meeting["decisions"]?.stringValue, "Ship on Thursday.")
    guard case .array(let segments)? = meeting["segments"] else { return XCTFail("no segments") }
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments.first?["channel"]?.stringValue, "them")
    XCTAssertEqual(segments.last?["channel"]?.stringValue, "me")
  }

  func testSearchingNotesMatchesTheBodyAsWellAsTheTitle() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let found = try payload(
      try await callTool(
        server, MCPTool.searchNotes.name, .object(["query": .string("rotate")])))
    guard case .array(let results)? = found["results"] else { return XCTFail("no results") }
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?["title"]?.stringValue, "Deploy runbook")
  }

  func testStatsReportCountsAndNoTranscriptText() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let stats = try payload(
      try await callTool(server, MCPTool.getStats.name, .object(["period": .string("all")])))
    XCTAssertEqual(stats["dictations"]?.intValue, 2)
    XCTAssertGreaterThan(stats["words"]?.intValue ?? 0, 0)
    XCTAssertNotNil(stats["words_by_category"]?["developer"])
    XCTAssertFalse(stats.encoded().contains("kettle"))
  }

  func testAnUnknownStatsPeriodIsRefusedRatherThanGuessed() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)
    let reply = try await callTool(
      server, MCPTool.getStats.name, .object(["period": .string("fortnight")]))
    XCTAssertEqual(errorCode(reply), MCPErrorCode.invalidParams)
  }

  func testCurrentContextDescribesTheAppButNotTheTextAroundTheCursor() async throws {
    let database = try freshDatabase()
    let context = TranscriptionContext(
      appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Bank — Transfer",
      browserHost: "example.com", fieldRole: "AXTextArea", fieldLabel: "Message",
      textBeforeCursor: "my account number is 12345678",
      selectedText: "secret selection",
      clipboardText: "pasted \(Planted.apiKey)")
    let server = makeServer(everythingShared(), database: database, context: context)

    let described = try payload(try await callTool(server, MCPTool.getCurrentContext.name))
    XCTAssertEqual(described["app"]?.stringValue, "Safari")
    XCTAssertEqual(described["field_role"]?.stringValue, "AXTextArea")
    XCTAssertEqual(described["selection_length"]?.intValue, 16)

    let json = described.encoded()
    for leaked in ["12345678", "secret selection", "pasted", "Bank — Transfer", Planted.apiKey] {
      XCTAssertFalse(json.contains(leaked), "context leaked \(leaked)")
    }
  }

  func testCurrentContextInASecureFieldSaysNothingButThat() async throws {
    let database = try freshDatabase()
    let server = makeServer(
      everythingShared(), database: database,
      context: TranscriptionContext(appName: "1Password", isSecureField: true))

    let described = try payload(try await callTool(server, MCPTool.getCurrentContext.name))
    XCTAssertEqual(described["secure_field"]?.boolValue, true)
    XCTAssertNil(described["app"])
  }

  // MARK: - Never expose secrets

  func testNoToolReturnsAKeyShapedStringOrAPathOutsideTheContainer() async throws {
    let database = try freshDatabase()
    try seed(database)
    let started = Counter(), stopped = Counter()
    let server = makeServer(
      everythingShared(write: true), database: database,
      dictation: StubDictation(started: started, stopped: stopped),
      context: TranscriptionContext(
        appName: "Ghostty", textBeforeCursor: "export TOKEN=\(Planted.apiKey)",
        clipboardText: Planted.awsKey))

    var everything = ""
    for (name, arguments) in everyCall {
      let reply = try await callTool(server, name, arguments)
      XCTAssertNotNil(reply["result"], "\(name) failed: \(reply.encoded())")
      everything += reply.encoded()
    }
    // Also the search that returns the transcript holding the key, by the word next
    // to it — the redactor, not the query, has to be what keeps it out.
    everything += try await callTool(
      server, MCPTool.searchTranscripts.name, .object(["query": .string("staging")])
    ).encoded()
    everything += try await callTool(
      server, MCPTool.getTranscript.name, .object(["id": .int(1)])
    ).encoded()

    for secret in [Planted.apiKey, Planted.awsKey, Planted.jwt] {
      XCTAssertFalse(everything.contains(secret), "a tool returned \(secret.prefix(8))…")
    }
    XCTAssertTrue(everything.contains(SecretRedactor.placeholder), "nothing was redacted at all")
    XCTAssertFalse(everything.contains("/Users/"), "a tool returned a filesystem path")
    XCTAssertFalse(everything.contains(Planted.audioPath))
    XCTAssertFalse(everything.contains(".wav"))
  }

  func testTheKeychainIsNeverReachableThroughAToolBecauseNoToolNamesASecret() {
    // A structural check rather than a behavioural one: there is no tool whose
    // contract mentions credentials, so there is no path from the protocol to
    // `SecretStore` to test dynamically.
    let surface = MCPTool.all.map { $0.name + " " + $0.description }.joined(separator: " ")
      .lowercased()
    for word in ["api key", "keychain", "secret", "password", "token", "credential"] {
      XCTAssertFalse(surface.contains(word), "a tool advertises \(word)")
    }
  }

  // MARK: - Audit

  func testEveryRequestWritesAnAuditRow() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database, context: .empty)
    let audit = MCPAudit(database: database)

    _ = try await request(
      server, method: "initialize",
      params: .object(["clientInfo": .object(["name": .string("cursor")])]))
    _ = try await request(server, method: "tools/list")
    _ = try await callTool(
      server, MCPTool.searchTranscripts.name, .object(["query": .string("deploy")]))
    _ = try await callTool(server, "rant_not_a_tool")
    _ = await send(server, "{ this is not json")
    _ = try await request(server, method: "sneaky/method")

    let entries = try audit.recent()
    XCTAssertEqual(entries.count, 6)
    XCTAssertEqual(
      Set(entries.map(\.tool)),
      ["initialize", "tools/list", MCPTool.searchTranscripts.name, "rant_not_a_tool", "invalid",
       "sneaky/method"])
    XCTAssertEqual(entries.first(where: { $0.tool == MCPTool.searchTranscripts.name })?.resultCount, 1)
  }

  func testARefusedRequestIsAuditedJustAsAnAnsweredOneIs() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(MCPSettings(enabled: true), database: database)

    _ = try await callTool(
      server, MCPTool.searchMeetings.name, .object(["query": .string("payroll")]))
    let entries = try MCPAudit(database: database).recent()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.tool, MCPTool.searchMeetings.name)
    XCTAssertEqual(entries.first?.resultCount, 0)
    XCTAssertTrue(entries.first?.arguments.contains("payroll") ?? false)
  }

  func testTheAuditRecordsTheArgumentsAndNeverTheTranscriptItReturned() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    _ = try await callTool(server, MCPTool.getTranscript.name, .object(["id": .int(2)]))
    let entry = try XCTUnwrap(try MCPAudit(database: database).recent().first)
    XCTAssertEqual(entry.tool, MCPTool.getTranscript.name)
    XCTAssertTrue(entry.arguments.contains("\"id\":2"))
    XCTAssertFalse(entry.arguments.contains("kettle"), "the audit kept the transcript body")
    XCTAssertEqual(entry.resultCount, 1)
  }

  func testASecretInSideAQueryIsRedactedBeforeItReachesTheAuditTable() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)

    _ = try await callTool(
      server, MCPTool.searchTranscripts.name, .object(["query": .string(Planted.apiKey)]))
    let entry = try XCTUnwrap(try MCPAudit(database: database).recent().first)
    XCTAssertFalse(entry.arguments.contains(Planted.apiKey))
    XCTAssertTrue(entry.arguments.contains(SecretRedactor.placeholder))
  }

  func testLongArgumentsAreTruncatedSoTheAuditCannotBecomeASecondCopyOfTheData() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)
    let essay = String(repeating: "word ", count: 4_000)

    _ = try await callTool(
      server, MCPTool.searchTranscripts.name, .object(["query": .string(essay)]))
    let entry = try XCTUnwrap(try MCPAudit(database: database).recent().first)
    XCTAssertLessThanOrEqual(entry.arguments.count, MCPAudit.totalLimit + 1)
  }

  func testANotificationIsAuditedEvenThoughItGetsNoReply() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)
    let message = JSONValue.object([
      "jsonrpc": .string("2.0"), "method": .string("tools/call"),
      "params": .object([
        "name": .string(MCPTool.searchNotes.name),
        "arguments": .object(["query": .string("runbook")]),
      ]),
    ]).encoded()

    let reply = await send(server, message)
    XCTAssertNil(reply)
    XCTAssertEqual(try MCPAudit(database: database).count(), 1)
  }

  // MARK: - Adversarial input

  func testMalformedInputProducesAnErrorResponseRatherThanACrash() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(write: true), database: database)

    let cases: [(String, Int)] = [
      ("", MCPErrorCode.parse),
      ("{", MCPErrorCode.parse),
      (#"{"jsonrpc":"2.0","id":1,"method":"tools/li"#, MCPErrorCode.parse),
      ("not json at all", MCPErrorCode.parse),
      ("\u{0}\u{1}\u{2}", MCPErrorCode.parse),
      ("null", MCPErrorCode.invalidRequest),
      ("42", MCPErrorCode.invalidRequest),
      (#""a string""#, MCPErrorCode.invalidRequest),
      ("[1,2,3]", MCPErrorCode.invalidRequest),
      (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, MCPErrorCode.invalidRequest),
      (#"{"jsonrpc":"2.0","id":1}"#, MCPErrorCode.invalidRequest),
      (#"{"jsonrpc":"2.0","id":1,"method":42}"#, MCPErrorCode.invalidRequest),
      (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, MCPErrorCode.invalidRequest),
      (#"{"jsonrpc":"2.0","id":1,"method":"tools/nope"}"#, MCPErrorCode.methodNotFound),
      (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, MCPErrorCode.invalidParams),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rant_get_stats","arguments":7}}"#,
        MCPErrorCode.invalidParams
      ),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rant_get_transcript","arguments":{"id":"one"}}}"#,
        MCPErrorCode.invalidParams
      ),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rant_search_notes","arguments":{}}}"#,
        MCPErrorCode.invalidParams
      ),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rant_search_notes","arguments":{"query":["a"]}}}"#,
        MCPErrorCode.invalidParams
      ),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rant_search_notes","arguments":{"query":"x","limit":"lots"}}}"#,
        MCPErrorCode.invalidParams
      ),
      (
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"../../etc/passwd"}}"#,
        MCPErrorCode.methodNotFound
      ),
    ]

    for (message, expected) in cases {
      guard let raw = await send(server, message) else {
        XCTFail("no reply to \(message.prefix(40))")
        continue
      }
      let reply = try JSONValue.parse(raw)
      XCTAssertEqual(reply["jsonrpc"]?.stringValue, "2.0")
      XCTAssertNotNil(reply["id"], "a JSON-RPC error must carry an id, even a null one")
      XCTAssertEqual(errorCode(reply), expected, "for \(message.prefix(60))")
      XCTAssertNil(reply["result"])
    }
  }

  func testARequestWithoutAnIdIsANotificationAndGetsNoReply() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)

    let notifications = [
      #"{"jsonrpc":"2.0","method":"ping"}"#,
      #"{"jsonrpc":"2.0","method":"nonsense/method"}"#,
      #"{"jsonrpc":"2.0"}"#,
      #"{"jsonrpc":"1.0","method":"ping"}"#,
    ]
    for message in notifications {
      let reply = await send(server, message)
      XCTAssertNil(reply, "a notification was answered: \(message)")
    }
  }

  func testAnIdOfAnyJSONTypeIsEchoedBackUnchanged() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)

    for id in [#""abc""#, "17", "null", "-3"] {
      let sent = await send(server, #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
      let raw = try XCTUnwrap(sent)
      let reply = try JSONValue.parse(raw)
      XCTAssertEqual(reply["id"], try JSONValue.parse(id))
    }
  }

  func testAHugePayloadIsRefusedBeforeItIsParsed() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)
    let huge = JSONValue.object([
      "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
      "params": .object([
        "name": .string(MCPTool.searchNotes.name),
        "arguments": .object([
          "query": .string(String(repeating: "a", count: MCPServer.maximumRequestBytes + 1_000))
        ]),
      ]),
    ]).encoded()

    let sent = await send(server, huge)
    let reply = try JSONValue.parse(try XCTUnwrap(sent))
    XCTAssertEqual(errorCode(reply), MCPErrorCode.invalidRequest)
    XCTAssertEqual(try MCPAudit(database: database).recent().first?.arguments, "\"oversized\"")
  }

  func testDeeplyNestedJSONIsHandledWithoutRunningOutOfStack() async throws {
    let database = try freshDatabase()
    let server = makeServer(everythingShared(), database: database)
    let nested = String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)
    let sent = await send(server, nested)
    let reply = try JSONValue.parse(try XCTUnwrap(sent))
    XCTAssertNotNil(reply["error"])
  }

  func testAQueryOfPunctuationAloneReturnsNothingRatherThanAnFTSSyntaxError() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    for query in ["\"", "*", "AND OR NOT", "' OR 1=1 --", "^$(){}"] {
      for tool in [
        MCPTool.searchTranscripts.name, MCPTool.searchMeetings.name, MCPTool.searchNotes.name,
      ] {
        let reply = try await callTool(server, tool, .object(["query": .string(query)]))
        XCTAssertNotNil(reply["result"], "\(tool) failed on \(query): \(reply.encoded())")
      }
    }
  }

  func testAnExcessiveLimitIsClampedRatherThanTrusted() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)

    let found = try payload(
      try await callTool(
        server, MCPTool.searchTranscripts.name,
        .object(["query": .string("the"), "limit": .int(1_000_000)])))
    guard case .array(let results)? = found["results"] else { return XCTFail("no results") }
    XCTAssertLessThanOrEqual(results.count, MCPTool.maximumLimit)
  }

  // MARK: - Transport

  func testTheLineTransportRepliesToEachRequestAndSkipsBlankLines() async throws {
    let database = try freshDatabase()
    try seed(database)
    let server = makeServer(everythingShared(), database: database)
    let collected = Collected()

    let (stream, continuation) = AsyncStream<String>.makeStream()
    continuation.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    continuation.yield("   ")
    continuation.yield(#"{"jsonrpc":"2.0","method":"ping"}"#)
    continuation.yield(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    continuation.finish()

    await MCPLineTransport(server: server).run(lines: stream) { collected.append($0) }
    let lines = collected.lines
    XCTAssertEqual(lines.count, 2, "a blank line or a notification produced output")
    XCTAssertTrue(lines[0].contains("\"id\":1"))
    XCTAssertTrue(lines[1].contains("rant_search_transcripts"))
  }

  private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
  }

  // MARK: - JSON

  func testTheJSONEncoderRoundTripsAndEscapesControlCharacters() throws {
    let value = JSONValue.object([
      "text": .string("line\nbreak \"quoted\" \\ tab\t\u{1}"),
      "list": .array([.int(1), .double(1.5), .bool(true), .null]),
    ])
    let round = try JSONValue.parse(value.encoded())
    XCTAssertEqual(round, value)
  }

  func testTrueIsDecodedAsABooleanRatherThanTheNumberOne() throws {
    XCTAssertEqual(try JSONValue.parse("true"), .bool(true))
    XCTAssertEqual(try JSONValue.parse("1"), .int(1))
    XCTAssertNotEqual(try JSONValue.parse("true"), .int(1))
  }
}
