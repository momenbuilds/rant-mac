import XCTest

@testable import RantCore

/// The scratchpad runs against a real in-memory database, so the FTS triggers, the
/// unique index and the tag column behave exactly as they will on a user's machine
/// rather than as a stand-in that agrees with the code.
final class ScratchpadTests: XCTestCase {

  private func makeStore() throws -> (NoteStore, Database) {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return (NoteStore(database: database), database)
  }

  private let day = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Creating

  func testANoteIsSavedAndReadBack() throws {
    let (store, _) = try makeStore()
    let note = try store.create(title: "Ideas", body: "Ship the thing.", at: day)
    let id = try XCTUnwrap(note.id)
    let read = try XCTUnwrap(store.note(id: id))
    XCTAssertEqual(read.title, "Ideas")
    XCTAssertEqual(read.body, "Ship the thing.")
    XCTAssertEqual(try store.count(), 1)
  }

  /// Importing the same export twice must leave one copy, and the caller must not have
  /// to know which of the two calls did the writing.
  func testCreatingTheSameNoteTwiceIsIdempotent() throws {
    let (store, _) = try makeStore()
    let first = try store.create(title: "Ideas", body: "Ship the thing.", at: day)
    let second = try store.create(title: "Ideas", body: "Ship the thing.", at: day)
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(first.id, second.id)
  }

  func testTheSameWordsWrittenAtDifferentTimesAreTwoNotes() throws {
    let (store, _) = try makeStore()
    _ = try store.create(body: "same words", at: day)
    _ = try store.create(body: "same words", at: day.addingTimeInterval(3_600))
    XCTAssertEqual(try store.count(), 2)
  }

  func testTheHashIgnoresSubSecondDriftAndWhitespace() {
    let a = Note.hash(title: "A", body: "one  two", createdAt: day.addingTimeInterval(0.2),
                      source: "rant")
    let b = Note.hash(title: "a", body: "one two", createdAt: day.addingTimeInterval(0.4),
                      source: "rant")
    XCTAssertEqual(a, b)
  }

  // MARK: - Voice append

  func testAppendingAddsToTheEndAsASeparateParagraph() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "First thought.", at: day)
    let id = try XCTUnwrap(note.id)
    _ = try store.append(to: id, text: "Second thought.", at: day.addingTimeInterval(60))

    let read = try XCTUnwrap(store.note(id: id))
    XCTAssertEqual(read.body, "First thought.\n\nSecond thought.")
    XCTAssertEqual(read.updatedAt, day.addingTimeInterval(60))
    XCTAssertEqual(read.createdAt, day)
  }

  /// The hash is the note's identity, fixed at creation. If appending changed it, every
  /// spoken addition would look like a different note to an import.
  func testAppendingDoesNotChangeTheNotesIdentity() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "First.", at: day)
    let id = try XCTUnwrap(note.id)
    _ = try store.append(to: id, text: "Second.", at: day)
    XCTAssertEqual(try store.note(id: id)?.contentHash, note.contentHash)
    XCTAssertEqual(try store.count(), 1)
  }

  func testAppendingNothingIsANoOp() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "Only this.", at: day)
    let id = try XCTUnwrap(note.id)
    _ = try store.append(to: id, text: "   \n ", at: day)
    XCTAssertEqual(try store.note(id: id)?.body, "Only this.")
  }

  func testAppendingToANoteThatIsGoneIsAnErrorRatherThanASilentNewNote() throws {
    let (store, _) = try makeStore()
    XCTAssertThrowsError(try store.append(to: 99, text: "hello")) { error in
      XCTAssertEqual(error as? NoteError, .notFound(99))
    }
    XCTAssertEqual(try store.count(), 0)
  }

  // MARK: - The scratchpad itself

  func testTheScratchpadCollectsADaysThoughtsInOneNote() throws {
    let (store, _) = try makeStore()
    _ = try store.appendToScratchpad("First idea.", at: day)
    _ = try store.appendToScratchpad("Second idea.", at: day.addingTimeInterval(120))

    XCTAssertEqual(try store.count(), 1)
    let note = try XCTUnwrap(store.recent().first)
    XCTAssertEqual(note.body, "First idea.\n\nSecond idea.")
    XCTAssertTrue(note.tags.contains("scratchpad"))
  }

  func testANewDayStartsANewScratchpad() throws {
    let (store, _) = try makeStore()
    _ = try store.appendToScratchpad("Monday.", at: day)
    _ = try store.appendToScratchpad("Tuesday.", at: day.addingTimeInterval(86_400))
    XCTAssertEqual(try store.count(), 2)
  }

  // MARK: - Search

  func testSearchFindsANoteByAWordInItsBody() throws {
    let (store, _) = try makeStore()
    _ = try store.create(title: "Work", body: "we should migrate the API", at: day)
    _ = try store.create(title: "Home", body: "buy milk", at: day.addingTimeInterval(1))
    let hits = try store.search("migrate")
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits.first?.note.title, "Work")
  }

  func testSearchMatchesPrefixesAndTheTitle() throws {
    let (store, _) = try makeStore()
    _ = try store.create(title: "Migration plan", body: "nothing much", at: day)
    XCTAssertEqual(try store.search("migr").count, 1)
  }

  func testSearchReturnsASnippetOfTheBody() throws {
    let (store, _) = try makeStore()
    _ = try store.create(
      body: "a long line that mentions Supabase in the middle of it somewhere", at: day)
    let hit = try XCTUnwrap(store.search("Supabase").first)
    XCTAssertTrue(hit.snippet.contains("⟦"), "the match should be marked: \(hit.snippet)")
  }

  func testDeletingANoteRemovesItFromSearchToo() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "a memorable phrase", at: day)
    XCTAssertEqual(try store.search("memorable").count, 1)
    try store.delete(id: try XCTUnwrap(note.id))
    XCTAssertEqual(try store.search("memorable").count, 0)
  }

  func testEditingANoteKeepsSearchInStep() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "before", at: day)
    let id = try XCTUnwrap(note.id)
    try store.update(id: id, body: "afterwards")
    XCTAssertEqual(try store.search("before").count, 0)
    XCTAssertEqual(try store.search("afterwards").count, 1)
  }

  /// Someone typing an apostrophe deserves results, not an FTS syntax error.
  func testSearchSurvivesPunctuationInTheQuery() throws {
    let (store, _) = try makeStore()
    _ = try store.create(body: "the client's request", at: day)
    for query in ["client's", "\"client", "client OR", "*", "()", "NEAR/", "-", "AND", "   "] {
      XCTAssertNoThrow(try store.search(query), "query \(query) threw")
    }
    XCTAssertEqual(try store.search("   ").count, 0)
  }

  // MARK: - Pinning and tags

  func testPinnedNotesComeFirst() throws {
    let (store, _) = try makeStore()
    _ = try store.create(body: "old but important", at: day)
    let newer = try store.create(body: "new", at: day.addingTimeInterval(600))
    let pinned = try XCTUnwrap(store.recent().last)
    try store.setPinned(id: try XCTUnwrap(pinned.id), true)

    XCTAssertEqual(try store.recent().first?.body, "old but important")
    XCTAssertEqual(try store.recent().last?.body, newer.body)
  }

  func testTagsAreLowercasedAndDeduplicated() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "tagged", tags: ["Ideas", "ideas", " IDEAS "], at: day)
    XCTAssertEqual(note.tags, ["ideas"])
    XCTAssertEqual(try store.note(id: try XCTUnwrap(note.id))?.tags, ["ideas"])
  }

  func testNotesAreFoundByTagWithoutMatchingPartOfAnotherTag() throws {
    let (store, _) = try makeStore()
    _ = try store.create(body: "good one", tags: ["ideas"], at: day)
    _ = try store.create(body: "bad one", tags: ["bad-ideas"], at: day.addingTimeInterval(1))
    XCTAssertEqual(try store.notes(tagged: "ideas").map(\.body), ["good one"])
    XCTAssertEqual(try store.notes(tagged: "bad-ideas").map(\.body), ["bad one"])
  }

  func testATagCanBeAddedToAnExistingNote() throws {
    let (store, _) = try makeStore()
    let note = try store.create(body: "untagged", at: day)
    let id = try XCTUnwrap(note.id)
    XCTAssertEqual(try store.addTag(id: id, "Later"), ["later"])
    XCTAssertEqual(try store.notes(tagged: "later").count, 1)
  }

  // MARK: - Export

  func testANoteExportsAsMarkdownWithItsMetadata() throws {
    let (store, _) = try makeStore()
    let note = try store.create(
      title: "Ideas", body: "- ship it\n- then rest", tags: ["work"], pinned: true, at: day)
    let markdown = try store.exportMarkdown(id: try XCTUnwrap(note.id))

    XCTAssertTrue(markdown.hasPrefix("---\ntitle: Ideas"))
    XCTAssertTrue(markdown.contains("tags: work"))
    XCTAssertTrue(markdown.contains("pinned: true"))
    XCTAssertTrue(markdown.contains("# Ideas"))
    XCTAssertTrue(markdown.contains("- ship it\n- then rest"))
  }

  func testExportingEverythingProducesOneReadableDocument() throws {
    let (store, _) = try makeStore()
    _ = try store.create(title: "One", body: "first", at: day)
    _ = try store.create(title: "Two", body: "second", at: day.addingTimeInterval(60))
    let markdown = try store.exportMarkdown()
    XCTAssertTrue(markdown.contains("# One"))
    XCTAssertTrue(markdown.contains("# Two"))
    XCTAssertTrue(markdown.contains("\n---\n"), "notes should be separated by a rule")
  }

  // MARK: - Adversarial input

  /// A note built from hundreds of spoken appends, searched with a query full of
  /// punctuation. Nothing here is quadratic, and the test says so out loud.
  func testALongScratchpadStillAppendsAndSearchesQuickly() throws {
    let (store, _) = try makeStore()
    let started = Date()
    for index in 0..<300 {
      _ = try store.appendToScratchpad(
        "thought number \(index) with markers , , , and more", at: day)
    }
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.search("markers").count, 1)
    XCTAssertLessThan(Date().timeIntervalSince(started), 20)
  }
}
