import XCTest

@testable import RantCore

/// Every function under test here is pure and takes its symbols as an argument. That
/// is the design: the developer pass improves dictation in an editor without Rant ever
/// opening a file, and these tests are where that stays true.
final class DeveloperContextTests: XCTestCase {

  private let developer = DeveloperContext()

  private let sample = """
    func loadUserProfile(userId: String) async throws -> UserProfile {
      let max_retries = MAX_RETRY_COUNT
      return try await client.fetch(userId, retries: max_retries)
    }
    // see also ContentView.swift and the notes in README.md
    """

  // MARK: - Harvesting

  func testIdentifiersAreHarvestedFromTheVisibleText() {
    let found = DeveloperContext.identifiers(in: sample)
    for expected in [
      "loadUserProfile", "userId", "UserProfile", "max_retries", "MAX_RETRY_COUNT",
      "ContentView.swift", "README.md",
    ] {
      XCTAssertTrue(found.contains(expected), "\(expected) was not harvested")
    }
  }

  func testOrdinaryWordsAreNotMistakenForIdentifiers() {
    let found = DeveloperContext.identifiers(in: sample)
    for word in ["func", "return", "try", "await", "the", "and", "see", "also", "notes"] {
      XCTAssertFalse(found.contains(word), "\(word) should not be treated as an identifier")
    }
  }

  func testACapitalisedWordOnItsOwnIsNotAnIdentifier() {
    XCTAssertFalse(DeveloperContext.looksLikeIdentifier("Thursday"))
    XCTAssertFalse(DeveloperContext.looksLikeIdentifier("Marcus"))
    XCTAssertTrue(DeveloperContext.looksLikeIdentifier("ContentView"))
    XCTAssertTrue(DeveloperContext.looksLikeIdentifier("user_id"))
    XCTAssertTrue(DeveloperContext.looksLikeIdentifier("main.swift"))
    XCTAssertFalse(DeveloperContext.looksLikeIdentifier("four.thirty"))
  }

  func testHarvestingDeduplicatesAndKeepsReadingOrder() {
    let found = DeveloperContext.identifiers(in: "userId then userId then maxCount")
    XCTAssertEqual(found, ["userId", "maxCount"])
  }

  func testHarvestingIsCappedSoAHugeWindowCannotFillMemory() {
    let text = (0..<5_000).map { "someName\($0)Value" }.joined(separator: " ")
    XCTAssertEqual(DeveloperContext.identifiers(in: text, limit: 100).count, 100)
  }

  // MARK: - Casing repair

  func testDictatedIdentifiersAreRepairedToTheCasingTheCodeUses() {
    XCTAssertEqual(
      developer.repairIdentifiers(in: "set the user id to five", symbols: ["userId"]),
      "set the userId to five")
    XCTAssertEqual(
      developer.repairIdentifiers(in: "call content view now", symbols: ["ContentView"]),
      "call ContentView now")
    XCTAssertEqual(
      developer.repairIdentifiers(in: "read max retries first", symbols: ["MAX_RETRIES"]),
      "read MAX_RETRIES first")
    XCTAssertEqual(
      developer.repairIdentifiers(in: "the max retry count is fixed", symbols: ["max_retry_count"]),
      "the max_retry_count is fixed")
  }

  func testTheLongestMatchingPhraseWinsOverItsFirstWord() {
    let symbols = ["maxRetry", "maxRetryCount"]
    XCTAssertEqual(
      developer.repairIdentifiers(in: "set max retry count now", symbols: symbols),
      "set maxRetryCount now")
  }

  func testPunctuationSurvivesACasingRepair() {
    XCTAssertEqual(
      developer.repairIdentifiers(in: "check the user id, then stop.", symbols: ["userId"]),
      "check the userId, then stop.")
  }

  /// The dangerous direction: a symbol table that contains an ordinary word would
  /// rewrite prose. Only identifier-shaped symbols are allowed to match, so this is
  /// left alone.
  func testProseIsNeverRewrittenByASymbolThatIsJustAWord() {
    XCTAssertEqual(
      developer.repairIdentifiers(in: "the text is fine as it is", symbols: ["text", "Fine"]),
      "the text is fine as it is")
  }

  func testWithNoSymbolsNothingIsTouched() {
    let line = "set the user id to five"
    XCTAssertEqual(developer.repairIdentifiers(in: line, symbols: []), line)
  }

  func testLineStructureIsPreservedByTheRepair() {
    let text = "first the user id\nthen the max retries"
    XCTAssertEqual(
      developer.repairIdentifiers(in: text, symbols: ["userId", "MAX_RETRIES"]),
      "first the userId\nthen the MAX_RETRIES")
  }

  // MARK: - Spoken file references

  func testASpokenFileNameBecomesAnAtReferenceInAnAIChat() {
    XCTAssertEqual(
      developer.expandFileReferences(in: "look at main dot swift please", isAIAssistant: true),
      "look @main.swift please")
  }

  func testAFileReferenceIsLeftAloneOutsideAnAIChat() {
    let line = "look at main dot swift please"
    XCTAssertEqual(developer.expandFileReferences(in: line, isAIAssistant: false), line)
  }

  func testAPathWithSpokenSlashesIsAssembled() {
    XCTAssertEqual(
      developer.expandFileReferences(in: "check at sources slash main dot swift", isAIAssistant: true),
      "check @sources/main.swift")
  }

  func testAMultiWordFileNameIsOnlyAssembledWhenTheNameIsOnScreen() {
    XCTAssertEqual(
      developer.expandFileReferences(
        in: "open at content view dot swift", isAIAssistant: true, symbols: ["ContentView"]),
      "open @ContentView.swift")
    // Without a symbol saying what the name is, Rant does not invent one.
    let line = "open at content view dot swift"
    XCTAssertEqual(developer.expandFileReferences(in: line, isAIAssistant: true), line)
  }

  func testAFileNameThatWasAlreadyWrittenOutIsStillReferenced() {
    XCTAssertEqual(
      developer.expandFileReferences(in: "see at main.swift", isAIAssistant: true),
      "see @main.swift")
  }

  /// The reason the extension list is closed. "Four dot thirty" is a time, and an
  /// expansion here would be a wrong answer in the middle of an ordinary sentence.
  func testSomethingThatIsNotAFileNameIsLeftAlone() {
    for line in [
      "meet me at four dot thirty", "the release is at version two dot one",
      "look at the dot on the screen", "at",
    ] {
      XCTAssertEqual(developer.expandFileReferences(in: line, isAIAssistant: true), line)
    }
  }

  // MARK: - Never the disk

  /// Rant improves developer dictation from what is already on screen. It does not
  /// index a repository, and a reference to a file that does not exist expands exactly
  /// like one that does — because nothing here ever asks.
  func testNothingIsReadFromDiskToResolveASymbolOrAFile() {
    let imaginary = developer.expandFileReferences(
      in: "look at definitely_not_a_real_file dot swift", isAIAssistant: true)
    XCTAssertEqual(imaginary, "look @definitely_not_a_real_file.swift")

    // A symbol that exists in this very repository is not harvested unless the caller
    // passed the text containing it.
    XCTAssertFalse(DeveloperContext.identifiers(in: "hello there").contains("TranscriptCleaner"))
    XCTAssertEqual(developer.repairIdentifiers(in: "transcript cleaner", symbols: []),
                   "transcript cleaner")
  }

  // MARK: - Where the pass applies

  func testTheDeveloperPassOnlyRunsInEditorsAndAssistants() {
    let context = TranscriptionContext(developerSymbols: ["userId"])
    let editor = SurfaceClassifier.Surface(category: .developer, isDeveloperContext: true)
    let email = SurfaceClassifier.Surface(category: .email)

    XCTAssertEqual(
      developer.apply(to: "the user id", context: context, surface: editor), "the userId")
    XCTAssertEqual(
      developer.apply(to: "the user id", context: context, surface: email), "the user id")
  }

  func testFileReferencesExpandInAnAssistantButNotInAnEditor() {
    let context = TranscriptionContext(developerSymbols: [])
    let assistant = SurfaceClassifier.Surface(category: .aiPrompt, isAIAssistant: true)
    let editor = SurfaceClassifier.Surface(category: .developer, isDeveloperContext: true)

    XCTAssertEqual(
      developer.apply(to: "look at main dot swift", context: context, surface: assistant),
      "look @main.swift")
    XCTAssertEqual(
      developer.apply(to: "look at main dot swift", context: context, surface: editor),
      "look at main dot swift")
  }

  func testTheDeveloperPassNeverRunsInASecureField() {
    let secure = TranscriptionContext(isSecureField: true, developerSymbols: ["userId"])
    let editor = SurfaceClassifier.Surface(category: .developer, isDeveloperContext: true)
    XCTAssertEqual(
      developer.apply(to: "the user id", context: secure, surface: editor), "the user id")
  }

  func testTheEditorsFromTheSurfaceTableAreAllDeveloperContexts() {
    let classifier = SurfaceClassifier()
    for bundle in [
      "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
      "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
    ] {
      let surface = classifier.classify(TranscriptionContext(appBundleID: bundle))
      XCTAssertTrue(surface.isDeveloperContext, "\(bundle) should be a developer context")
    }
  }

  // MARK: - Adversarial input

  /// Repeated markers in a very long line are what hung the cleaner's regular
  /// expression. Both passes are single scans over the words, so a pathological input
  /// costs time proportional to its length and nothing worse.
  func testAVeryLongLineFullOfMarkersIsProcessedQuickly() {
    let text = Array(repeating: "at dot slash user id max retries", count: 20_000)
      .joined(separator: " ")
    let started = Date()
    let repaired = developer.repairIdentifiers(in: text, symbols: ["userId", "MAX_RETRIES"])
    let expanded = developer.expandFileReferences(in: repaired, isAIAssistant: true)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertTrue(expanded.contains("userId"))
    XCTAssertFalse(expanded.contains("@"), "none of this names a file")
  }

  func testHarvestingAHugeWindowIsQuick() {
    let text = Array(repeating: "someValue other_value THING.swift plain words here", count: 20_000)
      .joined(separator: " ")
    let started = Date()
    XCTAssertEqual(DeveloperContext.identifiers(in: text).count, 3)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }
}
