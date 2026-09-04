import Foundation

/// A failure a tool can report to the client. Carries a JSON-RPC code so that
/// "you have not granted this" and "there is no transcript 9999" are distinguishable
/// by a machine, not only by reading the message.
public struct MCPToolError: Error, Equatable {
  public let code: Int
  public let message: String

  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
}

/// What a tool produced: the JSON the client receives, and how many records it
/// represents. The count exists for the audit row — a number is enough to spot an
/// agent hoovering up the whole history, and it is not itself a copy of the data.
public struct MCPToolResult: Sendable, Equatable {
  public let payload: JSONValue
  public let count: Int

  public init(payload: JSONValue, count: Int) {
    self.payload = payload
    self.count = count
  }
}

/// One tool: what it is called, what it does, what it accepts, and — the part that
/// matters here — which collection it reads and whether it writes.
public struct MCPTool: Sendable {
  public let name: String
  public let description: String
  public let collection: MCPCollection
  public let inputSchema: JSONValue

  /// The MCP `tools/list` entry.
  public var descriptor: JSONValue {
    .object([
      "name": .string(name),
      "description": .string(description),
      "inputSchema": inputSchema,
    ])
  }

  public var isWrite: Bool { collection == .control }

  // MARK: - The catalogue

  public static let searchTranscripts = MCPTool(
    name: "rant_search_transcripts",
    description: "Full-text search over your own dictation history. Returns matching snippets with the app and time each dictation was made, newest matches first.",
    collection: .transcripts,
    inputSchema: schema(
      properties: [
        "query": stringProperty("Words to search for."),
        "limit": intProperty("How many results to return (1–\(maximumLimit), default \(defaultLimit))."),
      ], required: ["query"]))

  public static let getTranscript = MCPTool(
    name: "rant_get_transcript",
    description: "Fetch one dictation by its identifier, including its full cleaned text.",
    collection: .transcripts,
    inputSchema: schema(
      properties: ["id": intProperty("The transcript identifier from a search result.")],
      required: ["id"]))

  public static let searchMeetings = MCPTool(
    name: "rant_search_meetings",
    description: "Full-text search over recorded meetings. Returns the meetings whose transcript segments match, most recent first.",
    collection: .meetings,
    inputSchema: schema(
      properties: [
        "query": stringProperty("Words to search for."),
        "limit": intProperty("How many meetings to return (1–\(maximumLimit), default \(defaultLimit))."),
      ], required: ["query"]))

  public static let getMeeting = MCPTool(
    name: "rant_get_meeting",
    description: "Fetch one meeting by its identifier, with its summary, decisions, action items and transcript segments.",
    collection: .meetings,
    inputSchema: schema(
      properties: ["id": intProperty("The meeting identifier from a search result.")],
      required: ["id"]))

  public static let searchNotes = MCPTool(
    name: "rant_search_notes",
    description: "Full-text search over your notes. Returns titles and matching extracts, most recently updated first.",
    collection: .notes,
    inputSchema: schema(
      properties: [
        "query": stringProperty("Words to search for."),
        "limit": intProperty("How many notes to return (1–\(maximumLimit), default \(defaultLimit))."),
      ], required: ["query"]))

  public static let getStats = MCPTool(
    name: "rant_get_stats",
    description: "Aggregate dictation statistics: words, dictations, time spoken and the breakdown by category. Counts only — no transcript text.",
    collection: .stats,
    inputSchema: schema(
      properties: [
        "period": .object([
          "type": .string("string"),
          "description": .string("Which window to report on."),
          "enum": .array(MCPStatsPeriod.allCases.map { .string($0.rawValue) }),
        ])
      ], required: []))

  public static let getCurrentContext = MCPTool(
    name: "rant_get_current_context",
    description: "Describe where the user is typing right now: the frontmost app, the browser host, and the kind of field focused. Metadata only — never the surrounding text.",
    collection: .context,
    inputSchema: schema(properties: [:], required: []))

  public static let startDictation = MCPTool(
    name: "rant_start_dictation",
    description: "Start recording a dictation. Requires write access, which is granted separately from read access.",
    collection: .control,
    inputSchema: schema(properties: [:], required: []))

  public static let stopDictation = MCPTool(
    name: "rant_stop_dictation",
    description: "Stop the dictation that is in progress. Requires write access, which is granted separately from read access.",
    collection: .control,
    inputSchema: schema(properties: [:], required: []))

  public static let all: [MCPTool] = [
    searchTranscripts, getTranscript, searchMeetings, getMeeting, searchNotes, getStats,
    getCurrentContext, startDictation, stopDictation,
  ]

  public static func named(_ name: String) -> MCPTool? {
    all.first { $0.name == name }
  }

  // MARK: - Schema helpers

  static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map { .string($0) }),
      "additionalProperties": .bool(false),
    ])
  }

  static func stringProperty(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }

  static func intProperty(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  // MARK: - Argument reading

  public static let defaultLimit = 20
  public static let maximumLimit = 100

  static func requiredString(_ arguments: JSONValue, _ key: String) throws -> String {
    guard let value = arguments[key] else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "Missing \(key).")
    }
    guard let string = value.stringValue else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "\(key) must be a string.")
    }
    return string
  }

  static func requiredInt(_ arguments: JSONValue, _ key: String) throws -> Int {
    guard let value = arguments[key] else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "Missing \(key).")
    }
    guard let number = value.intValue else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "\(key) must be an integer.")
    }
    return number
  }

  /// Clamped rather than rejected at the top end: an agent asking for ten thousand
  /// rows has misjudged, not misbehaved, and a hundred results is a better answer
  /// than an error. A limit of the wrong *type* is still a mistake worth reporting.
  static func limit(_ arguments: JSONValue) throws -> Int {
    guard let value = arguments["limit"], value != .null else { return defaultLimit }
    guard let number = value.intValue else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "limit must be an integer.")
    }
    return min(max(number, 1), maximumLimit)
  }
}

/// The windows `rant_get_stats` understands.
public enum MCPStatsPeriod: String, Sendable, CaseIterable {
  case today, week, month, all

  static func parse(_ value: JSONValue?) throws -> MCPStatsPeriod {
    guard let value, value != .null else { return .week }
    guard let raw = value.stringValue else {
      throw MCPToolError(code: MCPErrorCode.invalidParams, message: "period must be a string.")
    }
    guard let period = MCPStatsPeriod(rawValue: raw) else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams,
        message: "period must be one of: \(MCPStatsPeriod.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return period
  }

  /// The first day included, as `yyyy-MM-dd`, or nil for everything.
  func firstDay(from now: Date, calendar: Calendar = .current) -> String? {
    let days: Int
    switch self {
    case .today: days = 0
    case .week: days = 6
    case .month: days = 29
    case .all: return nil
    }
    let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
    return SQLiteTranscriptStore.dayFormatter.string(from: start)
  }
}

/// Reads the user's data for the MCP tools, and is the only place that decides what
/// a tool is allowed to say.
///
/// Two rules hold for every field emitted here. Nothing leaves without passing
/// through `SecretRedactor` — history is full of pasted API keys, and an agent that
/// searches for "deploy" should not receive one. And nothing filesystem-shaped
/// leaves at all: the retained-audio path is a real column on `transcripts`, and it
/// is simply never selected, because a path is both useless to the caller and a map
/// of the user's machine.
struct MCPDataSource: Sendable {
  private let database: Database
  private let redactor = SecretRedactor()
  private let log = RantLog("MCP")

  /// Long enough to judge relevance, short enough that a search is not an export.
  static let previewCharacters = 400

  init(database: Database) {
    self.database = database
  }

  private func clean(_ text: String, limit: Int? = nil) -> JSONValue {
    var result = redactor.redact(text)
    if let limit, result.count > limit {
      result = String(result.prefix(limit)) + "…"
    }
    return .string(result)
  }

  /// `ISO8601Format()` rather than a shared `ISO8601DateFormatter`: the formatter is
  /// not `Sendable`, and a cached one on a value type used from an actor is the
  /// classic way to get a data race out of a date.
  private func when(_ date: Date) -> JSONValue { .string(date.ISO8601Format()) }

  // MARK: - Transcripts

  func searchTranscripts(query: String, limit: Int) throws -> MCPToolResult {
    let expression = SQLiteTranscriptStore.ftsQuery(query)
    guard !expression.isEmpty else {
      return MCPToolResult(payload: .object(["results": .array([])]), count: 0)
    }
    let rows = try database.query(
      """
      SELECT t.id, t.created_at, t.app_name, t.category, t.word_count,
             snippet(transcripts_fts, 0, '', '', '…', 16)
      FROM transcripts_fts
      JOIN transcripts t ON t.id = transcripts_fts.rowid
      WHERE transcripts_fts MATCH ?
      ORDER BY rank
      LIMIT ?
      """, [.text(expression), .int(limit)]
    ) { row in
      JSONValue.object([
        "id": .int(row.int(0)),
        "created_at": when(row.date(1)),
        "app": .string(row.stringOrNil(2) ?? ""),
        "category": .string(row.string(3)),
        "word_count": .int(row.int(4)),
        "snippet": clean(row.string(5), limit: Self.previewCharacters),
      ])
    }
    return MCPToolResult(payload: .object(["results": .array(rows)]), count: rows.count)
  }

  func transcript(id: Int) throws -> MCPToolResult {
    let rows = try database.query(
      """
      SELECT id, created_at, final_text, app_name, browser_host, category, word_count,
             duration_ms, language
      FROM transcripts WHERE id = ?
      """, [.int(id)]
    ) { row in
      JSONValue.object([
        "id": .int(row.int(0)),
        "created_at": when(row.date(1)),
        "text": clean(row.string(2)),
        "app": .string(row.stringOrNil(3) ?? ""),
        "browser_host": .string(row.stringOrNil(4) ?? ""),
        "category": .string(row.string(5)),
        "word_count": .int(row.int(6)),
        "duration_ms": .int(row.int(7)),
        "language": .string(row.stringOrNil(8) ?? ""),
      ])
    }
    guard let transcript = rows.first else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams, message: "There is no transcript with id \(id).")
    }
    return MCPToolResult(payload: transcript, count: 1)
  }

  // MARK: - Meetings

  /// The match runs over segments but the answer is meetings, so the FTS hit is a
  /// subquery rather than a join with `GROUP BY`: one meeting appears once however
  /// many of its segments matched.
  func searchMeetings(query: String, limit: Int) throws -> MCPToolResult {
    let expression = SQLiteTranscriptStore.ftsQuery(query)
    guard !expression.isEmpty else {
      return MCPToolResult(payload: .object(["results": .array([])]), count: 0)
    }
    let rows = try database.query(
      """
      SELECT m.id, m.started_at, m.ended_at, m.title, m.app_name, m.summary
      FROM meetings m
      WHERE m.id IN (
        SELECT s.meeting_id FROM meetings_fts
        JOIN meeting_segments s ON s.id = meetings_fts.rowid
        WHERE meetings_fts MATCH ?
      )
      ORDER BY m.started_at DESC
      LIMIT ?
      """, [.text(expression), .int(limit)]
    ) { row in
      JSONValue.object([
        "id": .int(row.int(0)),
        "started_at": when(row.date(1)),
        "ended_at": row.dateOrNil(2).map(when) ?? .null,
        "title": clean(row.stringOrNil(3) ?? ""),
        "app": .string(row.stringOrNil(4) ?? ""),
        "summary": clean(row.stringOrNil(5) ?? "", limit: Self.previewCharacters),
      ])
    }
    return MCPToolResult(payload: .object(["results": .array(rows)]), count: rows.count)
  }

  func meeting(id: Int) throws -> MCPToolResult {
    let meetings = try database.query(
      """
      SELECT id, started_at, ended_at, title, app_name, summary, action_items, decisions
      FROM meetings WHERE id = ?
      """, [.int(id)]
    ) { row in
      JSONValue.object([
        "id": .int(row.int(0)),
        "started_at": when(row.date(1)),
        "ended_at": row.dateOrNil(2).map(when) ?? .null,
        "title": clean(row.stringOrNil(3) ?? ""),
        "app": .string(row.stringOrNil(4) ?? ""),
        "summary": clean(row.stringOrNil(5) ?? ""),
        "action_items": clean(row.stringOrNil(6) ?? ""),
        "decisions": clean(row.stringOrNil(7) ?? ""),
      ])
    }
    guard case .object(var meeting)? = meetings.first else {
      throw MCPToolError(
        code: MCPErrorCode.invalidParams, message: "There is no meeting with id \(id).")
    }

    let segments = try database.query(
      """
      SELECT started_ms, ended_ms, speaker, channel, text
      FROM meeting_segments WHERE meeting_id = ? ORDER BY started_ms
      """, [.int(id)]
    ) { row in
      JSONValue.object([
        "started_ms": .int(row.int(0)),
        "ended_ms": row.intOrNil(1).map { JSONValue.int($0) } ?? .null,
        "speaker": .string(row.stringOrNil(2) ?? ""),
        "channel": .string(row.string(3)),
        "text": clean(row.string(4)),
      ])
    }
    meeting["segments"] = .array(segments)
    return MCPToolResult(payload: .object(meeting), count: 1)
  }

  // MARK: - Notes

  func searchNotes(query: String, limit: Int) throws -> MCPToolResult {
    let expression = SQLiteTranscriptStore.ftsQuery(query)
    guard !expression.isEmpty else {
      return MCPToolResult(payload: .object(["results": .array([])]), count: 0)
    }
    let rows = try database.query(
      """
      SELECT n.id, n.created_at, n.updated_at, n.title, n.body, n.tags, n.pinned
      FROM notes n
      WHERE n.id IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?)
      ORDER BY n.updated_at DESC
      LIMIT ?
      """, [.text(expression), .int(limit)]
    ) { row in
      JSONValue.object([
        "id": .int(row.int(0)),
        "created_at": when(row.date(1)),
        "updated_at": when(row.date(2)),
        "title": clean(row.string(3)),
        "extract": clean(row.string(4), limit: Self.previewCharacters),
        "tags": .string(row.stringOrNil(5) ?? ""),
        "pinned": .bool(row.bool(6)),
      ])
    }
    return MCPToolResult(payload: .object(["results": .array(rows)]), count: rows.count)
  }

  // MARK: - Statistics

  /// Reads the pre-aggregated tables rather than the transcripts, which keeps the
  /// stats tool structurally incapable of returning anything anyone said.
  func stats(period: MCPStatsPeriod, now: Date = Date()) throws -> MCPToolResult {
    let day = period.firstDay(from: now)
    let bound: [SQLValue] = day.map { [.text($0)] } ?? []
    let filter = day == nil ? "" : "WHERE day >= ?"

    let totals = try database.query(
      """
      SELECT COALESCE(SUM(words),0), COALESCE(SUM(dictations),0), COALESCE(SUM(duration_ms),0),
             COUNT(*)
      FROM usage_daily \(filter)
      """, bound
    ) { row in
      (words: row.int(0), dictations: row.int(1), duration: row.int(2), days: row.int(3))
    }.first ?? (words: 0, dictations: 0, duration: 0, days: 0)

    let categories = try database.query(
      """
      SELECT category, SUM(words) FROM app_usage \(filter)
      GROUP BY category ORDER BY SUM(words) DESC
      """, bound
    ) { row in (name: row.string(0), words: row.int(1)) }

    var breakdown: [String: JSONValue] = [:]
    for entry in categories { breakdown[entry.name] = .int(entry.words) }

    return MCPToolResult(
      payload: .object([
        "period": .string(period.rawValue),
        "from": day.map { JSONValue.string($0) } ?? .null,
        "words": .int(totals.words),
        "dictations": .int(totals.dictations),
        "duration_ms": .int(totals.duration),
        "active_days": .int(totals.days),
        "words_by_category": .object(breakdown),
      ]), count: 1)
  }

  // MARK: - Context

  /// Metadata about the focused field, and nothing that was typed into it.
  ///
  /// `TranscriptionContext` carries the text around the cursor, the selection, the
  /// clipboard and OCR output. All of it is on-device material for choosing a style,
  /// and none of it is answered here: an agent asking "where am I?" is told which
  /// app and which kind of field, which is what the question is for. Lengths go out
  /// instead of contents, because an agent deciding whether to wait for the user to
  /// finish typing needs the shape, not the words. A secure field reports nothing
  /// but the fact that it is one.
  static func describe(_ context: TranscriptionContext?) -> MCPToolResult {
    guard let context else {
      return MCPToolResult(payload: .object(["available": .bool(false)]), count: 0)
    }
    if context.isSecureField {
      return MCPToolResult(
        payload: .object(["available": .bool(true), "secure_field": .bool(true)]), count: 1)
    }
    return MCPToolResult(
      payload: .object([
        "available": .bool(true),
        "secure_field": .bool(false),
        "app": .string(context.appName ?? ""),
        "bundle_id": .string(context.appBundleID ?? ""),
        "browser_host": .string(context.browserHost ?? ""),
        "field_role": .string(context.fieldRole ?? ""),
        "field_label": .string(context.fieldLabel ?? ""),
        "selection_length": .int(context.selectedText?.count ?? 0),
        "text_before_cursor_length": .int(context.textBeforeCursor?.count ?? 0),
      ]), count: 1)
  }
}
