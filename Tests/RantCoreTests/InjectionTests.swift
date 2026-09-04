import XCTest
@testable import RantCore

/// Insertion is where dictation either feels native or feels like a hack. These
/// tests pin the spacing rules, the refusals, and the clipboard contract.
final class InjectionTests: XCTestCase {
  private let spacing = InsertionSpacing()

  private func plan(_ text: String, before: String? = nil, after: String? = nil) -> String {
    spacing.plan(text: text, before: before, after: after).text
  }

  // MARK: - Spacing

  func testInsertingIntoAnEmptyFieldAddsNoSpaces() {
    XCTAssertEqual(plan("Hello there.", before: "", after: ""), "Hello there.")
  }

  /// The common case: no Accessibility text available. Guessing a leading space here
  /// would put a stray space at the start of every empty field.
  func testUnknownSurroundingsInsertTheTextUnchanged() {
    XCTAssertEqual(plan("Hello there."), "Hello there.")
  }

  func testASpaceIsAddedAfterAWord() {
    XCTAssertEqual(plan("world", before: "hello"), " world")
  }

  func testNoSecondSpaceWhenOneIsAlreadyThere() {
    XCTAssertEqual(plan("world", before: "hello "), "world")
  }

  func testNoSpaceAfterAnOpeningBracketOrQuote() {
    XCTAssertEqual(plan("aside", before: "the point ("), "aside")
    XCTAssertEqual(plan("quoted", before: "he said \u{201C}"), "quoted")
  }

  /// Dictating the second half of a hyphenated or namespaced token should not split it.
  func testNoSpaceAfterAJoiningCharacter() {
    XCTAssertEqual(plan("known", before: "well-"), "known")
    XCTAssertEqual(plan("handle", before: "@"), "handle")
    XCTAssertEqual(plan("swift", before: "src/"), "swift")
  }

  /// A full stop gets a space, even though that costs us "main." + "swift". Sentence
  /// spacing is the far more common case and getting it wrong is far more visible.
  func testAFullStopIsTreatedAsASentenceEndNotAFileExtension() {
    XCTAssertEqual(plan("swift", before: "main."), " swift")
  }

  func testASpaceIsAddedBeforeFollowingText() {
    XCTAssertEqual(plan("middle", before: "start ", after: "end"), "middle ")
  }

  func testNoSpaceBeforeTrailingPunctuation() {
    XCTAssertEqual(plan("the end", before: "this is ", after: "."), "the end")
  }

  // MARK: - Casing at the join

  func testContinuingASentenceLowercasesTheFirstWord() {
    XCTAssertEqual(plan("Hello there", before: "I said"), " hello there")
  }

  func testStartingAfterAFullStopKeepsTheCapital() {
    XCTAssertEqual(plan("Hello there", before: "That was fine."), " Hello there")
  }

  func testStartingOnANewLineKeepsTheCapital() {
    XCTAssertEqual(plan("Hello there", before: "previous line\n"), "Hello there")
  }

  func testAcronymsAndIdentifiersAreNotLowercasedAtAJoin() {
    XCTAssertEqual(plan("API keys are secret", before: "about the"), " API keys are secret")
    XCTAssertEqual(plan("userId is nil", before: "check that"), " userId is nil")
    XCTAssertEqual(plan("iPhone settings", before: "open the"), " iPhone settings")
  }

  func testContinuingAfterACommaAlsoLowercases() {
    XCTAssertEqual(plan("And then we shipped", before: "we tried,"), " and then we shipped")
  }

  // MARK: - Refusals

  func testPasswordFieldsAreRefusedOutright() {
    let policy = InjectionPolicy()
    XCTAssertEqual(policy.mustRefuse(TranscriptionContext(isSecureField: true)), .secureField)
    XCTAssertEqual(
      policy.mustRefuse(TranscriptionContext(fieldRole: "AXSecureTextField")), .secureField)
    XCTAssertEqual(
      policy.mustRefuse(TranscriptionContext(fieldRole: "AXSecureTextArea")), .secureField)
  }

  func testOrdinaryFieldsAreNotRefused() {
    let policy = InjectionPolicy()
    XCTAssertNil(policy.mustRefuse(TranscriptionContext(fieldRole: "AXTextArea")))
    XCTAssertNil(policy.mustRefuse(nil))
  }

  func testInjectorThrowsOnASecureFieldRatherThanTypingIntoIt() async {
    let board = FakePasteboard("original clipboard")
    let injector = AccessibilityInjector(pasteboard: board, sleeper: { _ in })
    await XCTAssertThrowsErrorAsync(
      try await injector.inject(
        InjectionRequest(text: "hunter2", context: TranscriptionContext(isSecureField: true)))
    ) { XCTAssertEqual($0 as? InjectionError, .secureField) }
    XCTAssertEqual(board.read(), "original clipboard",
                   "a refused injection must not touch the clipboard either")
  }

  func testEmptyTextIsRefusedRatherThanPastingNothing() async throws {
    let injector = AccessibilityInjector(pasteboard: FakePasteboard(), sleeper: { _ in })
    let outcome = try await injector.inject(InjectionRequest(text: "   \n  "))
    XCTAssertEqual(outcome, .refused(reason: "nothing to insert"))
  }

  // MARK: - Clipboard contract

  func testClipboardTargetWritesTheTextAndSaysSo() async throws {
    let board = FakePasteboard("previous")
    let injector = AccessibilityInjector(pasteboard: board, sleeper: { _ in })
    let outcome = try await injector.inject(
      InjectionRequest(text: "the transcript", target: .clipboard))
    XCTAssertEqual(outcome, .leftOnClipboard(reason: "you asked for the clipboard"))
    XCTAssertEqual(board.read(), "the transcript")
  }

  /// Without Accessibility we can neither read the focused element nor post a
  /// keystroke — so the text must still reach the user rather than vanishing.
  func testWithoutAccessibilityPermissionTheTextIsLeftOnTheClipboard() async throws {
    try XCTSkipIf(AXIsProcessTrusted(), "this machine has granted Accessibility to the test runner")
    let board = FakePasteboard("previous")
    let injector = AccessibilityInjector(pasteboard: board, sleeper: { _ in })
    let outcome = try await injector.inject(InjectionRequest(text: "do not lose me"))
    guard case .leftOnClipboard = outcome else {
      return XCTFail("expected the text to be preserved, got \(outcome)")
    }
    XCTAssertEqual(board.read(), "do not lose me")
  }

  func testPasteboardChangeCountTracksWrites() {
    let board = FakePasteboard()
    let before = board.changeCount
    board.write("a")
    XCTAssertGreaterThan(board.changeCount, before)
  }

  // MARK: - Robustness

  func testPlanNeverProducesLeadingOrTrailingDoubleSpaces() {
    let befores: [String?] = [nil, "", " ", "word", "word ", "(", ".", "\n", "well-"]
    let afters: [String?] = [nil, "", " ", "word", ".", ")"]
    for before in befores {
      for after in afters {
        let output = spacing.plan(text: "inserted text", before: before, after: after).text
        XCTAssertFalse(output.contains("  "), "double space from before=\(before ?? "nil") after=\(after ?? "nil")")
      }
    }
  }
}
