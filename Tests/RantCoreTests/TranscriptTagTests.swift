import XCTest

@testable import RantCore

/// Per-dictation favourites and tags — the two things §20 asks for that the history
/// row could not do.
///
/// Tags are stored comma-separated in one column, which is a fine choice for a
/// personal label always read with its own row and a bad one if the encoding is
/// careless. Most of these tests are about the encoding refusing to lose or invent a
/// tag, and about the schema change not disturbing anything that was already there.
final class TranscriptTagTests: XCTestCase {

  private func store() throws -> SQLiteTranscriptStore {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return SQLiteTranscriptStore(database: database)
  }

  private func transcript(_ text: String, tags: [String] = []) -> Transcript {
    Transcript(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      rawText: text, finalText: text, provider: "test", tags: tags)
  }

  // MARK: - Round trip

  func testTagsSurviveASaveAndRead() throws {
    let store = try store()
    let saved = try store.save(transcript("ship it", tags: ["work", "release"]))
    let id = try XCTUnwrap(saved.id)
    let read = try XCTUnwrap(store.transcript(id: id))
    XCTAssertEqual(read.tags, ["work", "release"])
  }

  func testADictationWithNoTagsReadsBackAsEmptyRatherThanOneBlankTag() throws {
    let store = try store()
    let saved = try store.save(transcript("no labels"))
    let read = try XCTUnwrap(store.transcript(id: try XCTUnwrap(saved.id)))
    XCTAssertEqual(read.tags, [])
  }

  func testTagsCanBeChangedAfterTheFact() throws {
    let store = try store()
    let saved = try store.save(transcript("later", tags: ["draft"]))
    let id = try XCTUnwrap(saved.id)
    try store.setTags(id: id, ["final", "sent"])
    let read = try XCTUnwrap(store.transcript(id: id))
    XCTAssertEqual(read.tags, ["final", "sent"])
  }

  func testTagsCanBeCleared() throws {
    let store = try store()
    let saved = try store.save(transcript("clear me", tags: ["a", "b"]))
    let id = try XCTUnwrap(saved.id)
    try store.setTags(id: id, [])
    let read = try XCTUnwrap(store.transcript(id: id))
    XCTAssertEqual(read.tags, [])
  }

  // MARK: - The encoding

  /// The failure this storage choice invites: a comma typed inside a tag has to become
  /// two tags rather than one label that reads back split in a surprising place.
  func testACommaInsideATagBecomesTwoTagsRatherThanOneBrokenOne() {
    XCTAssertEqual(
      SQLiteTranscriptStore.decodeTags(
        SQLiteTranscriptStore.encodeTags(["work, urgent"])),
      ["work", "urgent"])
  }

  func testBlankAndWhitespaceOnlyTagsAreDropped() {
    XCTAssertEqual(
      SQLiteTranscriptStore.decodeTags(
        SQLiteTranscriptStore.encodeTags(["  ", "work", "", "  home  "])),
      ["work", "home"])
  }

  func testNoTagsIsStoredAsNullRatherThanAnEmptyString() {
    XCTAssertNil(SQLiteTranscriptStore.encodeTags([]))
    XCTAssertNil(SQLiteTranscriptStore.encodeTags(["", "   "]))
  }

  func testOrderIsPreserved() {
    let tags = ["zebra", "apple", "mango"]
    XCTAssertEqual(
      SQLiteTranscriptStore.decodeTags(SQLiteTranscriptStore.encodeTags(tags)), tags)
  }

  // MARK: - Favourites

  func testFavouriteSurvivesAndCanBeToggled() throws {
    let store = try store()
    let saved = try store.save(transcript("keep this"))
    let id = try XCTUnwrap(saved.id)
    XCTAssertFalse(saved.favourite)

    try store.setFavourite(id: id, true)
    XCTAssertTrue(try XCTUnwrap(store.transcript(id: id)).favourite)

    try store.setFavourite(id: id, false)
    XCTAssertFalse(try XCTUnwrap(store.transcript(id: id)).favourite)
  }

  // MARK: - The schema change

  /// Adding a column shifted the index the search snippet was read from, and the
  /// snippet was a literal. Everything decoded fine and the highlight silently
  /// disappeared, which is exactly the kind of break a round-trip test misses.
  func testSearchStillReturnsAHighlightedSnippetAfterTheSchemaGrew() throws {
    let store = try store()
    _ = try store.save(transcript("the migration center imports your history"))
    let hits = try store.search("migration")
    XCTAssertEqual(hits.count, 1)
    let snippet = try XCTUnwrap(hits.first?.snippet)
    XCTAssertTrue(snippet.contains("⟦"), "the snippet should mark the match: \(snippet)")
  }

  /// A database written before version 8 has to keep its rows and gain the column.
  ///
  /// The old row is inserted with SQL rather than through the store, because the store
  /// always speaks the *current* schema — writing through it would be testing the new
  /// code against the new shape, which proves nothing about an upgrade. This is what
  /// actually happens: a database from an older release, opened by a newer build.
  func testADatabaseFromTheVersionBeforeTagsMigratesWithoutLosingAnything() throws {
    let database = try Database(url: nil)
    try Migrations.migrate(database, upTo: 7)
    try database.run(
      """
      INSERT INTO transcripts
        (created_at, raw_text, final_text, provider, cleanup_level, category,
         duration_ms, word_count, enhanced, content_hash, source, favourite)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      """,
      [
        SQLValue(Date(timeIntervalSince1970: 1_700_000_000)),
        .text("written before tags existed"), .text("written before tags existed"),
        .text("test"), .text("medium"), .text("other"), .int(1_000), .int(4),
        SQLValue(false), .text("hash-from-an-older-release"), .text("rant"),
        SQLValue(true),
      ])

    try Migrations.migrate(database)
    XCTAssertEqual(database.userVersion, Migrations.latestVersion)

    let after = SQLiteTranscriptStore(database: database)
    let rows = try after.recent()
    let read = try XCTUnwrap(rows.first)
    XCTAssertEqual(read.finalText, "written before tags existed")
    XCTAssertTrue(read.favourite, "the upgrade must not disturb the columns it found")
    XCTAssertEqual(read.tags, [], "an existing row gains the column with no tags")

    let id = try XCTUnwrap(read.id)
    try after.setTags(id: id, ["kept"])
    XCTAssertEqual(try XCTUnwrap(after.transcript(id: id)).tags, ["kept"])
  }
}
