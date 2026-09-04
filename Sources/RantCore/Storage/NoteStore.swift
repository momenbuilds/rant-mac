import CryptoKit
import Foundation

/// One scratchpad note: Markdown, on your machine, in a table you can read with the
/// `sqlite3` shell.
public struct Note: Equatable, Sendable, Identifiable {
  public var id: Int64?
  public var createdAt: Date
  public var updatedAt: Date
  public var title: String
  /// Markdown. Rant never renders it on the way in, so what you dictated is what is
  /// stored and what an export gives back.
  public var body: String
  public var pinned: Bool
  public var tags: [String]
  /// Identity for deduplication, fixed at creation. See `Note.hash`.
  public var contentHash: String
  public var source: String

  public init(
    id: Int64? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    title: String = "",
    body: String = "",
    pinned: Bool = false,
    tags: [String] = [],
    contentHash: String? = nil,
    source: String = "rant"
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.title = title
    self.body = body
    self.pinned = pinned
    self.tags = Note.normaliseTags(tags)
    self.contentHash =
      contentHash ?? Note.hash(title: title, body: body, createdAt: createdAt, source: source)
    self.source = source
  }

  /// Lower-cased and deduplicated, order preserved. Tags are a filing system, and
  /// `Ideas` and `ideas` filing separately is a bug the user has to notice.
  public static func normaliseTags(_ tags: [String]) -> [String] {
    var seen: Set<String> = []
    var kept: [String] = []
    for tag in tags {
      let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Commas are the column separator, so a tag cannot contain one.
        .replacingOccurrences(of: ",", with: " ")
        .trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      kept.append(trimmed)
    }
    return kept
  }

  /// Identity, not a checksum.
  ///
  /// The hash covers the note *as created* — title, first body, second-resolution
  /// timestamp, source — and is never recomputed afterwards. Appending to a note must
  /// not change what the note is, or every voice-append would look like a new note to
  /// an import and the unique index would start rejecting real edits. Re-importing the
  /// same export stays a no-op, which is the job this column exists to do.
  public static func hash(title: String, body: String, createdAt: Date, source: String) -> String {
    let normalised = (title + "\n" + body)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .lowercased()
    let seconds = Int(createdAt.timeIntervalSince1970.rounded())
    let digest = SHA256.hash(data: Data("\(source)|\(seconds)|\(normalised)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// The note as a Markdown file, front matter included, ready to write to disk or
  /// paste into another app. Exporting is not a feature bolted on at the end: a note
  /// you cannot get out is a note you do not own.
  public var markdown: String {
    var lines = ["---"]
    lines.append("title: \(title)")
    lines.append("created: \(createdAt.formatted(.iso8601))")
    lines.append("updated: \(updatedAt.formatted(.iso8601))")
    if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
    if pinned { lines.append("pinned: true") }
    lines.append("---")
    lines.append("")
    if !title.isEmpty {
      lines.append("# \(title)")
      lines.append("")
    }
    lines.append(body)
    return lines.joined(separator: "\n")
  }
}

public struct NoteSearchResult: Equatable, Sendable {
  public var note: Note
  public var snippet: String
}

/// The scratchpad: somewhere to put a thought without choosing an app first.
///
/// Notes live in the same SQLite file as everything else, indexed by the same FTS5
/// machinery as dictation history, so search behaves identically and there is one file
/// to back up, export or delete. The store is deliberately small: create, append,
/// search, pin, tag, export. Anything more is a note-taking app, and Rant is not one.
public struct NoteStore: Sendable {
  private let database: Database
  private let log = RantLog("Notes")

  public init(database: Database) {
    self.database = database
  }

  private static let columns =
    "id, created_at, updated_at, title, body, pinned, tags, content_hash, source"

  private func decode(_ row: Row) -> Note {
    Note(
      id: Int64(row.int(0)),
      createdAt: row.date(1),
      updatedAt: row.date(2),
      title: row.string(3),
      body: row.string(4),
      pinned: row.bool(5),
      tags: Self.decodeTags(row.stringOrNil(6)),
      contentHash: row.string(7),
      source: row.string(8))
  }

  static func decodeTags(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    return Note.normaliseTags(raw.split(separator: ",").map(String.init))
  }

  static func encodeTags(_ tags: [String]) -> String {
    Note.normaliseTags(tags).joined(separator: ",")
  }

  // MARK: - Writing

  /// Creates a note, or returns the one that is already there.
  ///
  /// The existence check comes before the insert rather than leaning on
  /// `INSERT OR IGNORE` alone, so the caller gets the stored row — with its id — in
  /// both cases and cannot tell the difference. Importing the same set of notes twice
  /// leaves one copy of each.
  @discardableResult
  public func create(
    title: String = "",
    body: String,
    tags: [String] = [],
    pinned: Bool = false,
    at date: Date = Date(),
    source: String = "rant"
  ) throws -> Note {
    let note = Note(
      createdAt: date, title: title, body: body, pinned: pinned, tags: tags, source: source)
    return try save(note)
  }

  @discardableResult
  public func save(_ note: Note) throws -> Note {
    try database.transaction {
      if let existing = try database.query(
        "SELECT \(Self.columns) FROM notes WHERE content_hash = ? LIMIT 1",
        [.text(note.contentHash)], decode
      ).first {
        return existing
      }
      try database.run(
        """
        INSERT OR IGNORE INTO notes
          (created_at, updated_at, title, body, pinned, tags, content_hash, source)
        VALUES (?,?,?,?,?,?,?,?)
        """,
        [
          SQLValue(note.createdAt), SQLValue(note.updatedAt), .text(note.title),
          .text(note.body), SQLValue(note.pinned), .text(Self.encodeTags(note.tags)),
          .text(note.contentHash), .text(note.source),
        ])
      log.shape("note created", of: note.body)
      return try database.query(
        "SELECT \(Self.columns) FROM notes WHERE content_hash = ? LIMIT 1",
        [.text(note.contentHash)], decode
      ).first ?? note
    }
  }

  /// Adds dictated text to the end of a note.
  ///
  /// A blank line between the old body and the new text, because appends are separate
  /// thoughts spoken minutes apart, and running them together produces a paragraph
  /// nobody wrote. The content hash is left alone on purpose — see `Note.hash`.
  @discardableResult
  public func append(to id: Int64, text: String, at date: Date = Date()) throws -> Note {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      guard let note = try note(id: id) else { throw NoteError.notFound(id) }
      return note
    }
    return try database.transaction {
      guard
        let existing = try database.query(
          "SELECT \(Self.columns) FROM notes WHERE id = ?", [.int(Int(id))], decode
        ).first
      else { throw NoteError.notFound(id) }

      let body =
        existing.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? trimmed : existing.body + "\n\n" + trimmed
      try database.run(
        "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?",
        [.text(body), SQLValue(date), .int(Int(id))])
      var updated = existing
      updated.body = body
      updated.updatedAt = date
      return updated
    }
  }

  /// Appends to today's scratchpad, creating it on the first thought of the day.
  ///
  /// One note per day rather than one per utterance: a scratchpad you have to name
  /// before you can use it is not a scratchpad, and a hundred one-line notes is not a
  /// day's thinking.
  @discardableResult
  public func appendToScratchpad(_ text: String, at date: Date = Date()) throws -> Note {
    let title = Self.scratchpadTitle(for: date)
    if let existing = try notes(titled: title).first, let id = existing.id {
      return try append(to: id, text: text, at: date)
    }
    return try create(title: title, body: text, tags: ["scratchpad"], at: date)
  }

  static func scratchpadTitle(for date: Date) -> String {
    "Scratchpad \(dayFormatter.string(from: date))"
  }

  static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  public func setPinned(id: Int64, _ value: Bool) throws {
    try database.run(
      "UPDATE notes SET pinned = ? WHERE id = ?", [SQLValue(value), .int(Int(id))])
  }

  public func setTags(id: Int64, _ tags: [String]) throws {
    try database.run(
      "UPDATE notes SET tags = ? WHERE id = ?", [.text(Self.encodeTags(tags)), .int(Int(id))])
  }

  @discardableResult
  public func addTag(id: Int64, _ tag: String) throws -> [String] {
    guard let note = try note(id: id) else { throw NoteError.notFound(id) }
    let tags = Note.normaliseTags(note.tags + [tag])
    try setTags(id: id, tags)
    return tags
  }

  public func update(id: Int64, title: String? = nil, body: String? = nil, at date: Date = Date())
    throws
  {
    guard let note = try note(id: id) else { throw NoteError.notFound(id) }
    try database.run(
      "UPDATE notes SET title = ?, body = ?, updated_at = ? WHERE id = ?",
      [.text(title ?? note.title), .text(body ?? note.body), SQLValue(date), .int(Int(id))])
  }

  public func delete(id: Int64) throws {
    try database.run("DELETE FROM notes WHERE id = ?", [.int(Int(id))])
  }

  public func deleteAll() throws {
    try database.execute("DELETE FROM notes;")
  }

  // MARK: - Reading

  public func note(id: Int64) throws -> Note? {
    try database.query(
      "SELECT \(Self.columns) FROM notes WHERE id = ?", [.int(Int(id))], decode
    ).first
  }

  /// Pinned notes first, then most recently touched. Pinning that does not float the
  /// note to the top is only a label.
  public func recent(limit: Int = 50, offset: Int = 0) throws -> [Note] {
    try database.query(
      """
      SELECT \(Self.columns) FROM notes
      ORDER BY pinned DESC, updated_at DESC LIMIT ? OFFSET ?
      """,
      [.int(limit), .int(offset)], decode)
  }

  public func notes(titled title: String) throws -> [Note] {
    try database.query(
      "SELECT \(Self.columns) FROM notes WHERE title = ? ORDER BY created_at DESC",
      [.text(title)], decode)
  }

  /// Notes carrying a tag. The comparison pads both sides with commas so `ideas` does
  /// not match `bad-ideas`.
  public func notes(tagged tag: String) throws -> [Note] {
    let needle = Note.normaliseTags([tag]).first ?? ""
    guard !needle.isEmpty else { return [] }
    return try database.query(
      """
      SELECT \(Self.columns) FROM notes
      WHERE ',' || COALESCE(tags,'') || ',' LIKE '%,' || ? || ',%'
      ORDER BY pinned DESC, updated_at DESC
      """,
      [.text(needle)], decode)
  }

  public func count() throws -> Int {
    try database.query("SELECT COUNT(*) FROM notes") { $0.int(0) }.first ?? 0
  }

  /// Full-text search over title and body, through the same FTS5 table the schema
  /// already maintains with triggers.
  ///
  /// The query is rewritten into quoted prefix terms rather than passed through, for
  /// the same reason history search does it: an apostrophe or a stray quote must
  /// produce results, not an FTS syntax error thrown at someone who was typing.
  public func search(_ query: String, limit: Int = 50) throws -> [NoteSearchResult] {
    let expression = Self.ftsQuery(query)
    guard !expression.isEmpty else { return [] }
    return try database.query(
      """
      SELECT \(Self.columns.split(separator: ",").map { "n.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")),
             snippet(notes_fts, 1, '⟦', '⟧', '…', 12)
      FROM notes_fts
      JOIN notes n ON n.id = notes_fts.rowid
      WHERE notes_fts MATCH ?
      ORDER BY rank
      LIMIT ?
      """,
      [.text(expression), .int(limit)]
    ) { row in
      NoteSearchResult(note: decode(row), snippet: row.string(9))
    }
  }

  static func ftsQuery(_ raw: String) -> String {
    raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { "\"\($0)\"*" }
      .joined(separator: " AND ")
  }

  // MARK: - Export

  /// Every note as one Markdown document, newest first, separated by a rule. The point
  /// is that the export is readable on its own — not a format that needs Rant to open
  /// it again.
  public func exportMarkdown(limit: Int = 10_000) throws -> String {
    try recent(limit: limit).map(\.markdown).joined(separator: "\n\n---\n\n")
  }

  public func exportMarkdown(id: Int64) throws -> String {
    guard let note = try note(id: id) else { throw NoteError.notFound(id) }
    return note.markdown
  }
}

public enum NoteError: Error, Equatable, LocalizedError {
  case notFound(Int64)

  public var errorDescription: String? {
    switch self {
    case .notFound: "That note is no longer there."
    }
  }
}
