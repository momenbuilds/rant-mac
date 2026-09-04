import XCTest
@testable import RantCore

/// Semantic search is optional, local, and allowed to say "nothing". These tests use
/// a deterministic embedder so they assert the index's own behaviour — storage,
/// incremental indexing, the cutoff — rather than the quality of whatever model
/// happens to be installed on the machine running them.
final class SemanticSearchTests: XCTestCase {

  private func fixture() throws -> (Database, SemanticIndex, SQLiteTranscriptStore) {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    let index = SemanticIndex(database: database, embedder: HashingTextEmbedding())
    return (database, index, SQLiteTranscriptStore(database: database))
  }

  private func save(_ store: SQLiteTranscriptStore, _ text: String, at seconds: TimeInterval) throws {
    _ = try store.save(
      Transcript(
        createdAt: Date(timeIntervalSince1970: seconds), rawText: text, finalText: text,
        provider: "test"))
  }

  // MARK: - Vector maths

  func testCosineOfAVectorWithItselfIsOne() {
    XCTAssertEqual(SemanticIndex.cosine([1, 2, 3], [1, 2, 3]), 1, accuracy: 0.0001)
  }

  func testCosineOfOrthogonalVectorsIsZero() {
    XCTAssertEqual(SemanticIndex.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
  }

  /// A zero-length vector has no direction, so it is similar to nothing rather than
  /// to everything — which is what a naive division would produce.
  func testAZeroVectorIsSimilarToNothing() {
    XCTAssertEqual(SemanticIndex.cosine([0, 0, 0], [1, 2, 3]), 0)
    XCTAssertEqual(SemanticIndex.cosine([0, 0], [0, 0]), 0)
  }

  func testMismatchedWidthsAreNeverCompared() {
    XCTAssertEqual(SemanticIndex.cosine([1, 2, 3], [1, 2]), 0)
  }

  func testVectorsSurviveEncodingAndDecoding() {
    let original: [Float] = [0, 1, -1, 0.5, 1_234.5, -0.000_1]
    let decoded = SemanticIndex.decode(SemanticIndex.encode(original), count: original.count)
    XCTAssertEqual(decoded, original)
  }

  func testDecodingATruncatedBlobYieldsNothingRatherThanGarbage() {
    let data = SemanticIndex.encode([1, 2, 3]).prefix(6)
    XCTAssertTrue(SemanticIndex.decode(Data(data), count: 3).isEmpty)
  }

  // MARK: - Indexing

  func testIndexingIsIncrementalAndResumable() async throws {
    let (_, index, store) = try fixture()
    for number in 0..<5 {
      try save(store, "transcript number \(number)", at: Double(number))
    }

    let first = try await index.indexPending()
    XCTAssertEqual(first, 5)

    // A second sweep finds nothing new; it does not redo the work.
    let second = try await index.indexPending()
    XCTAssertEqual(second, 0)

    try save(store, "a later thought", at: 99)
    let third = try await index.indexPending()
    XCTAssertEqual(third, 1)

    let total = try await index.indexedCount()
    XCTAssertEqual(total, 6)
  }

  func testNotesAndMeetingSegmentsAreIndexedToo() async throws {
    let (database, index, _) = try fixture()
    let notes = NoteStore(database: database)
    _ = try notes.create(title: "Plan", body: "we should migrate the database")

    try database.run(
      "INSERT INTO meetings (started_at, content_hash) VALUES (?, ?)",
      [SQLValue(Date()), .text("meeting-hash")])
    try database.run(
      "INSERT INTO meeting_segments (meeting_id, started_ms, text) VALUES (1, 0, 'quarterly planning')")

    let indexed = try await index.indexPending()
    XCTAssertEqual(indexed, 2)
    let total = try await index.indexedCount()
    XCTAssertEqual(total, 2)
  }

  /// An unembeddable row must be recorded as attempted, or every sweep retries it for
  /// ever and indexing never converges.
  func testRowsThatCannotBeEmbeddedAreNotRetriedForever() async throws {
    let (_, index, store) = try fixture()
    try save(store, "   ", at: 1)
    _ = try await index.indexPending()

    let again = try await index.indexPending()
    XCTAssertEqual(again, 0, "an unembeddable row was retried")

    let counted = try await index.indexedCount()
    XCTAssertEqual(counted, 0, "it must not count as indexed either")
  }

  func testRebuildIsSafeAndProducesTheSameIndex() async throws {
    let (_, index, store) = try fixture()
    for number in 0..<4 { try save(store, "thought \(number)", at: Double(number)) }
    _ = try await index.indexPending()
    let before = try await index.indexedCount()

    try await index.rebuild()
    let after = try await index.indexedCount()
    XCTAssertEqual(after, before)
  }

  // MARK: - Searching

  func testSearchFindsTheRowThatActuallyMatches() async throws {
    let (_, index, store) = try fixture()
    try save(store, "we should migrate the database to Postgres", at: 1)
    try save(store, "lunch plans for tomorrow with Marcus", at: 2)
    _ = try await index.indexPending()

    let hits = try await index.search("migrate the database to Postgres", cutoff: 0.5)
    XCTAssertEqual(hits.first?.kind, .transcript)
    XCTAssertTrue(hits.first?.text.contains("migrate") ?? false)
  }

  /// The behaviour that matters most: an unrelated query returns nothing rather than
  /// the least-bad row. A plausible-looking wrong answer is worse than no answer.
  func testAnUnrelatedQueryReturnsNothingRatherThanTheLeastBadMatch() async throws {
    let (_, index, store) = try fixture()
    try save(store, "we should migrate the database to Postgres", at: 1)
    try save(store, "lunch plans for tomorrow with Marcus", at: 2)
    _ = try await index.indexPending()

    let hits = try await index.search("submarine periscope maintenance schedule")
    XCTAssertTrue(hits.isEmpty, "returned \(hits.map(\.text))")
  }

  func testResultsAreOrderedBestFirst() async throws {
    let (_, index, store) = try fixture()
    try save(store, "database migration plan", at: 1)
    try save(store, "database migration plan and rollout and staffing and budget", at: 2)
    _ = try await index.indexPending()

    let hits = try await index.search("database migration plan", cutoff: 0.1)
    XCTAssertGreaterThanOrEqual(hits.count, 2)
    XCTAssertGreaterThanOrEqual(hits[0].similarity, hits[1].similarity)
  }

  func testSearchCanBeLimitedToOneKind() async throws {
    let (database, index, store) = try fixture()
    try save(store, "database migration plan", at: 1)
    _ = try NoteStore(database: database).create(title: "database migration plan", body: "")
    _ = try await index.indexPending()

    let notesOnly = try await index.search("database migration plan", kinds: [.note], cutoff: 0.1)
    XCTAssertFalse(notesOnly.isEmpty)
    XCTAssertTrue(notesOnly.allSatisfy { $0.kind == .note })
  }

  func testSearchRespectsItsLimit() async throws {
    let (_, index, store) = try fixture()
    for number in 0..<10 { try save(store, "shared words here \(number)", at: Double(number)) }
    _ = try await index.indexPending()

    let hits = try await index.search("shared words here", limit: 3, cutoff: 0.1)
    XCTAssertLessThanOrEqual(hits.count, 3)
  }

  func testAnEmptyQueryFindsNothing() async throws {
    let (_, index, store) = try fixture()
    try save(store, "something", at: 1)
    _ = try await index.indexPending()

    let hits = try await index.search("   ")
    XCTAssertTrue(hits.isEmpty)
  }

  func testSearchingAnEmptyIndexIsHarmless() async throws {
    let (_, index, _) = try fixture()
    let hits = try await index.search("anything at all")
    XCTAssertTrue(hits.isEmpty)
  }

  // MARK: - Availability

  /// The feature is optional, so an absent model must degrade to "no semantic hits"
  /// and let the caller fall back to full-text search — never fail, never block.
  func testAnUnavailableEmbedderYieldsNoHitsRatherThanAnError() async throws {
    struct Absent: TextEmbedding {
      var dimensions: Int { 0 }
      var isAvailable: Bool { false }
      func vector(for text: String) -> [Float]? { nil }
    }
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    let store = SQLiteTranscriptStore(database: database)
    _ = try store.save(Transcript(rawText: "x", finalText: "hello there", provider: "t"))

    let index = SemanticIndex(database: database, embedder: Absent())
    let available = await index.isAvailable
    XCTAssertFalse(available)

    let indexed = try await index.indexPending()
    XCTAssertEqual(indexed, 0)

    let hits = try await index.search("hello")
    XCTAssertTrue(hits.isEmpty)
  }

  /// The table is created on first use rather than by a schema migration, so a user
  /// who never enables the feature never carries it.
  func testTheIndexTableIsNotCreatedUntilTheFeatureIsUsed() throws {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    let tables = try database.query(
      "SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) }
    XCTAssertFalse(tables.contains("semantic_vectors"))
  }

  func testTheIndexTableAppearsOnceTheFeatureIsUsed() async throws {
    let (database, index, _) = try fixture()
    _ = try await index.indexPending()
    let tables = try database.query(
      "SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) }
    XCTAssertTrue(tables.contains("semantic_vectors"))
  }

  // MARK: - Robustness

  func testIndexingLargeAndAwkwardTextDoesNotHang() async throws {
    let (_, index, store) = try fixture()
    try save(store, String(repeating: "word ", count: 20_000), at: 1)
    try save(store, String(repeating: "a", count: 50_000), at: 2)
    try save(store, "🙂 emoji only 🙂", at: 3)

    let started = ContinuousClock.now
    _ = try await index.indexPending()
    _ = try await index.search("word")
    let elapsed = ContinuousClock.now - started
    XCTAssertLessThan(elapsed, .seconds(10), "indexing awkward text took \(elapsed)")
  }
}
