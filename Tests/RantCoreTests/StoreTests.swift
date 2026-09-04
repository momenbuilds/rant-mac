import XCTest
@testable import RantCore

/// Storage tests run against a real in-memory SQLite database, so they exercise the
/// same SQL, the same triggers and the same constraints as production rather than a
/// stand-in that agrees with the code.
final class StoreTests: XCTestCase {

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func store() throws -> (SQLiteTranscriptStore, Database) {
    let database = try freshDatabase()
    return (SQLiteTranscriptStore(database: database), database)
  }

  private func sample(
    _ text: String = "Hello there.", at date: Date = Date(), source: String = "rant",
    category: UsageCategory = .other, durationMs: Int = 2_000
  ) -> Transcript {
    Transcript(
      createdAt: date, rawText: "um hello there", finalText: text, provider: "test",
      category: category, durationMilliseconds: durationMs, source: source)
  }

  // MARK: - Migrations

  func testMigrationsBringAnEmptyDatabaseToTheLatestVersion() throws {
    let database = try Database(url: nil)
    XCTAssertEqual(database.userVersion, 0)
    let applied = try Migrations.migrate(database)
    XCTAssertEqual(applied, Migrations.latestVersion)
    XCTAssertEqual(database.userVersion, Migrations.latestVersion)
  }

  /// A migration that only works when run after a later one is a migration that
  /// breaks for anyone upgrading. Applying every prefix catches that.
  func testEveryPrefixOfTheMigrationListAppliesCleanly() throws {
    for target in 1...Migrations.latestVersion {
      let database = try Database(url: nil)
      XCTAssertEqual(try Migrations.migrate(database, upTo: target), target,
                     "migrating to version \(target) from empty failed")
    }
  }

  /// Upgrading one version at a time must reach the same place as migrating in one go.
  func testSteppingOneVersionAtATimeReachesTheSameSchema() throws {
    let stepwise = try Database(url: nil)
    for target in 1...Migrations.latestVersion {
      try Migrations.migrate(stepwise, upTo: target)
    }
    let direct = try freshDatabase()

    func schema(_ database: Database) throws -> [String] {
      try database.query(
        "SELECT name || '|' || COALESCE(sql,'') FROM sqlite_master ORDER BY name"
      ) { $0.string(0) }
    }
    XCTAssertEqual(try schema(stepwise), try schema(direct))
  }

  func testMigratingAnAlreadyCurrentDatabaseIsANoOp() throws {
    let database = try freshDatabase()
    XCTAssertEqual(try Migrations.migrate(database), Migrations.latestVersion)
  }

  func testMigrationVersionsAreUniqueAndContiguous() {
    let versions = Migrations.all.map(\.version).sorted()
    XCTAssertEqual(versions, Array(1...Migrations.latestVersion),
                   "migration versions must be 1…n with no gaps or repeats")
  }

  // MARK: - CRUD

  func testSavingAndReadingBack() throws {
    let (store, _) = try store()
    let saved = try store.save(sample("The build is green."))
    XCTAssertNotNil(saved.id)
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.transcript(id: saved.id!)?.finalText, "The build is green.")
  }

  /// Cleanup is lossy, so the input is kept alongside the output.
  func testBothRawAndFinalTextSurvive() throws {
    let (store, _) = try store()
    let saved = try store.save(sample("Hello there."))
    let read = try XCTUnwrap(try store.transcript(id: saved.id!))
    XCTAssertEqual(read.rawText, "um hello there")
    XCTAssertEqual(read.finalText, "Hello there.")
  }

  func testWordCountAndWpmAreDerived() throws {
    let (store, _) = try store()
    let saved = try store.save(
      Transcript(rawText: "", finalText: "one two three four five six",
                 provider: "test", durationMilliseconds: 60_000))
    XCTAssertEqual(saved.wordCount, 6)
    XCTAssertEqual(saved.wordsPerMinute ?? 0, 6, accuracy: 0.01)
  }

  func testVeryShortRecordingsProduceNoWpmRatherThanAbsurdOnes() {
    XCTAssertNil(Transcript.wordsPerMinute(words: 3, milliseconds: 100))
  }

  func testRecentIsNewestFirstAndPages() throws {
    let (store, _) = try store()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<5 {
      _ = try store.save(sample("entry \(index)", at: base.addingTimeInterval(Double(index))))
    }
    XCTAssertEqual(try store.recent(limit: 2, offset: 0).map(\.finalText), ["entry 4", "entry 3"])
    XCTAssertEqual(try store.recent(limit: 2, offset: 2).map(\.finalText), ["entry 2", "entry 1"])
  }

  func testEditingATranscriptUpdatesItsWordCount() throws {
    let (store, _) = try store()
    let saved = try store.save(sample("one two"))
    try store.update(id: saved.id!, finalText: "one two three four")
    XCTAssertEqual(try store.transcript(id: saved.id!)?.wordCount, 4)
  }

  func testFavouriting() throws {
    let (store, _) = try store()
    let saved = try store.save(sample())
    try store.setFavourite(id: saved.id!, true)
    XCTAssertEqual(try store.transcript(id: saved.id!)?.favourite, true)
  }

  // MARK: - Deletion

  func testDeletingOne() throws {
    let (store, _) = try store()
    let a = try store.save(sample("first", at: Date(timeIntervalSince1970: 1)))
    _ = try store.save(sample("second", at: Date(timeIntervalSince1970: 2)))
    try store.delete(id: a.id!)
    XCTAssertEqual(try store.count(), 1)
  }

  func testDeletingMany() throws {
    let (store, _) = try store()
    var ids: [Int64] = []
    for index in 0..<4 {
      ids.append(try store.save(sample("row \(index)", at: Date(timeIntervalSince1970: Double(index)))).id!)
    }
    try store.delete(ids: Array(ids.prefix(3)))
    XCTAssertEqual(try store.count(), 1)
  }

  /// "Delete everything" that leaves your word count on the Insights screen is not
  /// deleting everything.
  func testDeleteAllAlsoClearsDerivedStatistics() throws {
    let (store, database) = try store()
    _ = try store.save(sample("some words here"))
    XCTAssertGreaterThan(try database.query("SELECT COUNT(*) FROM usage_daily") { $0.int(0) }.first ?? 0, 0)

    try store.deleteAll()
    XCTAssertEqual(try store.count(), 0)
    XCTAssertEqual(try database.query("SELECT COUNT(*) FROM usage_daily") { $0.int(0) }.first ?? 0, 0)
    XCTAssertEqual(try database.query("SELECT COUNT(*) FROM app_usage") { $0.int(0) }.first ?? 0, 0)
  }

  func testDeletingATranscriptRemovesItFromSearchToo() throws {
    let (store, _) = try store()
    let saved = try store.save(sample("a memorable phrase"))
    XCTAssertEqual(try store.search("memorable", limit: 10).count, 1)
    try store.delete(id: saved.id!)
    XCTAssertEqual(try store.search("memorable", limit: 10).count, 0,
                   "the FTS index must be kept in step by the delete trigger")
  }

  // MARK: - Search

  func testFullTextSearchFindsBySingleWord() throws {
    let (store, _) = try store()
    _ = try store.save(sample("we should migrate the API next week"))
    _ = try store.save(sample("lunch plans for tomorrow", at: Date(timeIntervalSince1970: 5)))
    let hits = try store.search("migrate", limit: 10)
    XCTAssertEqual(hits.count, 1)
    XCTAssertTrue(hits[0].transcript.finalText.contains("migrate"))
  }

  func testSearchMatchesPrefixes() throws {
    let (store, _) = try store()
    _ = try store.save(sample("the migration is finished"))
    XCTAssertEqual(try store.search("migr", limit: 10).count, 1)
  }

  func testSearchRequiresAllTerms() throws {
    let (store, _) = try store()
    _ = try store.save(sample("the API migration"))
    _ = try store.save(sample("the database migration", at: Date(timeIntervalSince1970: 9)))
    XCTAssertEqual(try store.search("API migration", limit: 10).count, 1)
  }

  func testSearchAlsoLooksAtTheRawTranscript() throws {
    let (store, _) = try store()
    _ = try store.save(
      Transcript(rawText: "um the flibbertigibbet thing", finalText: "The thing.", provider: "t"))
    XCTAssertEqual(try store.search("flibbertigibbet", limit: 10).count, 1)
  }

  func testSearchReturnsASnippet() throws {
    let (store, _) = try store()
    _ = try store.save(sample("a long sentence that mentions Supabase somewhere in the middle of it"))
    let hit = try XCTUnwrap(try store.search("Supabase", limit: 1).first)
    XCTAssertTrue(hit.snippet.contains("⟦"), "the snippet should mark the match: \(hit.snippet)")
  }

  /// A user typing a quote or an apostrophe must get results, not an FTS syntax error.
  func testSearchSurvivesPunctuationAndQuotesInTheQuery() throws {
    let (store, _) = try store()
    _ = try store.save(sample("the client's request"))
    for query in ["client's", "\"client", "client OR", "*", "()", "NEAR/", "-", "AND"] {
      XCTAssertNoThrow(try store.search(query, limit: 10), "query \(query) threw")
    }
  }

  func testEmptySearchReturnsNothingRatherThanEverything() throws {
    let (store, _) = try store()
    _ = try store.save(sample())
    XCTAssertEqual(try store.search("   ", limit: 10).count, 0)
  }

  func testSearchIsDiacriticInsensitive() throws {
    let (store, _) = try store()
    _ = try store.save(sample("we met with Renée"))
    XCTAssertEqual(try store.search("Renee", limit: 10).count, 1)
  }

  // MARK: - Deduplication

  /// Importing the same export twice must be a no-op, not a mess.
  func testSavingTheSameContentTwiceIsIdempotent() throws {
    let (store, _) = try store()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try store.save(sample("identical content", at: date, source: "wispr_flow"))
    let second = try store.save(sample("identical content", at: date, source: "wispr_flow"))
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(first.id, second.id)
  }

  func testTheSameWordsAtDifferentTimesAreTwoRealDictations() throws {
    let (store, _) = try store()
    _ = try store.save(sample("yes", at: Date(timeIntervalSince1970: 100)))
    _ = try store.save(sample("yes", at: Date(timeIntervalSince1970: 900)))
    XCTAssertEqual(try store.count(), 2)
  }

  func testTheSameWordsFromDifferentSourcesAreDistinct() throws {
    let (store, _) = try store()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.save(sample("shared line", at: date, source: "rant"))
    _ = try store.save(sample("shared line", at: date, source: "otter"))
    XCTAssertEqual(try store.count(), 2)
  }

  /// Exports round-trip through formats with different time precision; a millisecond
  /// of drift must not create a duplicate.
  func testHashIgnoresSubSecondDriftAndWhitespace() {
    let a = Transcript.hash(text: "Hello  there", createdAt: Date(timeIntervalSince1970: 10.2), source: "x")
    let b = Transcript.hash(text: "hello there", createdAt: Date(timeIntervalSince1970: 10.4), source: "x")
    XCTAssertEqual(a, b)
  }

  // MARK: - Usage aggregates

  func testSavingUpdatesTheDailyAggregates() throws {
    let (store, database) = try store()
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.save(sample("one two three", at: day, category: .developer))
    _ = try store.save(sample("four five", at: day.addingTimeInterval(30), category: .developer))

    let words = try database.query("SELECT words, dictations FROM usage_daily") {
      ($0.int(0), $0.int(1))
    }
    XCTAssertEqual(words.first?.0, 5)
    XCTAssertEqual(words.first?.1, 2)

    let byCategory = try database.query(
      "SELECT category, words FROM app_usage") { ($0.string(0), $0.int(1)) }
    XCTAssertEqual(byCategory.first?.0, "developer")
    XCTAssertEqual(byCategory.first?.1, 5)
  }

  /// A duplicate must not inflate the statistics either.
  func testDuplicateSavesDoNotDoubleCountUsage() throws {
    let (store, database) = try store()
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.save(sample("one two three", at: day))
    _ = try store.save(sample("one two three", at: day))
    let dictations = try database.query("SELECT dictations FROM usage_daily") { $0.int(0) }.first
    XCTAssertEqual(dictations, 1, "the same dictation was counted twice")
  }

  // MARK: - Persistence

  func testDataSurvivesClosingAndReopeningTheFile() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("rant-test-\(UUID().uuidString)")
      .appendingPathComponent("rant.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    do {
      let database = try Database(url: url)
      try Migrations.migrate(database)
      _ = try SQLiteTranscriptStore(database: database).save(sample("persisted"))
      database.close()
    }
    let reopened = try Database(url: url)
    XCTAssertEqual(reopened.userVersion, Migrations.latestVersion)
    XCTAssertEqual(try SQLiteTranscriptStore(database: reopened).count(), 1)
  }

  func testForeignKeysCascadeSoDeletingAMeetingRemovesItsSegments() throws {
    let database = try freshDatabase()
    try database.run(
      "INSERT INTO meetings (started_at, content_hash) VALUES (?, ?)",
      [SQLValue(Date()), .text("hash-1")])
    try database.run(
      "INSERT INTO meeting_segments (meeting_id, started_ms, text) VALUES (1, 0, 'hello')")
    try database.run("DELETE FROM meetings WHERE id = 1")
    XCTAssertEqual(
      try database.query("SELECT COUNT(*) FROM meeting_segments") { $0.int(0) }.first, 0)
  }
}
