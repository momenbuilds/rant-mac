import CryptoKit
import Foundation

/// A recorded meeting, without its transcript.
///
/// Segments live in their own table and are fetched separately, because the history
/// list needs a hundred meetings and none of their thousands of segments, and
/// loading an hour of transcript to draw a row would make the list stutter.
public struct Meeting: Equatable, Sendable {
  public var id: Int64?
  public var startedAt: Date
  public var endedAt: Date?
  public var title: String?
  /// The app the call was in — Zoom, Meet in a browser, and so on. Recorded for the
  /// history list, never for anything that leaves the machine.
  public var appName: String?
  public var calendarEventID: String?
  public var summary: String?
  public var actionItems: [String]
  public var decisions: [String]
  public var audioPath: String?
  public var contentHash: String
  public var source: String

  public init(
    id: Int64? = nil,
    startedAt: Date,
    endedAt: Date? = nil,
    title: String? = nil,
    appName: String? = nil,
    calendarEventID: String? = nil,
    summary: String? = nil,
    actionItems: [String] = [],
    decisions: [String] = [],
    audioPath: String? = nil,
    contentHash: String? = nil,
    source: String = "rant",
    transcript: String = ""
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.title = title
    self.appName = appName
    self.calendarEventID = calendarEventID
    self.summary = summary
    self.actionItems = actionItems
    self.decisions = decisions
    self.audioPath = audioPath
    self.source = source
    self.contentHash =
      contentHash ?? Meeting.hash(startedAt: startedAt, transcript: transcript, source: source)
  }

  public var durationMilliseconds: Int {
    guard let endedAt else { return 0 }
    return max(0, Int(endedAt.timeIntervalSince(startedAt) * 1000))
  }

  /// Identity for deduplication, on the same principle as `Transcript.hash`: start
  /// time to the second plus the transcript plus the source. Re-importing the same
  /// export is one meeting; two genuinely separate stand-ups are two, even if
  /// somebody said the same thing in both.
  public static func hash(startedAt: Date, transcript: String, source: String) -> String {
    let normalised = transcript.split(whereSeparator: \.isWhitespace)
      .joined(separator: " ").lowercased()
    let seconds = Int(startedAt.timeIntervalSince1970.rounded())
    let digest = SHA256.hash(data: Data("\(source)|\(seconds)|\(normalised)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// A search hit: which meeting, which segment, and the text FTS matched.
public struct MeetingSearchResult: Equatable, Sendable {
  public var meeting: Meeting
  public var segment: MeetingSegment
  public var snippet: String

  public init(meeting: Meeting, segment: MeetingSegment, snippet: String) {
    self.meeting = meeting
    self.segment = segment
    self.snippet = snippet
  }
}

/// Meetings and their transcripts, over SQLite.
///
/// Nothing here talks to the network, and there is no upload path to forget to turn
/// off: a meeting is a row in the same `rant.sqlite` file as everything else, which
/// the user can open with the `sqlite3` shell and delete with the Finder.
public struct MeetingStore: Sendable {
  private let database: Database
  private let log = RantLog("Notetaker")

  public init(database: Database) {
    self.database = database
  }

  private static let columns = """
    id, started_at, ended_at, title, app_name, calendar_event_id, summary, action_items,
    decisions, audio_path, content_hash, source
    """

  private static let prefixedColumns = columns
    .split(separator: ",")
    .map { "m.\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
    .joined(separator: ", ")

  private func decode(_ row: Row) -> Meeting {
    Meeting(
      id: Int64(row.int(0)),
      startedAt: row.date(1),
      endedAt: row.dateOrNil(2),
      title: row.stringOrNil(3),
      appName: row.stringOrNil(4),
      calendarEventID: row.stringOrNil(5),
      summary: row.stringOrNil(6),
      actionItems: MeetingList.decode(row.stringOrNil(7)),
      decisions: MeetingList.decode(row.stringOrNil(8)),
      audioPath: row.stringOrNil(9),
      contentHash: row.string(10),
      source: row.string(11))
  }

  private func decodeSegment(_ row: Row, offset: Int32) -> MeetingSegment {
    MeetingSegment(
      id: Int64(row.int(offset)),
      meetingID: Int64(row.int(offset + 1)),
      startedMilliseconds: row.int(offset + 2),
      endedMilliseconds: row.intOrNil(offset + 3),
      speaker: row.stringOrNil(offset + 4),
      channel: MeetingChannel(rawValue: row.string(offset + 5)) ?? .me,
      text: row.string(offset + 6))
  }

  // MARK: - Writing

  /// Inserts a meeting and its segments, or returns the existing row when the content
  /// hash already exists.
  ///
  /// The existence check comes before the insert, as it does for transcripts: an
  /// `INSERT OR IGNORE` that quietly did nothing would still leave us inserting the
  /// segments, and a re-import would then double every line of the transcript while
  /// the meeting row looked perfectly fine.
  @discardableResult
  public func save(_ meeting: Meeting, segments: [MeetingSegment] = []) throws -> Meeting {
    try database.transaction {
      if let existing = try database.query(
        "SELECT \(Self.columns) FROM meetings WHERE content_hash = ? LIMIT 1",
        [.text(meeting.contentHash)], decode
      ).first {
        return existing
      }

      try database.run(
        """
        INSERT INTO meetings
          (started_at, ended_at, title, app_name, calendar_event_id, summary, action_items,
           decisions, audio_path, content_hash, source)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """,
        [
          SQLValue(meeting.startedAt), SQLValue(meeting.endedAt), SQLValue(meeting.title),
          SQLValue(meeting.appName), SQLValue(meeting.calendarEventID),
          SQLValue(meeting.summary), SQLValue(MeetingList.encode(meeting.actionItems)),
          SQLValue(MeetingList.encode(meeting.decisions)), SQLValue(meeting.audioPath),
          .text(meeting.contentHash), .text(meeting.source),
        ])

      guard
        let stored = try database.query(
          "SELECT \(Self.columns) FROM meetings WHERE content_hash = ? LIMIT 1",
          [.text(meeting.contentHash)], decode
        ).first, let id = stored.id
      else { return meeting }

      for segment in segments { try insert(segment, meetingID: id) }
      log.info("saved meeting \(id) with \(segments.count) segments")
      return stored
    }
  }

  /// Appends segments to a meeting that is already stored — the live path, where the
  /// transcript grows while the meeting is still running.
  public func append(_ segments: [MeetingSegment], toMeeting id: Int64) throws {
    guard !segments.isEmpty else { return }
    try database.transaction {
      for segment in segments { try insert(segment, meetingID: id) }
    }
  }

  private func insert(_ segment: MeetingSegment, meetingID: Int64) throws {
    try database.run(
      """
      INSERT INTO meeting_segments (meeting_id, started_ms, ended_ms, speaker, channel, text)
      VALUES (?,?,?,?,?,?)
      """,
      [
        .int(Int(meetingID)), .int(segment.startedMilliseconds),
        SQLValue(segment.endedMilliseconds), SQLValue(segment.speaker),
        .text(segment.channel.rawValue), .text(segment.text),
      ])
  }

  public func setTitle(_ title: String?, forMeeting id: Int64) throws {
    try database.run("UPDATE meetings SET title = ? WHERE id = ?", [SQLValue(title), .int(Int(id))])
  }

  public func setEnded(_ date: Date?, forMeeting id: Int64) throws {
    try database.run(
      "UPDATE meetings SET ended_at = ? WHERE id = ?", [SQLValue(date), .int(Int(id))])
  }

  public func setCalendarEvent(_ eventID: String?, forMeeting id: Int64) throws {
    try database.run(
      "UPDATE meetings SET calendar_event_id = ? WHERE id = ?",
      [SQLValue(eventID), .int(Int(id))])
  }

  /// Stores what the summariser produced. Kept separate from `save` because
  /// summarising happens after the meeting is already safely on disk, and a slow or
  /// failed model must never be able to cost the transcript.
  public func setSummary(
    _ summary: String?, actionItems: [String], decisions: [String], forMeeting id: Int64
  ) throws {
    try database.run(
      "UPDATE meetings SET summary = ?, action_items = ?, decisions = ? WHERE id = ?",
      [
        SQLValue(summary), SQLValue(MeetingList.encode(actionItems)),
        SQLValue(MeetingList.encode(decisions)), .int(Int(id)),
      ])
  }

  // MARK: - Reading

  public func meeting(id: Int64) throws -> Meeting? {
    try database.query(
      "SELECT \(Self.columns) FROM meetings WHERE id = ?", [.int(Int(id))], decode
    ).first
  }

  public func recent(limit: Int = 50, offset: Int = 0) throws -> [Meeting] {
    try database.query(
      "SELECT \(Self.columns) FROM meetings ORDER BY started_at DESC LIMIT ? OFFSET ?",
      [.int(limit), .int(offset)], decode)
  }

  public func segments(forMeeting id: Int64) throws -> [MeetingSegment] {
    try database.query(
      """
      SELECT id, meeting_id, started_ms, ended_ms, speaker, channel, text
      FROM meeting_segments WHERE meeting_id = ? ORDER BY started_ms, id
      """,
      [.int(Int(id))]
    ) { decodeSegment($0, offset: 0) }
  }

  public func count() throws -> Int {
    try database.query("SELECT COUNT(*) FROM meetings") { $0.int(0) }.first ?? 0
  }

  /// Full-text search over segment text.
  ///
  /// The query goes through the same escaping as transcript search: terms become
  /// quoted prefix matches and everything else is dropped, because a user typing an
  /// apostrophe should get results rather than an FTS5 syntax error.
  public func search(_ query: String, limit: Int = 50) throws -> [MeetingSearchResult] {
    let expression = SQLiteTranscriptStore.ftsQuery(query)
    guard !expression.isEmpty else { return [] }
    return try database.query(
      """
      SELECT \(Self.prefixedColumns),
             s.id, s.meeting_id, s.started_ms, s.ended_ms, s.speaker, s.channel, s.text,
             snippet(meetings_fts, 0, '⟦', '⟧', '…', 12)
      FROM meetings_fts
      JOIN meeting_segments s ON s.id = meetings_fts.rowid
      JOIN meetings m ON m.id = s.meeting_id
      WHERE meetings_fts MATCH ?
      ORDER BY rank
      LIMIT ?
      """,
      [.text(expression), .int(limit)]
    ) { row in
      MeetingSearchResult(
        meeting: decode(row), segment: decodeSegment(row, offset: 12), snippet: row.string(19))
    }
  }

  // MARK: - Deleting

  /// Deletes a meeting and its transcript.
  ///
  /// The segments go first, explicitly, rather than being left to `ON DELETE
  /// CASCADE`. What keeps the FTS index honest is the `meeting_segments_ad` trigger,
  /// and whether a cascade fires a child table's triggers depends on how the
  /// connection is configured and has not always been the same across SQLite
  /// versions. Getting that wrong leaves the index holding the words of a meeting the
  /// user has deleted, which then keeps turning up in search — a deletion that does
  /// not delete is the one storage bug users never forgive. Two statements cost
  /// nothing and do not depend on the answer.
  public func delete(id: Int64) throws {
    try database.transaction {
      try database.run("DELETE FROM meeting_segments WHERE meeting_id = ?", [.int(Int(id))])
      try database.run("DELETE FROM meetings WHERE id = ?", [.int(Int(id))])
    }
  }

  public func deleteAll() throws {
    try database.transaction {
      try database.execute("DELETE FROM meeting_segments;")
      try database.execute("DELETE FROM meetings;")
    }
  }
}

/// Encodes a list of short strings into one TEXT column.
///
/// JSON rather than newline-joined text, so an action item that itself contains a
/// newline survives the round trip. Decoding accepts plain lines too, because an
/// import from another tool will not have written JSON and losing the data would be
/// worse than accepting a looser format.
public enum MeetingList {
  public static func encode(_ items: [String]) -> String? {
    let cleaned = items
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    guard let data = try? JSONEncoder().encode(cleaned) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  public static func decode(_ stored: String?) -> [String] {
    guard let stored, !stored.isEmpty else { return [] }
    if let data = stored.data(using: .utf8),
      let items = try? JSONDecoder().decode([String].self, from: data)
    {
      return items
    }
    return stored.split(separator: "\n")
      .map { line -> String in
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
          text = String(text.dropFirst(marker.count))
        }
        return text
      }
      .filter { !$0.isEmpty }
  }
}
