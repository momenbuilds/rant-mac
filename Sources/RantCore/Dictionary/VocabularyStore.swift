import Foundation

/// One personal dictionary entry.
public struct DictionaryEntry: Equatable, Sendable, Identifiable, Codable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// Replace the spoken form with the written form after transcription.
    case replacement
    /// Bias the recogniser toward this spelling, without rewriting anything.
    case boost

    public var displayName: String {
      switch self {
      case .replacement: "Replacement"
      case .boost: "Key term"
      }
    }
  }

  public var id: Int64?
  /// What you say.
  public var spoken: String
  /// What Rant writes. For a `.boost` this is the same as `spoken`.
  public var written: String
  public var kind: Kind
  public var category: String?
  public var enabled: Bool
  public var favourite: Bool
  public var caseSensitive: Bool
  public var createdAt: Date
  public var useCount: Int
  public var source: String

  public init(
    id: Int64? = nil,
    spoken: String,
    written: String? = nil,
    kind: Kind = .replacement,
    category: String? = nil,
    enabled: Bool = true,
    favourite: Bool = false,
    caseSensitive: Bool = false,
    createdAt: Date = Date(),
    useCount: Int = 0,
    source: String = "rant"
  ) {
    self.id = id
    self.spoken = spoken
    self.written = written ?? spoken
    self.kind = kind
    self.category = category
    self.enabled = enabled
    self.favourite = favourite
    self.caseSensitive = caseSensitive
    self.createdAt = createdAt
    self.useCount = useCount
    self.source = source
  }
}

/// A phrase you say that expands into something longer.
public struct Snippet: Equatable, Sendable, Identifiable, Codable {
  public var id: Int64?
  public var trigger: String
  public var expansion: String
  public var folder: String?
  public var enabled: Bool
  public var createdAt: Date
  public var useCount: Int
  public var source: String

  public init(
    id: Int64? = nil,
    trigger: String,
    expansion: String,
    folder: String? = nil,
    enabled: Bool = true,
    createdAt: Date = Date(),
    useCount: Int = 0,
    source: String = "rant"
  ) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
    self.folder = folder
    self.enabled = enabled
    self.createdAt = createdAt
    self.useCount = useCount
    self.source = source
  }
}

public enum VocabularyError: Error, Equatable, LocalizedError {
  case duplicateSpokenForm(String)
  case duplicateTrigger(String)
  case emptyField(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateSpokenForm(let spoken):
      "You already have an entry for “\(spoken)”."
    case .duplicateTrigger(let trigger):
      "A snippet is already triggered by “\(trigger)”."
    case .emptyField(let field):
      "\(field) cannot be empty."
    }
  }
}

/// The user's dictionary and snippets.
///
/// Both live in SQLite alongside everything else, and both import and export as plain
/// JSON — because a personal dictionary you cannot take with you is a personal
/// dictionary you have rented.
public struct VocabularyStore: Sendable {
  private let database: Database

  public init(database: Database) { self.database = database }

  // MARK: - Dictionary

  @discardableResult
  public func add(_ entry: DictionaryEntry) throws -> DictionaryEntry {
    let spoken = entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { throw VocabularyError.emptyField("Spoken form") }
    guard !written.isEmpty else { throw VocabularyError.emptyField("Written form") }

    if try existingEntry(spoken: spoken, kind: entry.kind) != nil {
      throw VocabularyError.duplicateSpokenForm(spoken)
    }
    let id = try database.run(
      """
      INSERT INTO dictionary_entries
        (spoken, written, kind, category, enabled, favourite, case_sensitive, created_at,
         use_count, source)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      """,
      [
        .text(spoken), .text(written), .text(entry.kind.rawValue), SQLValue(entry.category),
        SQLValue(entry.enabled), SQLValue(entry.favourite), SQLValue(entry.caseSensitive),
        SQLValue(entry.createdAt), .int(entry.useCount), .text(entry.source),
      ])
    var stored = entry
    stored.id = id
    stored.spoken = spoken
    stored.written = written
    return stored
  }

  /// Insert, or leave an existing entry alone. What an import uses, so re-running one
  /// never fails and never duplicates.
  @discardableResult
  public func addOrIgnore(_ entry: DictionaryEntry) throws -> Bool {
    do {
      _ = try add(entry)
      return true
    } catch VocabularyError.duplicateSpokenForm {
      return false
    }
  }

  func existingEntry(spoken: String, kind: DictionaryEntry.Kind) throws -> DictionaryEntry? {
    try database.query(
      "SELECT \(Self.entryColumns) FROM dictionary_entries WHERE spoken = ? AND kind = ?",
      [.text(spoken), .text(kind.rawValue)], Self.decodeEntry(_:)
    ).first
  }

  private static let entryColumns =
    "id, spoken, written, kind, category, enabled, favourite, case_sensitive, created_at, use_count, source"

  private static func decodeEntry(_ row: Row) -> DictionaryEntry {
    DictionaryEntry(
      id: Int64(row.int(0)), spoken: row.string(1), written: row.string(2),
      kind: DictionaryEntry.Kind(rawValue: row.string(3)) ?? .replacement,
      category: row.stringOrNil(4), enabled: row.bool(5), favourite: row.bool(6),
      caseSensitive: row.bool(7), createdAt: row.date(8), useCount: row.int(9),
      source: row.string(10))
  }

  public func entries(includeDisabled: Bool = true) throws -> [DictionaryEntry] {
    let filter = includeDisabled ? "" : "WHERE enabled = 1"
    return try database.query(
      "SELECT \(Self.entryColumns) FROM dictionary_entries \(filter) ORDER BY spoken COLLATE NOCASE",
      [], Self.decodeEntry(_:))
  }

  public func searchEntries(_ query: String) throws -> [DictionaryEntry] {
    let term = "%\(query)%"
    return try database.query(
      """
      SELECT \(Self.entryColumns) FROM dictionary_entries
      WHERE spoken LIKE ? OR written LIKE ? ORDER BY spoken COLLATE NOCASE
      """,
      [.text(term), .text(term)], Self.decodeEntry(_:))
  }

  public func update(_ entry: DictionaryEntry) throws {
    guard let id = entry.id else { return }
    try database.run(
      """
      UPDATE dictionary_entries
      SET spoken = ?, written = ?, kind = ?, category = ?, enabled = ?, favourite = ?,
          case_sensitive = ?
      WHERE id = ?
      """,
      [
        .text(entry.spoken), .text(entry.written), .text(entry.kind.rawValue),
        SQLValue(entry.category), SQLValue(entry.enabled), SQLValue(entry.favourite),
        SQLValue(entry.caseSensitive), .int(Int(id)),
      ])
  }

  public func deleteEntry(id: Int64) throws {
    try database.run("DELETE FROM dictionary_entries WHERE id = ?", [.int(Int(id))])
  }

  // MARK: - Snippets

  @discardableResult
  public func add(_ snippet: Snippet) throws -> Snippet {
    let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trigger.isEmpty else { throw VocabularyError.emptyField("Trigger phrase") }
    guard !snippet.expansion.isEmpty else { throw VocabularyError.emptyField("Expansion") }
    if try existingSnippet(trigger: trigger) != nil {
      throw VocabularyError.duplicateTrigger(trigger)
    }
    let id = try database.run(
      """
      INSERT INTO snippets (trigger, expansion, folder, enabled, created_at, use_count, source)
      VALUES (?,?,?,?,?,?,?)
      """,
      [
        .text(trigger), .text(snippet.expansion), SQLValue(snippet.folder),
        SQLValue(snippet.enabled), SQLValue(snippet.createdAt), .int(snippet.useCount),
        .text(snippet.source),
      ])
    var stored = snippet
    stored.id = id
    stored.trigger = trigger
    return stored
  }

  @discardableResult
  public func addOrIgnore(_ snippet: Snippet) throws -> Bool {
    do {
      _ = try add(snippet)
      return true
    } catch VocabularyError.duplicateTrigger {
      return false
    }
  }

  private static let snippetColumns =
    "id, trigger, expansion, folder, enabled, created_at, use_count, source"

  private static func decodeSnippet(_ row: Row) -> Snippet {
    Snippet(
      id: Int64(row.int(0)), trigger: row.string(1), expansion: row.string(2),
      folder: row.stringOrNil(3), enabled: row.bool(4), createdAt: row.date(5),
      useCount: row.int(6), source: row.string(7))
  }

  func existingSnippet(trigger: String) throws -> Snippet? {
    try database.query(
      "SELECT \(Self.snippetColumns) FROM snippets WHERE trigger = ?", [.text(trigger)],
      Self.decodeSnippet(_:)
    ).first
  }

  public func snippets(includeDisabled: Bool = true) throws -> [Snippet] {
    let filter = includeDisabled ? "" : "WHERE enabled = 1"
    return try database.query(
      "SELECT \(Self.snippetColumns) FROM snippets \(filter) ORDER BY trigger COLLATE NOCASE",
      [], Self.decodeSnippet(_:))
  }

  public func update(_ snippet: Snippet) throws {
    guard let id = snippet.id else { return }
    try database.run(
      "UPDATE snippets SET trigger = ?, expansion = ?, folder = ?, enabled = ? WHERE id = ?",
      [
        .text(snippet.trigger), .text(snippet.expansion), SQLValue(snippet.folder),
        SQLValue(snippet.enabled), .int(Int(id)),
      ])
  }

  public func deleteSnippet(id: Int64) throws {
    try database.run("DELETE FROM snippets WHERE id = ?", [.int(Int(id))])
  }

  // MARK: - Feeding the pipeline

  /// The applier the dictation pipeline uses. Only enabled entries, and `.boost`
  /// entries are excluded because they steer recognition rather than rewrite text.
  public func makeApplier() throws -> VocabularyApplier {
    let entries = try entries(includeDisabled: false).filter { $0.kind == .replacement }
    let snippets = try snippets(includeDisabled: false)
    return VocabularyApplier(
      replacements: entries.map { ($0.spoken, $0.written, $0.caseSensitive) },
      snippets: snippets.map { ($0.trigger, $0.expansion) })
  }

  /// Terms sent to the provider as recognition hints. Both kinds contribute: a
  /// replacement's *written* form is what we want the recogniser to produce.
  public func keyTerms() throws -> [String] {
    try entries(includeDisabled: false).map(\.written)
  }
}
