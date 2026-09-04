import Foundation

#if canImport(NaturalLanguage)
  import NaturalLanguage
#endif

/// Which of the user's own records a vector belongs to. The row identifier is the
/// primary key of the corresponding table, so a deleted record simply stops being
/// joinable and its vector becomes dead weight rather than a dangling result.
public enum SemanticSourceKind: String, Sendable, Codable, CaseIterable {
  case transcript, meeting, note
}

/// One recalled record.
public struct SemanticMatch: Equatable, Sendable, Identifiable {
  public var kind: SemanticSourceKind
  public var rowID: Int64
  public var date: Date
  public var text: String
  /// Cosine similarity, or zero for a keyword fallback result — which is honest
  /// rather than a fabricated score, and lets the UI avoid showing a percentage it
  /// did not measure.
  public var similarity: Double

  public var id: String { "\(kind.rawValue)-\(rowID)" }

  public init(
    kind: SemanticSourceKind, rowID: Int64, date: Date, text: String, similarity: Double
  ) {
    self.kind = kind
    self.rowID = rowID
    self.date = date
    self.text = text
    self.similarity = similarity
  }
}

/// What came back, and how it was found.
///
/// The strategy is part of the result rather than an internal detail because the two
/// searches answer different questions, and a user who typed a vague phrase deserves
/// to know they got keyword matches instead of meaning-based ones.
public struct SemanticSearchResults: Equatable, Sendable {
  public enum Strategy: String, Sendable {
    case semantic, keyword
  }

  public var matches: [SemanticMatch]
  public var strategy: Strategy

  public init(matches: [SemanticMatch], strategy: Strategy) {
    self.matches = matches
    self.strategy = strategy
  }
}

/// Turns text into a vector. Injectable so the tests can be deterministic.
///
/// The protocol exists mainly so nothing in the search path can quietly acquire a
/// network dependency: an embedder is a pure function from a string to numbers, and
/// the only implementation shipped is Apple's on-device one.
public protocol TextEmbedder: Sendable {
  /// Identifies the model. Vectors are stored against it, so swapping models
  /// invalidates the old vectors instead of silently comparing incompatible ones.
  var identifier: String { get }
  /// Nil when the text carries nothing to embed — empty, or all punctuation.
  func vector(for text: String) -> [Double]?
}

#if canImport(NaturalLanguage)
  /// Apple's on-device sentence embedding.
  ///
  /// The whole feature rests on this being local: semantic search over a dictation
  /// history is exactly the sort of thing that would otherwise mean uploading
  /// everything the user has ever said. `NLEmbedding` is not available for every
  /// language, and the initialiser fails rather than pretending — `SemanticIndex`
  /// then falls back to keyword search.
  public final class NaturalLanguageEmbedder: TextEmbedder, @unchecked Sendable {
    private let embedding: NLEmbedding
    public let identifier: String

    public init?(language: NLLanguage = .english) {
      guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
      self.embedding = embedding
      self.identifier = "nl-sentence-\(language.rawValue)-\(embedding.dimension)"
    }

    public func vector(for text: String) -> [Double]? {
      let normalised = SemanticIndex.normalise(text)
      guard !normalised.isEmpty else { return nil }
      return embedding.vector(for: normalised)
    }
  }
#endif

/// Optional, local, meaning-based recall over transcripts, meetings and notes — the
/// search that answers "what did I say about Candle last week?" when the user cannot
/// remember which words they used.
///
/// Three constraints shape it:
///
/// - **Local.** Embeddings come from `NLEmbedding` on the user's machine. There is no
///   network path in this file and no provider to configure.
/// - **Optional, and never worse than what it replaces.** When the feature is off, or
///   the platform has no embedding for the user's language, `search` returns the
///   existing FTS5 results and says so, rather than failing or returning nothing.
/// - **Never blocking.** `indexNextBatch` does a bounded amount of work and records
///   how far it reached, so indexing an existing history is resumable across launches
///   and can be driven from wherever the app has spare time.
///
/// ### Why the table is created here rather than in `Migrations`
///
/// The vectors are derived data: rebuildable from the transcripts, meetings and notes
/// that are already stored, and meaningless without the model that produced them. The
/// feature is also opt-in, and a user who never turns it on should not be carrying its
/// table, its indexes or its rows — a schema migration would create them on every
/// machine on first launch. Creating the table lazily on first use keeps the migration
/// list to things that are part of the user's data rather than a cache of it, and it
/// keeps the recovery story simple: delete the table and the next indexing pass
/// rebuilds it. `Migrations` stays the description of what Rant *knows*; this is a
/// description of what Rant has *precomputed*.
public actor SemanticIndex {

  /// Settings, all defaulting to the conservative choice.
  public struct Settings: Equatable, Sendable, Codable {
    /// Opt-in. While false, nothing is indexed and search falls back to keywords.
    public var enabled: Bool
    /// Cosine similarity below which a result is not a result. Without a floor the
    /// nearest vector always wins, so a query about something the user never
    /// mentioned would return whatever they talked about most — a confidently wrong
    /// answer, which is worse than an empty one.
    public var minimumSimilarity: Double
    /// Records embedded per `indexNextBatch` call.
    public var batchSize: Int
    /// How much of a record is embedded. A sentence embedding of an hour-long meeting
    /// is a blur; the opening of a record is what identifies it, and truncating also
    /// bounds the work per row.
    public var maximumCharacters: Int

    public init(
      enabled: Bool = false,
      minimumSimilarity: Double = 0.35,
      batchSize: Int = 32,
      maximumCharacters: Int = 1_000
    ) {
      self.enabled = enabled
      self.minimumSimilarity = minimumSimilarity
      self.batchSize = batchSize
      self.maximumCharacters = maximumCharacters
    }

    public static let `default` = Settings()
  }

  /// How much is done and how much is left, so the UI can show progress rather than a
  /// spinner of unknown duration.
  public struct IndexingProgress: Equatable, Sendable {
    public var indexed: Int
    public var remaining: Int

    public init(indexed: Int, remaining: Int) {
      self.indexed = indexed
      self.remaining = remaining
    }

    public var isComplete: Bool { remaining == 0 }
  }

  private let database: Database
  private let embedder: TextEmbedder?
  private let log = RantLog("Semantic")
  public private(set) var settings: Settings
  private var schemaReady = false

  public init(database: Database, embedder: TextEmbedder?, settings: Settings = .default) {
    self.database = database
    self.embedder = embedder
    self.settings = settings
  }

  public func update(settings: Settings) {
    self.settings = settings
  }

  /// True when meaning-based search is actually available. The UI should ask rather
  /// than assume, because the answer depends on the platform's language support as
  /// well as on the user's setting.
  public var isAvailable: Bool { settings.enabled && embedder != nil }

  // MARK: - Schema

  /// Created on first use. See the type's documentation for why this is not a
  /// migration.
  private func ensureSchema() throws {
    guard !schemaReady else { return }
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS semantic_vectors (
        kind        TEXT NOT NULL,
        row_id      INTEGER NOT NULL,
        model       TEXT NOT NULL,
        dimensions  INTEGER NOT NULL,
        vector      BLOB NOT NULL,
        updated_at  REAL NOT NULL,
        PRIMARY KEY (kind, row_id, model)
      );
      -- How far each kind has been indexed, per model, so an interrupted pass resumes
      -- where it stopped instead of starting again.
      CREATE TABLE IF NOT EXISTS semantic_index_state (
        model       TEXT NOT NULL,
        kind        TEXT NOT NULL,
        last_row_id INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (model, kind)
      );
      """)
    schemaReady = true
  }

  /// Throws away every vector and every cursor. The escape hatch for a changed model
  /// or a suspect index — and cheap to offer, because none of this is original data.
  public func rebuild() throws {
    try ensureSchema()
    try database.transaction {
      try database.execute("DELETE FROM semantic_vectors;")
      try database.execute("DELETE FROM semantic_index_state;")
    }
  }

  // MARK: - Indexing

  private struct PendingRow {
    var id: Int64
    var text: String
    var date: Date
  }

  /// Embeds up to `limit` records and returns what is left to do.
  ///
  /// Rows that produce no vector still advance the cursor. Leaving them behind would
  /// stall the queue on the first empty note forever, and re-reading them on every
  /// pass would make "remaining" a number that never falls.
  @discardableResult
  public func indexNextBatch(limit: Int? = nil) throws -> IndexingProgress {
    guard settings.enabled, let embedder else { return IndexingProgress(indexed: 0, remaining: 0) }
    try ensureSchema()

    var budget = max(0, limit ?? settings.batchSize)
    var indexed = 0
    for kind in SemanticSourceKind.allCases {
      guard budget > 0 else { break }
      let rows = try pendingRows(kind: kind, after: cursor(for: kind, model: embedder.identifier), limit: budget)
      guard !rows.isEmpty else { continue }
      try database.transaction {
        for row in rows {
          if let vector = embedder.vector(for: row.text) {
            try store(vector, kind: kind, rowID: row.id, model: embedder.identifier, at: row.date)
          }
          try setCursor(row.id, for: kind, model: embedder.identifier)
          indexed += 1
        }
      }
      budget -= rows.count
    }

    let remaining = try pendingCount()
    if indexed > 0 { log.info("embedded \(indexed) records, \(remaining) remaining") }
    return IndexingProgress(indexed: indexed, remaining: remaining)
  }

  /// How many records have not been embedded yet.
  public func pendingCount() throws -> Int {
    guard settings.enabled, let embedder else { return 0 }
    try ensureSchema()
    var total = 0
    for kind in SemanticSourceKind.allCases {
      let last = try cursor(for: kind, model: embedder.identifier)
      total += try database.query(
        "SELECT COUNT(*) FROM \(Self.sourceTable(kind)) WHERE id > ?", [.int(Int(last))]
      ) { $0.int(0) }.first ?? 0
    }
    return total
  }

  public func vectorCount() throws -> Int {
    try ensureSchema()
    return try database.query("SELECT COUNT(*) FROM semantic_vectors") { $0.int(0) }.first ?? 0
  }

  private static func sourceTable(_ kind: SemanticSourceKind) -> String {
    switch kind {
    case .transcript: "transcripts"
    case .meeting: "meeting_segments"
    case .note: "notes"
    }
  }

  private func pendingRows(
    kind: SemanticSourceKind, after last: Int64, limit: Int
  ) throws -> [PendingRow] {
    let sql: String
    switch kind {
    case .transcript:
      sql = """
        SELECT id, final_text, created_at FROM transcripts
        WHERE id > ? ORDER BY id LIMIT ?
        """
    case .meeting:
      sql = """
        SELECT s.id, s.text, m.started_at FROM meeting_segments s
        JOIN meetings m ON m.id = s.meeting_id
        WHERE s.id > ? ORDER BY s.id LIMIT ?
        """
    case .note:
      sql = """
        SELECT id, title || ' ' || body, updated_at FROM notes
        WHERE id > ? ORDER BY id LIMIT ?
        """
    }
    return try database.query(sql, [.int(Int(last)), .int(limit)]) { row in
      PendingRow(id: Int64(row.int(0)), text: row.string(1), date: row.date(2))
    }
  }

  private func cursor(for kind: SemanticSourceKind, model: String) throws -> Int64 {
    let value = try database.query(
      "SELECT last_row_id FROM semantic_index_state WHERE model = ? AND kind = ?",
      [.text(model), .text(kind.rawValue)]
    ) { $0.int(0) }.first
    return Int64(value ?? 0)
  }

  private func setCursor(_ rowID: Int64, for kind: SemanticSourceKind, model: String) throws {
    try database.run(
      """
      INSERT INTO semantic_index_state (model, kind, last_row_id) VALUES (?,?,?)
      ON CONFLICT(model, kind) DO UPDATE SET last_row_id = MAX(last_row_id, excluded.last_row_id)
      """,
      [.text(model), .text(kind.rawValue), .int(Int(rowID))])
  }

  private func store(
    _ vector: [Double], kind: SemanticSourceKind, rowID: Int64, model: String, at date: Date
  ) throws {
    try database.run(
      """
      INSERT OR REPLACE INTO semantic_vectors
        (kind, row_id, model, dimensions, vector, updated_at)
      VALUES (?,?,?,?,?,?)
      """,
      [
        .text(kind.rawValue), .int(Int(rowID)), .text(model), .int(vector.count),
        .blob(Self.encode(vector)), SQLValue(date),
      ])
  }

  // MARK: - Searching

  /// Meaning-based recall, degrading to the full-text search when it cannot be done.
  ///
  /// An empty semantic result is *not* a reason to fall back. If the user has never
  /// mentioned the thing they asked about, the honest answer is nothing at all —
  /// running a keyword search to fill the space would produce matches on the
  /// stop-words in the question.
  public func search(
    _ query: String,
    limit: Int = 10,
    since: Date? = nil,
    kinds: Set<SemanticSourceKind> = Set(SemanticSourceKind.allCases)
  ) throws -> SemanticSearchResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return SemanticSearchResults(matches: [], strategy: .keyword) }

    guard settings.enabled, let embedder, let target = embedder.vector(for: trimmed) else {
      return SemanticSearchResults(
        matches: try keywordSearch(trimmed, limit: limit, since: since, kinds: kinds),
        strategy: .keyword)
    }
    try ensureSchema()

    var scored: [SemanticMatch] = []
    var examined = 0
    let floor = since ?? Date.distantPast
    for kind in SemanticSourceKind.allCases where kinds.contains(kind) {
      for candidate in try storedVectors(kind: kind, model: embedder.identifier, since: floor) {
        examined += 1
        let score = Self.cosineSimilarity(target, candidate.vector)
        guard score >= settings.minimumSimilarity else { continue }
        scored.append(
          SemanticMatch(
            kind: kind, rowID: candidate.rowID, date: candidate.date, text: candidate.text,
            similarity: score))
      }
    }

    // Nothing embedded yet is a different situation from nothing relevant: the user
    // would get an empty page for a term that is plainly in their history, so the
    // keyword search answers instead until indexing catches up.
    guard examined > 0 else {
      return SemanticSearchResults(
        matches: try keywordSearch(trimmed, limit: limit, since: since, kinds: kinds),
        strategy: .keyword)
    }

    scored.sort { $0.similarity == $1.similarity ? $0.date > $1.date : $0.similarity > $1.similarity }
    return SemanticSearchResults(matches: Array(scored.prefix(limit)), strategy: .semantic)
  }

  private struct StoredVector {
    var rowID: Int64
    var vector: [Double]
    var text: String
    var date: Date
  }

  private func storedVectors(
    kind: SemanticSourceKind, model: String, since: Date
  ) throws -> [StoredVector] {
    let sql: String
    switch kind {
    case .transcript:
      sql = """
        SELECT v.row_id, v.vector, t.final_text, t.created_at
        FROM semantic_vectors v JOIN transcripts t ON t.id = v.row_id
        WHERE v.kind = 'transcript' AND v.model = ? AND t.created_at >= ?
        """
    case .meeting:
      sql = """
        SELECT v.row_id, v.vector, s.text, m.started_at
        FROM semantic_vectors v
        JOIN meeting_segments s ON s.id = v.row_id
        JOIN meetings m ON m.id = s.meeting_id
        WHERE v.kind = 'meeting' AND v.model = ? AND m.started_at >= ?
        """
    case .note:
      sql = """
        SELECT v.row_id, v.vector, n.title || ' ' || n.body, n.updated_at
        FROM semantic_vectors v JOIN notes n ON n.id = v.row_id
        WHERE v.kind = 'note' AND v.model = ? AND n.updated_at >= ?
        """
    }
    return try database.query(sql, [.text(model), SQLValue(since)]) { row in
      StoredVector(
        rowID: Int64(row.int(0)), vector: Self.decode(row.data(1)), text: row.string(2),
        date: row.date(3))
    }
  }

  /// The existing FTS5 search, over the same three sources. Escaping goes through
  /// `SQLiteTranscriptStore.ftsQuery` so a stray apostrophe in a spoken question
  /// cannot become an FTS syntax error here either.
  private func keywordSearch(
    _ query: String, limit: Int, since: Date?, kinds: Set<SemanticSourceKind>
  ) throws -> [SemanticMatch] {
    let expression = SQLiteTranscriptStore.ftsQuery(query)
    guard !expression.isEmpty else { return [] }
    let floor = since ?? Date.distantPast

    var matches: [SemanticMatch] = []
    for kind in SemanticSourceKind.allCases where kinds.contains(kind) {
      let sql: String
      switch kind {
      case .transcript:
        sql = """
          SELECT t.id, t.final_text, t.created_at
          FROM transcripts_fts JOIN transcripts t ON t.id = transcripts_fts.rowid
          WHERE transcripts_fts MATCH ? AND t.created_at >= ?
          ORDER BY rank LIMIT ?
          """
      case .meeting:
        sql = """
          SELECT s.id, s.text, m.started_at
          FROM meetings_fts
          JOIN meeting_segments s ON s.id = meetings_fts.rowid
          JOIN meetings m ON m.id = s.meeting_id
          WHERE meetings_fts MATCH ? AND m.started_at >= ?
          ORDER BY rank LIMIT ?
          """
      case .note:
        sql = """
          SELECT n.id, n.title || ' ' || n.body, n.updated_at
          FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
          WHERE notes_fts MATCH ? AND n.updated_at >= ?
          ORDER BY rank LIMIT ?
          """
      }
      let found = try database.query(
        sql, [.text(expression), SQLValue(floor), .int(limit)]
      ) { row in
        SemanticMatch(
          kind: kind, rowID: Int64(row.int(0)), date: row.date(2), text: row.string(1),
          similarity: 0)
      }
      matches.append(contentsOf: found)
    }
    matches.sort { $0.date > $1.date }
    return Array(matches.prefix(limit))
  }

  // MARK: - Vector arithmetic

  public static func cosineSimilarity(_ first: [Double], _ second: [Double]) -> Double {
    guard first.count == second.count, !first.isEmpty else { return 0 }
    var dot = 0.0
    var firstMagnitude = 0.0
    var secondMagnitude = 0.0
    for index in first.indices {
      dot += first[index] * second[index]
      firstMagnitude += first[index] * first[index]
      secondMagnitude += second[index] * second[index]
    }
    guard firstMagnitude > 0, secondMagnitude > 0 else { return 0 }
    return dot / (firstMagnitude.squareRoot() * secondMagnitude.squareRoot())
  }

  /// Vectors are stored as little-endian 32-bit floats: half the size of the doubles
  /// they came from, and the precision lost is far below the resolution of a
  /// similarity ranking.
  static func encode(_ vector: [Double]) -> Data {
    var data = Data(capacity: vector.count * 4)
    for value in vector {
      var bits = Float(value).bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func decode(_ data: Data) -> [Double] {
    var values: [Double] = []
    values.reserveCapacity(data.count / 4)
    let bytes = [UInt8](data)
    var index = 0
    while index + 4 <= bytes.count {
      var bits: UInt32 = 0
      for offset in 0..<4 { bits |= UInt32(bytes[index + offset]) << (8 * UInt32(offset)) }
      values.append(Double(Float(bitPattern: bits)))
      index += 4
    }
    return values
  }

  /// Lower-cases, collapses runs of whitespace and truncates — in one linear pass, so
  /// a pathological record (a log file pasted into a note, a transcript with no
  /// punctuation for a hundred thousand characters) costs a bounded amount of work
  /// rather than whatever a pattern match would have decided to cost.
  static func normalise(_ text: String, maximumCharacters: Int = 1_000) -> String {
    var result = ""
    result.reserveCapacity(min(text.count, maximumCharacters))
    var written = 0
    var lastWasSpace = true
    for character in text {
      if written >= maximumCharacters { break }
      if character.isWhitespace {
        if lastWasSpace { continue }
        result.append(" ")
        lastWasSpace = true
      } else {
        result.append(character)
        lastWasSpace = false
      }
      written += 1
    }
    return result.trimmingCharacters(in: .whitespaces).lowercased()
  }
}
