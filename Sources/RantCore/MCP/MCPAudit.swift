import Foundation

/// One line of the MCP audit trail.
public struct MCPAuditEntry: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let at: Date
  public let tool: String
  /// The request's arguments, redacted and truncated. Never the response.
  public let arguments: String
  public let resultCount: Int
  public let client: String?

  public init(id: Int64, at: Date, tool: String, arguments: String, resultCount: Int, client: String?) {
    self.id = id
    self.at = at
    self.tool = tool
    self.arguments = arguments
    self.resultCount = resultCount
    self.client = client
  }
}

/// Writes the record of what the MCP server was asked for.
///
/// The trail is the thing that makes the server safe to switch on: a local port that
/// serves your dictation history is only acceptable if you can go and look at what
/// it served. So every request is written, including the ones that were refused —
/// an agent probing for a collection the user did not share is exactly what someone
/// would want to see.
///
/// What is written is the *request*, never the response. The arguments go through
/// `SecretRedactor` and are truncated first, because a search query is user text
/// like any other and can contain a pasted credential; the answer is represented by
/// a count alone, so an audit table cannot become a second copy of the transcripts
/// it was meant to police.
public struct MCPAudit: Sendable {
  private let database: Database
  private let log = RantLog("MCP")

  /// Enough of a query to recognise it, not enough to be a transcript.
  public static let argumentLimit = 120
  /// A whole arguments object cannot be longer than this in the audit table.
  public static let totalLimit = 512

  public init(database: Database) {
    self.database = database
  }

  /// Records one request. Deliberately non-throwing: a full disk must not turn into
  /// a protocol error, and an audit failure is worth a log line rather than a
  /// broken session. The counterpart to that trade-off is that failures are loud in
  /// the log, not silent.
  public func record(tool: String, arguments: JSONValue, resultCount: Int, client: String?) {
    do {
      try database.run(
        """
        INSERT INTO mcp_audit (at, tool, arguments, result_count, client)
        VALUES (?,?,?,?,?)
        """,
        [
          SQLValue(Date()), .text(tool), .text(Self.redact(arguments)), .int(resultCount),
          SQLValue(client),
        ])
    } catch {
      log.error("could not write the MCP audit row for \(tool)")
    }
  }

  public func recent(limit: Int = 100) throws -> [MCPAuditEntry] {
    try database.query(
      """
      SELECT id, at, tool, arguments, result_count, client
      FROM mcp_audit ORDER BY at DESC, id DESC LIMIT ?
      """, [.int(limit)]
    ) { row in
      MCPAuditEntry(
        id: Int64(row.int(0)), at: row.date(1), tool: row.string(2), arguments: row.string(3),
        resultCount: row.int(4), client: row.stringOrNil(5))
    }
  }

  public func count() throws -> Int {
    try database.query("SELECT COUNT(*) FROM mcp_audit") { $0.int(0) }.first ?? 0
  }

  public func deleteAll() throws {
    try database.execute("DELETE FROM mcp_audit;")
  }

  /// Turns a request's arguments into the form that is safe to keep: every string
  /// scrubbed of credential shapes and cut to length, and the whole thing capped
  /// again afterwards so a deeply nested object cannot smuggle a long value through
  /// in pieces.
  public static func redact(_ value: JSONValue, redactor: SecretRedactor = SecretRedactor()) -> String {
    let text = shorten(value, redactor: redactor).encoded()
    guard text.count > totalLimit else { return text }
    return String(text.prefix(totalLimit)) + "…"
  }

  private static func shorten(_ value: JSONValue, redactor: SecretRedactor) -> JSONValue {
    switch value {
    case .string(let raw):
      let scrubbed = redactor.redact(raw)
      return .string(
        scrubbed.count > argumentLimit ? String(scrubbed.prefix(argumentLimit)) + "…" : scrubbed)
    case .array(let items):
      return .array(items.map { shorten($0, redactor: redactor) })
    case .object(let members):
      var out: [String: JSONValue] = [:]
      for (key, member) in members { out[key] = shorten(member, redactor: redactor) }
      return .object(out)
    default:
      return value
    }
  }
}
