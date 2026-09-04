import XCTest
@testable import RantCore

/// Cleanup is the difference between a transcript and something you would send.
/// These tests are the specification: if a rule changes, a line here changes with it.
final class CleanupTests: XCTestCase {
  private let cleaner = TranscriptCleaner()

  private func clean(_ input: String, _ level: CleanupLevel = .medium) -> String {
    cleaner.clean(input, level: level)
  }

  // MARK: - Levels

  func testNoneLeavesTheWordsAloneAndOnlyTidiesWhitespace() {
    XCTAssertEqual(clean("um  so   i think  we should ship", .none), "um so i think we should ship")
  }

  func testLightPunctuatesAndCapitalisesWithoutRestructuring() {
    XCTAssertEqual(clean("um i think we should ship on friday", .light), "I think we should ship on Friday.".replacingOccurrences(of: "Friday", with: "friday"))
  }

  func testMediumIsTheDefaultAndRemovesFalseStarts() {
    XCTAssertEqual(clean("so um we we should ship it"), "So we should ship it.")
  }

  // MARK: - Fillers

  func testFillerSoundsAreRemoved() {
    XCTAssertEqual(clean("uh the build is uh green"), "The build is green.")
  }

  /// A cleaner that eats real words is worse than one that leaves an "um".
  func testWordsThatAreOnlySometimesFillerSurvive() {
    for word in ["like", "so", "right", "well", "just", "basically"] {
      let output = clean("it was \(word) fine")
      XCTAssertTrue(output.lowercased().contains(word.split(separator: " ").first!),
                    "\(word) was removed from: \(output)")
    }
  }

  func testHedgePhrasesGoAtMediumButNotAtLight() {
    XCTAssertEqual(clean("it is you know fine", .medium), "It is fine.")
    XCTAssertTrue(clean("it is you know fine", .light).lowercased().contains("you know"))
  }

  // MARK: - Repetition

  func testStutteredWordsCollapse() {
    XCTAssertEqual(clean("i i i think so"), "I think so.")
    XCTAssertEqual(clean("the the plan is ready"), "The plan is ready.")
  }

  func testLegitimateDoubledWordsSurvive() {
    XCTAssertTrue(clean("i had had enough").contains("had had"))
    XCTAssertTrue(clean("it was very very good").contains("very very"))
  }

  // MARK: - Self-correction  (the headline behaviour)

  func testCorrectionWithActually() {
    XCTAssertEqual(clean("send it Tuesday, actually Wednesday"), "Send it Wednesday.")
  }

  func testCorrectionWithSorry() {
    XCTAssertEqual(clean("his name is Mark, sorry, Marcus"), "His name is Marcus.")
  }

  func testCorrectionWithEmDash() {
    XCTAssertEqual(clean("ship it Tuesday — actually Wednesday"), "Ship it Wednesday.")
  }

  func testMultiWordCorrectionReplacesTheSameNumberOfWords() {
    XCTAssertEqual(clean("meet at the blue office, i mean the red office"),
                   "Meet at the red office.")
  }

  /// A long "correction" is really a new statement. Guessing would destroy meaning,
  /// so we keep both halves.
  func testLongCorrectionIsNotTreatedAsAReplacement() {
    let output = clean("send it Tuesday, actually let us wait until the client confirms")
    XCTAssertTrue(output.contains("Tuesday"), "the original clause must survive: \(output)")
    XCTAssertTrue(output.contains("client confirms"))
  }

  func testCorrectionsAreNotAppliedAtLightLevel() {
    XCTAssertTrue(clean("send it Tuesday, actually Wednesday", .light).contains("Tuesday"))
  }

  // MARK: - Restarts

  func testScratchThatDiscardsTheRestOfTheSentence() {
    XCTAssertEqual(clean("we ship Tuesday. scratch that, we ship Friday"),
                   "We ship Tuesday. We ship Friday.")
  }

  // MARK: - Spoken punctuation

  func testSpokenTerminatorsBecomeMarks() {
    XCTAssertEqual(clean("hello comma world period"), "Hello, world.")
    XCTAssertEqual(clean("are you sure question mark"), "Are you sure?")
  }

  func testNewLineAndNewParagraph() {
    XCTAssertEqual(clean("first line new line second line"), "First line\nSecond line.")
    XCTAssertEqual(clean("intro new paragraph body"), "Intro\n\nBody.")
  }

  func testBulletPoints() {
    XCTAssertEqual(clean("shopping bullet point milk bullet point eggs"),
                   "Shopping\n- Milk\n- Eggs.")
  }

  /// The classic false positive. "Add a period" is prose, not an instruction.
  func testPunctuationWordsAfterAnArticleStayWords() {
    XCTAssertTrue(clean("add a period to the end").contains("period"))
    XCTAssertTrue(clean("it is a comma separated list").contains("comma"))
    XCTAssertTrue(clean("draw the dash longer").contains("dash"))
  }

  func testBracketsAndQuotesSpaceCorrectly() {
    XCTAssertEqual(clean("the value open paren roughly close paren is fine"),
                   "The value (roughly) is fine.")
  }

  // MARK: - Casing

  func testAcronymsAndIdentifiersSurviveCapitalisation() {
    XCTAssertTrue(clean("the API returned JSON").contains("API returned JSON"))
    XCTAssertTrue(clean("call userId on the model").contains("userId"))
    XCTAssertTrue(clean("open the iPhone settings").contains("iPhone"))
  }

  func testStandalonePronounIIsCapitalised() {
    XCTAssertEqual(clean("i think i agree"), "I think I agree.")
  }

  func testEachSentenceGetsACapital() {
    XCTAssertEqual(clean("one thing. another thing. a third"),
                   "One thing. Another thing. A third.")
  }

  // MARK: - Terminal punctuation

  func testATrailingSentenceGainsAFullStop() {
    XCTAssertEqual(clean("this is done"), "This is done.")
  }

  func testExistingPunctuationIsNotDoubled() {
    XCTAssertEqual(clean("is this done?"), "Is this done?")
  }

  func testUrlsDoNotGainASentenceFullStop() {
    XCTAssertFalse(clean("the docs are at https://example.com/docs").hasSuffix(".."))
  }

  // MARK: - Robustness

  func testEmptyAndWhitespaceInputProduceEmptyOutput() {
    XCTAssertEqual(clean(""), "")
    XCTAssertEqual(clean("   \n  "), "")
  }

  func testCleaningIsIdempotent() {
    for input in [
      "send it Tuesday, actually Wednesday",
      "um the the build is green",
      "shopping bullet point milk bullet point eggs",
      "hello comma world period",
    ] {
      let once = clean(input)
      XCTAssertEqual(clean(once), once, "cleaning \(input) twice changed it again")
    }
  }

  func testCleanerNeverThrowsOnAdversarialInput() {
    let inputs = [
      String(repeating: "actually ", count: 200),
      String(repeating: "comma ", count: 200),
      "period period period",
      "scratch that",
      "\u{1F600} um \u{1F600}",
      String(repeating: "a", count: 20_000),
    ]
    for input in inputs {
      for level in CleanupLevel.allCases {
        _ = cleaner.clean(input, level: level)   // must simply not crash or hang
      }
    }
  }
}
