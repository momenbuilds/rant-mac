import Foundation

#if canImport(NaturalLanguage)
@preconcurrency import NaturalLanguage
#endif

/// Turns text into a vector. Behind a protocol so the index can be tested with a
/// deterministic embedder rather than whatever Apple's model happens to produce on
/// the machine running the tests.
public protocol TextEmbedding: Sendable {
  /// The number of dimensions every vector from this embedder has. Mixing widths in
  /// one index would silently produce meaningless similarities, so it is checked.
  var dimensions: Int { get }
  /// Nil when the text cannot be embedded — an unknown language, an empty string, or
  /// a model that is not present.
  func vector(for text: String) -> [Float]?
  var isAvailable: Bool { get }
}

#if canImport(NaturalLanguage)
/// Apple's on-device sentence embedding.
///
/// Local by construction: `NLEmbedding` ships with the OS and does no networking, so
/// semantic search cannot become a quiet reason for your transcripts to leave the
/// machine. It is also why this is opt-in rather than automatic — the model is only
/// present for some languages, and an index that silently covers half your history
/// is worse than one you chose to build.
///
/// `@unchecked Sendable` because `NLEmbedding` is not marked `Sendable` but is only
/// ever *read* here — it is loaded once in `init` and never mutated. The alternative,
/// re-loading the model per call, would be far slower for no safety gained.
public final class AppleTextEmbedding: TextEmbedding, @unchecked Sendable {
  private let embedding: NLEmbedding?

  public init(language: NLLanguage = .english) {
    self.embedding = NLEmbedding.sentenceEmbedding(for: language)
  }

  public var dimensions: Int { embedding?.dimension ?? 0 }
  public var isAvailable: Bool { embedding != nil }

  public func vector(for text: String) -> [Float]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let embedding else { return nil }
    // `NLEmbedding` works on a sentence, so a long transcript is truncated rather
    // than averaged: the opening of a dictation is what people search for, and
    // averaging a whole paragraph blurs it into nothing.
    let clipped = String(trimmed.prefix(1_000))
    guard let doubles = embedding.vector(for: clipped) else { return nil }
    return doubles.map(Float.init)
  }
}
#endif

/// Deterministic embedder for tests and for machines where Apple's model is absent.
///
/// A bag-of-words hash projected onto a fixed number of dimensions. It is not a good
/// semantic model and is not pretending to be one — it exists so the index's own
/// behaviour (storage, incremental indexing, the similarity cutoff) can be asserted
/// without depending on a model that may or may not be installed.
public struct HashingTextEmbedding: TextEmbedding {
  public let dimensions: Int
  public var isAvailable: Bool { true }

  public init(dimensions: Int = 64) {
    self.dimensions = dimensions
  }

  public func vector(for text: String) -> [Float]? {
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
    guard !words.isEmpty else { return nil }
    var vector = [Float](repeating: 0, count: dimensions)
    for word in words {
      var hash: UInt64 = 1_469_598_103_934_665_603
      for byte in word.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
      }
      vector[Int(hash % UInt64(dimensions))] += 1
    }
    return vector
  }
}

/// What a semantic hit refers to.
public enum SemanticKind: String, Sendable, CaseIterable {
  case transcript, note, meeting
}

public struct SemanticHit: Equatable, Sendable {
  public var kind: SemanticKind
  public var rowID: Int64
  public var text: String
  public var similarity: Double

  public init(kind: SemanticKind, rowID: Int64, text: String, similarity: Double) {
    self.kind = kind
    self.rowID = rowID
    self.text = text
    self.similarity = similarity
  }
}

/// Optional local semantic recall over transcripts, notes and meetings.
///
/// **Why the table is created here rather than in `Migrations.swift`.** Everything in
/// this index is derived data: it can be thrown away and rebuilt from rows that
/// already exist, it is only useful to someone who turned the feature on, and its
/// shape depends on the embedder's width, which is a runtime fact rather than a
/// schema one. Putting it in the migration list would make every user carry a table
/// for a feature most will never enable, and would tie a rebuildable cache to the
/// versioning of data that is not rebuildable. So it is created lazily, on first use,
/// with `CREATE TABLE IF NOT EXISTS`.
///
/// It is also the reason `rebuild` exists and is safe to call: dropping and
/// regenerating this table loses nothing.
public actor SemanticIndex {
  private let database: Database
  private let embedder: any TextEmbedding
  private let log = RantLog("Semantic")
  private var prepared = false

  /// Below this, a match is noise. Returning the least-bad row for a query about
  /// something the user never said is worse than returning nothing, because it looks
  /// like an answer.
  public static let defaultCutoff = 0.55

  public init(database: Database, embedder: any TextEmbedding) {
    self.database = database
    self.embedder = embedder
  }

  public var isAvailable: Bool { embedder.isAvailable && embedder.dimensions > 0 }

  // MARK: - Schema

  private func prepare() throws {
    guard !prepared else { return }
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS semantic_vectors (
        kind        TEXT NOT NULL,
        row_id      INTEGER NOT NULL,
        dimensions  INTEGER NOT NULL,
        vector      BLOB NOT NULL,
        text        TEXT NOT NULL,
        indexed_at  REAL NOT NULL,
        PRIMARY KEY (kind, row_id)
      );
      """)
    prepared = true
  }

  // MARK: - Indexing

  /// Indexes anything not already indexed. Incremental and resumable: it asks for the
  /// rows that have no vector yet, so an interrupted run simply picks up where it
  /// stopped rather than starting again.
  @discardableResult
  public func indexPending(limit: Int = 200) throws -> Int {
    guard isAvailable else { return 0 }
    try prepare()

    var indexed = 0
    indexed += try indexRows(
      kind: .transcript,
      sql: """
        SELECT t.id, t.final_text FROM transcripts t
        LEFT JOIN semantic_vectors v ON v.kind = 'transcript' AND v.row_id = t.id
        WHERE v.row_id IS NULL LIMIT ?
        """,
      limit: limit)
    indexed += try indexRows(
      kind: .note,
      sql: """
        SELECT n.id, n.title || ' ' || n.body FROM notes n
        LEFT JOIN semantic_vectors v ON v.kind = 'note' AND v.row_id = n.id
        WHERE v.row_id IS NULL LIMIT ?
        """,
      limit: limit)
    indexed += try indexRows(
      kind: .meeting,
      sql: """
        SELECT s.id, s.text FROM meeting_segments s
        LEFT JOIN semantic_vectors v ON v.kind = 'meeting' AND v.row_id = s.id
        WHERE v.row_id IS NULL LIMIT ?
        """,
      limit: limit)

    if indexed > 0 { log.info("indexed \(indexed) rows") }
    return indexed
  }

  private func indexRows(kind: SemanticKind, sql: String, limit: Int) throws -> Int {
    let rows = try database.query(sql, [.int(limit)]) { (Int64($0.int(0)), $0.string(1)) }
    guard !rows.isEmpty else { return 0 }

    return try database.transaction {
      var count = 0
      for (id, text) in rows {
        guard let vector = embedder.vector(for: text) else {
          // Record the attempt so an unembeddable row is not retried on every sweep.
          try database.run(
            """
            INSERT OR REPLACE INTO semantic_vectors
              (kind, row_id, dimensions, vector, text, indexed_at)
            VALUES (?,?,0,?,?,?)
            """,
            [.text(kind.rawValue), .int(Int(id)), .blob(Data()), .text(""), SQLValue(Date())])
          continue
        }
        try database.run(
          """
          INSERT OR REPLACE INTO semantic_vectors
            (kind, row_id, dimensions, vector, text, indexed_at)
          VALUES (?,?,?,?,?,?)
          """,
          [
            .text(kind.rawValue), .int(Int(id)), .int(vector.count),
            .blob(Self.encode(vector)), .text(String(text.prefix(400))), SQLValue(Date()),
          ])
        count += 1
      }
      return count
    }
  }

  /// Drops and regenerates everything. Safe because the index is derived data.
  public func rebuild() throws {
    try prepare()
    try database.execute("DELETE FROM semantic_vectors;")
    var total = 0
    while true {
      let batch = try indexPending()
      if batch == 0 { break }
      total += batch
    }
    log.info("rebuilt semantic index over \(total) rows")
  }

  public func indexedCount() throws -> Int {
    try prepare()
    return try database.query(
      "SELECT COUNT(*) FROM semantic_vectors WHERE dimensions > 0") { $0.int(0) }.first ?? 0
  }

  // MARK: - Search

  /// Rows most like `query`, best first.
  ///
  /// Returns an empty array — never a best guess — when nothing clears the cutoff or
  /// when the embedder is unavailable. The caller is expected to fall back to the FTS
  /// search, which always works, rather than showing the user a plausible-looking
  /// wrong answer.
  public func search(
    _ query: String,
    kinds: Set<SemanticKind> = Set(SemanticKind.allCases),
    limit: Int = 20,
    cutoff: Double = SemanticIndex.defaultCutoff
  ) throws -> [SemanticHit] {
    guard isAvailable, let target = embedder.vector(for: query) else { return [] }
    try prepare()

    let rows = try database.query(
      "SELECT kind, row_id, dimensions, vector, text FROM semantic_vectors WHERE dimensions > 0"
    ) { row -> (SemanticKind, Int64, Int, Data, String) in
      (
        SemanticKind(rawValue: row.string(0)) ?? .transcript, Int64(row.int(1)), row.int(2),
        row.data(3), row.string(4)
      )
    }

    var hits: [SemanticHit] = []
    for (kind, id, dimensions, blob, text) in rows {
      guard kinds.contains(kind), dimensions == target.count else { continue }
      let vector = Self.decode(blob, count: dimensions)
      let similarity = Self.cosine(target, vector)
      guard similarity >= cutoff else { continue }
      hits.append(SemanticHit(kind: kind, rowID: id, text: text, similarity: similarity))
    }
    return Array(hits.sorted { $0.similarity > $1.similarity }.prefix(limit))
  }

  // MARK: - Maths and storage

  /// Cosine similarity, clamped to 0…1. A zero-length vector has no direction, so it
  /// is similar to nothing rather than to everything.
  static func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Double = 0
    var normA: Double = 0
    var normB: Double = 0
    for index in a.indices {
      dot += Double(a[index]) * Double(b[index])
      normA += Double(a[index]) * Double(a[index])
      normB += Double(b[index]) * Double(b[index])
    }
    guard normA > 0, normB > 0 else { return 0 }
    return max(0, min(1, dot / (normA.squareRoot() * normB.squareRoot())))
  }

  /// Little-endian `Float32`, which is what every machine this runs on uses natively.
  static func encode(_ vector: [Float]) -> Data {
    var data = Data(capacity: vector.count * 4)
    for value in vector {
      withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func decode(_ data: Data, count: Int) -> [Float] {
    guard data.count >= count * 4 else { return [] }
    var vector = [Float]()
    vector.reserveCapacity(count)
    for index in 0..<count {
      let start = index * 4
      let bits = data[start..<(start + 4)].withUnsafeBytes { raw in
        raw.loadUnaligned(as: UInt32.self)
      }
      vector.append(Float(bitPattern: UInt32(littleEndian: bits)))
    }
    return vector
  }
}
