import Foundation

/// A minimal JSON tree.
///
/// `JSONSerialization` hands back `Any`, which cannot cross an actor boundary under
/// strict concurrency and cannot be compared in a test without casting at every step.
/// Converting once, at the edge, buys a `Sendable`, `Equatable` value for the rest of
/// the server — and an encoder that sorts its keys, so a response is a stable string
/// rather than something that reorders between runs.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    guard case .object(let members) = self else { return nil }
    return members[key]
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    switch self {
    case .int(let value): value
    case .double(let value): value.rounded() == value ? Int(value) : nil
    default: nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var isObject: Bool {
    if case .object = self { return true }
    return false
  }

  // MARK: - Parsing

  public enum ParseError: Error, Equatable {
    case malformed
  }

  /// Parses a JSON document. Fragments are allowed so that a client sending `null`
  /// or a bare number gets an "invalid request" rather than a parse error the caller
  /// then has to tell apart from a truncated message.
  public static func parse(_ text: String) throws -> JSONValue {
    guard let data = text.data(using: .utf8) else { throw ParseError.malformed }
    guard
      let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { throw ParseError.malformed }
    return from(any)
  }

  static func from(_ any: Any) -> JSONValue {
    switch any {
    case is NSNull: return .null
    case let number as NSNumber:
      // `true` and `1` are both NSNumber; only the CFBoolean type tells them apart,
      // and getting this wrong turns a boolean argument into the integer 1.
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      let double = number.doubleValue
      if double.rounded() == double, abs(double) < 9e15 { return .int(number.intValue) }
      return .double(double)
    case let string as String: return .string(string)
    case let array as [Any]: return .array(array.map(from))
    case let object as [String: Any]:
      var members: [String: JSONValue] = [:]
      for (key, value) in object { members[key] = from(value) }
      return .object(members)
    default: return .null
    }
  }

  // MARK: - Encoding

  /// Hand-written rather than `JSONSerialization.data` so keys come out sorted and
  /// the output is byte-stable — which is what makes a protocol test a string
  /// comparison instead of a re-parse.
  public func encoded() -> String {
    switch self {
    case .null: "null"
    case .bool(let value): value ? "true" : "false"
    case .int(let value): String(value)
    case .double(let value): value.isFinite ? String(value) : "0"
    case .string(let value): Self.quote(value)
    case .array(let items): "[" + items.map { $0.encoded() }.joined(separator: ",") + "]"
    case .object(let members):
      "{"
        + members.keys.sorted()
        .map { key in "\(Self.quote(key)):\((members[key] ?? .null).encoded())" }
        .joined(separator: ",") + "}"
    }
  }

  static func quote(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}

/// Which of the user's collections a tool reads.
///
/// Consent is per-collection because "let my coding agent search my code notes" and
/// "let my coding agent read every meeting I have recorded" are not the same
/// decision, and a single on/off switch forces the user to make the larger one in
/// order to get the smaller.
public enum MCPCollection: String, Sendable, Codable, CaseIterable {
  case transcripts, meetings, notes, stats, context
  /// Not a collection the user picks: the class every write-shaped tool belongs to,
  /// gated by `allowWrite` instead.
  case control
}

/// What the user has switched on. Every default here is the closed one.
public struct MCPSettings: Sendable, Equatable, Codable {
  /// Off until the user turns it on. No build, flag or upgrade path starts this
  /// server on its own.
  public var enabled: Bool
  /// Write-class tools — the ones that make the machine do something rather than
  /// tell the caller something — need a second, separate grant.
  public var allowWrite: Bool
  /// The collections the user has exposed. Empty is a working configuration: the
  /// server answers `tools/list` and refuses every tool.
  public var collections: Set<MCPCollection>
  /// Where the optional socket listener binds. Validated, never trusted.
  public var host: String
  public var port: Int

  public init(
    enabled: Bool = false,
    allowWrite: Bool = false,
    collections: Set<MCPCollection> = [],
    host: String = "127.0.0.1",
    port: Int = 7373
  ) {
    self.enabled = enabled
    self.allowWrite = allowWrite
    self.collections = collections
    self.host = host
    self.port = port
  }

  public static let disabled = MCPSettings()

  public func allows(_ collection: MCPCollection) -> Bool {
    collection == .control ? allowWrite : collections.contains(collection)
  }

  /// The address the listener may use, or the reason it may not.
  public func bindAddress() throws -> MCPBindAddress {
    try MCPBindAddress(host: host, port: port)
  }
}

/// Where a socket listener may bind.
///
/// A dictation history reachable from the local network is a different product from
/// one reachable from the editor on the same machine, and the difference is a single
/// string in a settings file. So the address is parsed into this type before anything
/// binds, and there is no way to construct it from an address that is not loopback.
public struct MCPBindAddress: Sendable, Equatable {
  public let host: String
  public let port: Int

  public enum Failure: Error, Equatable, LocalizedError {
    case notLoopback(String)
    case invalidPort(Int)

    public var errorDescription: String? {
      switch self {
      case .notLoopback(let host):
        "Rant's MCP server only listens on the loopback interface; \(host) is not one."
      case .invalidPort(let port):
        "\(port) is not a usable port."
      }
    }
  }

  public init(host: String, port: Int) throws {
    guard Self.isLoopback(host) else { throw Failure.notLoopback(host) }
    guard (1...65_535).contains(port) else { throw Failure.invalidPort(port) }
    self.host = host
    self.port = port
  }

  /// Loopback is the whole 127.0.0.0/8 block, `::1`, and the name that resolves to
  /// them. Anything else — including `0.0.0.0` and `::`, the two spellings of "every
  /// interface" that people reach for first — is refused.
  public static func isLoopback(_ host: String) -> Bool {
    let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed == "localhost" || trimmed == "::1" || trimmed == "[::1]" { return true }
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
    return numbers[0] == 127
  }
}

/// Starting and stopping dictation from outside the app. Injected, and absent by
/// default, so a build that never wires one up cannot be talked into recording.
public protocol MCPDictationControlling: Sendable {
  func startDictation() async throws
  func stopDictation() async throws
}

/// The live context, for the one tool that reports it.
public protocol MCPContextProviding: Sendable {
  func currentContext() async -> TranscriptionContext?
}

/// JSON-RPC error codes. The first five are the standard ones; the Rant-specific
/// codes live in the implementation-defined server range so a client can tell "you
/// have not granted this" apart from "you asked for something that does not exist".
public enum MCPErrorCode {
  public static let parse = -32_700
  public static let invalidRequest = -32_600
  public static let methodNotFound = -32_601
  public static let invalidParams = -32_602
  public static let internalError = -32_603
  /// The tool exists, but the user has not exposed that collection.
  public static let collectionNotEnabled = -32_002
  /// The tool exists, but write access has not been granted.
  public static let writeNotAllowed = -32_003
}

/// The optional local MCP server.
///
/// Transport-free on purpose: `handle(_:)` takes one JSON-RPC message as a string
/// and returns the reply as a string, or nil for a notification or a server that is
/// switched off. Sockets and pipes are somebody else's problem, which is what lets
/// the protocol, the consent rules and the adversarial-input handling be tested
/// without opening a file descriptor.
public actor MCPServer {
  private var settings: MCPSettings
  private let source: MCPDataSource
  private let audit: MCPAudit
  private let dictation: MCPDictationControlling?
  private let context: MCPContextProviding?
  private let log = RantLog("MCP")

  /// A request larger than this is refused before it is parsed. The largest honest
  /// request is a search query and a limit; a quarter-megabyte of JSON is either a
  /// bug or somebody probing for a parser that allocates whatever it is handed.
  public static let maximumRequestBytes = 256 * 1024

  private var clientName: String?

  public init(
    settings: MCPSettings = .disabled,
    database: Database,
    dictation: MCPDictationControlling? = nil,
    context: MCPContextProviding? = nil
  ) {
    self.settings = settings
    self.source = MCPDataSource(database: database)
    self.audit = MCPAudit(database: database)
    self.dictation = dictation
    self.context = context
  }

  public func update(settings: MCPSettings) {
    self.settings = settings
    log.info(
      "settings updated: enabled=\(settings.enabled) write=\(settings.allowWrite) collections=\(settings.collections.count)"
    )
  }

  public var currentSettings: MCPSettings { settings }

  /// The audit trail, newest first. Exposed so the settings screen can show the user
  /// what their agents have been asking for.
  public func recentAudit(limit: Int = 100) throws -> [MCPAuditEntry] {
    try audit.recent(limit: limit)
  }

  // MARK: - Dispatch

  /// Handles one message. Returns nil when there is nothing to send back: a
  /// notification, or a server the user has not enabled.
  public func handle(_ message: String) async -> String? {
    guard settings.enabled else {
      // Not an error reply, and not an audit row: a server that was never switched
      // on should be indistinguishable from one that was never built.
      log.debug("request ignored, server disabled")
      return nil
    }

    guard message.utf8.count <= Self.maximumRequestBytes else {
      audit.record(tool: "invalid", arguments: .string("oversized"), resultCount: 0, client: clientName)
      return failure(id: .null, code: MCPErrorCode.invalidRequest, message: "Request too large.")
    }

    let parsed: JSONValue
    do {
      parsed = try JSONValue.parse(message)
    } catch {
      audit.record(
        tool: "invalid", arguments: .string("unparseable"), resultCount: 0, client: clientName)
      return failure(id: .null, code: MCPErrorCode.parse, message: "Could not parse JSON.")
    }

    guard parsed.isObject else {
      // Includes batches. Rant's server is one request at a time, and saying so is
      // better than half-supporting an array.
      audit.record(
        tool: "invalid", arguments: .string("not an object"), resultCount: 0, client: clientName)
      return failure(
        id: .null, code: MCPErrorCode.invalidRequest,
        message: "Expected a single JSON-RPC object.")
    }

    let id = parsed["id"]
    guard let method = parsed["method"]?.stringValue else {
      audit.record(
        tool: "invalid", arguments: .string("no method"), resultCount: 0, client: clientName)
      guard let id else { return nil }
      return failure(id: id, code: MCPErrorCode.invalidRequest, message: "Missing method.")
    }

    if let version = parsed["jsonrpc"]?.stringValue, version != "2.0" {
      audit.record(
        tool: method, arguments: .string("bad version"), resultCount: 0, client: clientName)
      guard let id else { return nil }
      return failure(
        id: id, code: MCPErrorCode.invalidRequest, message: "Unsupported JSON-RPC version.")
    }

    let params = parsed["params"] ?? .object([:])
    let outcome = await perform(method: method, params: params)

    // A notification carries no id and gets no reply — but it is still audited,
    // because the point of the audit is what was asked, not what was answered.
    guard let id else { return nil }
    switch outcome {
    case .success(let result):
      return reply(id: id, result: result)
    case .failure(let code, let message):
      return failure(id: id, code: code, message: message)
    }
  }

  private enum Outcome {
    case success(JSONValue)
    case failure(code: Int, message: String)
  }

  private func perform(method: String, params: JSONValue) async -> Outcome {
    switch method {
    case "initialize":
      clientName = params["clientInfo"]?["name"]?.stringValue
      audit.record(tool: "initialize", arguments: params, resultCount: 0, client: clientName)
      return .success(
        .object([
          "protocolVersion": .string(Self.protocolVersion),
          "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
          "serverInfo": .object(["name": .string("rant"), "version": .string("1.0.0")]),
        ]))

    case "notifications/initialized", "initialized":
      return .success(.object([:]))

    case "ping":
      return .success(.object([:]))

    case "tools/list":
      audit.record(
        tool: "tools/list", arguments: .object([:]), resultCount: MCPTool.all.count,
        client: clientName)
      // Every tool is listed regardless of consent. Hiding the ungranted ones would
      // leak which collections the user keeps and leave the agent guessing why a
      // documented tool is missing; refusing at call time says so out loud.
      return .success(.object(["tools": .array(MCPTool.all.map(\.descriptor))]))

    case "tools/call":
      return await call(params: params)

    default:
      audit.record(
        tool: method, arguments: .string("unknown method"), resultCount: 0, client: clientName)
      return .failure(code: MCPErrorCode.methodNotFound, message: "Unknown method: \(method).")
    }
  }

  public static let protocolVersion = "2024-11-05"

  private func call(params: JSONValue) async -> Outcome {
    guard let name = params["name"]?.stringValue else {
      audit.record(
        tool: "tools/call", arguments: .string("no tool name"), resultCount: 0, client: clientName)
      return .failure(code: MCPErrorCode.invalidParams, message: "Missing tool name.")
    }
    let arguments = params["arguments"] ?? .object([:])
    guard arguments.isObject else {
      audit.record(
        tool: name, arguments: .string("bad arguments"), resultCount: 0, client: clientName)
      return .failure(code: MCPErrorCode.invalidParams, message: "Arguments must be an object.")
    }

    guard let tool = MCPTool.named(name) else {
      audit.record(tool: name, arguments: arguments, resultCount: 0, client: clientName)
      return .failure(code: MCPErrorCode.methodNotFound, message: "Unknown tool: \(name).")
    }

    // Consent first, work second — the check has to be impossible to fall past.
    guard settings.allows(tool.collection) else {
      audit.record(tool: name, arguments: arguments, resultCount: 0, client: clientName)
      if tool.collection == .control {
        return .failure(
          code: MCPErrorCode.writeNotAllowed,
          message: "\(name) needs write access, which has not been granted.")
      }
      return .failure(
        code: MCPErrorCode.collectionNotEnabled,
        message: "The \(tool.collection.rawValue) collection is not shared with MCP clients.")
    }

    do {
      let result = try await run(tool, arguments: arguments)
      audit.record(
        tool: name, arguments: arguments, resultCount: result.count, client: clientName)
      return .success(
        .object([
          "content": .array([
            .object(["type": .string("text"), "text": .string(result.payload.encoded())])
          ]),
          "isError": .bool(false),
        ]))
    } catch let error as MCPToolError {
      audit.record(tool: name, arguments: arguments, resultCount: 0, client: clientName)
      return .failure(code: error.code, message: error.message)
    } catch {
      audit.record(tool: name, arguments: arguments, resultCount: 0, client: clientName)
      log.error("tool \(name) failed")
      return .failure(code: MCPErrorCode.internalError, message: "The tool failed.")
    }
  }

  private func run(_ tool: MCPTool, arguments: JSONValue) async throws -> MCPToolResult {
    switch tool.name {
    case MCPTool.searchTranscripts.name:
      return try source.searchTranscripts(
        query: try MCPTool.requiredString(arguments, "query"),
        limit: try MCPTool.limit(arguments))
    case MCPTool.getTranscript.name:
      return try source.transcript(id: try MCPTool.requiredInt(arguments, "id"))
    case MCPTool.searchMeetings.name:
      return try source.searchMeetings(
        query: try MCPTool.requiredString(arguments, "query"),
        limit: try MCPTool.limit(arguments))
    case MCPTool.getMeeting.name:
      return try source.meeting(id: try MCPTool.requiredInt(arguments, "id"))
    case MCPTool.searchNotes.name:
      return try source.searchNotes(
        query: try MCPTool.requiredString(arguments, "query"),
        limit: try MCPTool.limit(arguments))
    case MCPTool.getStats.name:
      return try source.stats(period: try MCPStatsPeriod.parse(arguments["period"]))
    case MCPTool.getCurrentContext.name:
      return MCPDataSource.describe(await context?.currentContext())
    case MCPTool.startDictation.name:
      guard let dictation else {
        throw MCPToolError(
          code: MCPErrorCode.internalError, message: "Dictation control is unavailable.")
      }
      try await dictation.startDictation()
      return MCPToolResult(payload: .object(["started": .bool(true)]), count: 1)
    case MCPTool.stopDictation.name:
      guard let dictation else {
        throw MCPToolError(
          code: MCPErrorCode.internalError, message: "Dictation control is unavailable.")
      }
      try await dictation.stopDictation()
      return MCPToolResult(payload: .object(["stopped": .bool(true)]), count: 1)
    default:
      throw MCPToolError(code: MCPErrorCode.methodNotFound, message: "Unknown tool: \(tool.name).")
    }
  }

  // MARK: - Framing

  private func reply(id: JSONValue, result: JSONValue) -> String {
    JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded()
  }

  private func failure(id: JSONValue, code: Int, message: String) -> String {
    JSONValue.object([
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .int(code), "message": .string(message)]),
    ]).encoded()
  }
}

/// Reads newline-delimited JSON-RPC from a stream and writes replies back.
///
/// The whole transport, and deliberately dull: line in, line out. stdio and a
/// loopback socket differ only in where the lines come from, so neither of them gets
/// to hold any protocol knowledge.
public struct MCPLineTransport: Sendable {
  private let server: MCPServer

  public init(server: MCPServer) {
    self.server = server
  }

  public func run(
    lines: AsyncStream<String>,
    output: @Sendable @escaping (String) -> Void
  ) async {
    for await line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if let reply = await server.handle(trimmed) { output(reply) }
    }
  }
}
