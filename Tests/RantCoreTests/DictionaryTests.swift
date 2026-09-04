import XCTest
@testable import RantCore

/// The personal dictionary is what makes Rant get *your* words right. These tests
/// cover the storage rules and, more importantly, the matching rules — a dictionary
/// that corrupts the middle of an unrelated word is worse than no dictionary.
final class DictionaryTests: XCTestCase {

  private func store() throws -> VocabularyStore {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return VocabularyStore(database: database)
  }

  // MARK: - Storage

  func testAddingAndListing() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "super base", written: "Supabase"))
    _ = try store.add(DictionaryEntry(spoken: "ver sell", written: "Vercel"))
    XCTAssertEqual(try store.entries().map(\.written), ["Supabase", "Vercel"])
  }

  func testDuplicateSpokenFormsAreRejectedWithAUsefulMessage() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "super base", written: "Supabase"))
    XCTAssertThrowsError(try store.add(DictionaryEntry(spoken: "super base", written: "Other"))) {
      XCTAssertEqual($0 as? VocabularyError, .duplicateSpokenForm("super base"))
      XCTAssertTrue(($0 as? VocabularyError)?.errorDescription?.contains("super base") ?? false)
    }
  }

  /// The same spoken form can be both a replacement and a key term — they do
  /// different jobs.
  func testTheSameWordCanBeBothAReplacementAndAKeyTerm() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "supabase", written: "Supabase", kind: .replacement))
    XCTAssertNoThrow(
      try store.add(DictionaryEntry(spoken: "supabase", written: "Supabase", kind: .boost)))
  }

  func testBlankFieldsAreRejected() throws {
    let store = try store()
    XCTAssertThrowsError(try store.add(DictionaryEntry(spoken: "   ", written: "x")))
    XCTAssertThrowsError(try store.add(DictionaryEntry(spoken: "x", written: "   ")))
  }

  func testWhitespaceIsTrimmedOnTheWayIn() throws {
    let store = try store()
    let entry = try store.add(DictionaryEntry(spoken: "  super base  ", written: " Supabase "))
    XCTAssertEqual(entry.spoken, "super base")
    XCTAssertEqual(entry.written, "Supabase")
  }

  func testAddOrIgnoreIsIdempotentSoImportsCanBeReRun() throws {
    let store = try store()
    XCTAssertTrue(try store.addOrIgnore(DictionaryEntry(spoken: "a", written: "A")))
    XCTAssertFalse(try store.addOrIgnore(DictionaryEntry(spoken: "a", written: "A")))
    XCTAssertEqual(try store.entries().count, 1)
  }

  func testUpdatingAndDeleting() throws {
    let store = try store()
    var entry = try store.add(DictionaryEntry(spoken: "cloud flare", written: "Cloudflare"))
    entry.written = "Cloudflare Workers"
    try store.update(entry)
    XCTAssertEqual(try store.entries().first?.written, "Cloudflare Workers")

    try store.deleteEntry(id: entry.id!)
    XCTAssertTrue(try store.entries().isEmpty)
  }

  func testSearchMatchesEitherSide() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "super base", written: "Supabase"))
    XCTAssertEqual(try store.searchEntries("base").count, 1)
    XCTAssertEqual(try store.searchEntries("Supa").count, 1)
    XCTAssertEqual(try store.searchEntries("nothing").count, 0)
  }

  // MARK: - Feeding the pipeline

  func testDisabledEntriesDoNotReachThePipeline() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "a", written: "A", enabled: true))
    _ = try store.add(DictionaryEntry(spoken: "b", written: "B", enabled: false))
    XCTAssertEqual(try store.makeApplier().replacements.count, 1)
  }

  /// A key term steers recognition; it must not silently rewrite the transcript.
  func testKeyTermsAreNotAppliedAsReplacements() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "Kubernetes", kind: .boost))
    XCTAssertTrue(try store.makeApplier().replacements.isEmpty)
    XCTAssertEqual(try store.keyTerms(), ["Kubernetes"])
  }

  /// The recogniser should be biased toward the spelling we actually want, which is
  /// the written form, not the phonetic one.
  func testKeyTermsUseTheWrittenFormNotTheSpokenOne() throws {
    let store = try store()
    _ = try store.add(DictionaryEntry(spoken: "super base", written: "Supabase"))
    XCTAssertEqual(try store.keyTerms(), ["Supabase"])
  }

  // MARK: - Matching rules

  func testReplacementsAreAppliedToFinishedText() {
    let applier = VocabularyApplier(replacements: [("super base", "Supabase", false)])
    XCTAssertEqual(applier.apply(to: "we use super base for auth"), "we use Supabase for auth")
  }

  func testReplacementIsCaseInsensitiveByDefault() {
    let applier = VocabularyApplier(replacements: [("super base", "Supabase", false)])
    XCTAssertEqual(applier.apply(to: "Super Base is fine"), "Supabase is fine")
  }

  func testCaseSensitiveEntriesOnlyMatchExactly() {
    let applier = VocabularyApplier(replacements: [("API", "API", true), ("api", "the API", true)])
    XCTAssertEqual(applier.apply(to: "call the api"), "call the the API")
  }

  /// The rule that keeps a dictionary from doing damage.
  func testReplacementsNeverMatchInsideALongerWord() {
    let applier = VocabularyApplier(replacements: [("sell", "Vercel", false)])
    XCTAssertEqual(applier.apply(to: "we sell reseller sellers"), "we Vercel reseller sellers")
  }

  func testLongerPhrasesWinOverShorterOnes() {
    let applier = VocabularyApplier(replacements: [
      ("cloud flare", "Cloudflare", false),
      ("cloud flare workers", "Cloudflare Workers", false),
    ])
    XCTAssertEqual(applier.apply(to: "deploy to cloud flare workers"), "deploy to Cloudflare Workers")
  }

  /// A replacement containing regex metacharacters must be treated as literal text.
  func testSpecialCharactersInEntriesAreTakenLiterally() {
    let applier = VocabularyApplier(replacements: [
      ("c plus plus", "C++", false),
      ("dot star", ".*", false),
    ])
    XCTAssertEqual(applier.apply(to: "I write c plus plus"), "I write C++")
    XCTAssertEqual(applier.apply(to: "use dot star here"), "use .* here")
  }

  func testAReplacementWhoseOutputContainsADollarSignSurvives() {
    let applier = VocabularyApplier(replacements: [("dollar var", "$VAR", false)])
    XCTAssertEqual(applier.apply(to: "set dollar var now"), "set $VAR now")
  }

  func testEmptyDictionaryLeavesTextAlone() {
    XCTAssertEqual(VocabularyApplier().apply(to: "unchanged text"), "unchanged text")
  }

  // MARK: - Snippets

  func testSnippetsExpandOnTheirTriggerPhrase() {
    let applier = VocabularyApplier(snippets: [("my meeting link", "https://cal.com/rant")])
    XCTAssertEqual(
      applier.apply(to: "send them my meeting link please"),
      "send them https://cal.com/rant please")
  }

  func testDuplicateSnippetTriggersAreRejected() throws {
    let store = try store()
    _ = try store.add(Snippet(trigger: "my address", expansion: "1 Main Street"))
    XCTAssertThrowsError(try store.add(Snippet(trigger: "my address", expansion: "other"))) {
      XCTAssertEqual($0 as? VocabularyError, .duplicateTrigger("my address"))
    }
  }

  func testDisabledSnippetsDoNotExpand() throws {
    let store = try store()
    _ = try store.add(Snippet(trigger: "x", expansion: "y", enabled: false))
    XCTAssertTrue(try store.makeApplier().snippets.isEmpty)
  }

  /// An expansion may contain something the dictionary should then correct, so
  /// snippets run first.
  func testSnippetsExpandBeforeDictionaryReplacementsApply() {
    let applier = VocabularyApplier(
      replacements: [("super base", "Supabase", false)],
      snippets: [("my stack", "super base and Next")])
    XCTAssertEqual(applier.apply(to: "we run my stack"), "we run Supabase and Next")
  }

  func testSnippetStorageRoundTrip() throws {
    let store = try store()
    var snippet = try store.add(Snippet(trigger: "sig", expansion: "Best,\nDaniel"))
    XCTAssertEqual(try store.snippets().count, 1)
    snippet.expansion = "Thanks,\nDaniel"
    try store.update(snippet)
    XCTAssertEqual(try store.snippets().first?.expansion, "Thanks,\nDaniel")
    try store.deleteSnippet(id: snippet.id!)
    XCTAssertTrue(try store.snippets().isEmpty)
  }
}
