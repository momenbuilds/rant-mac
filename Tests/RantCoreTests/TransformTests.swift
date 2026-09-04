import XCTest

@testable import RantCore

/// Transforms rewrite text the user already wrote, which makes them the most
/// destructive thing Rant does. These tests pin the two properties that keep that
/// safe — nothing is written without a preview, and everything written can be undone —
/// alongside the diff the preview is built from.
final class TransformTests: XCTestCase {

  private func makeEngine(
    _ transform: @escaping @Sendable (String) -> String = { $0.uppercased() },
    catalogue: TransformCatalogue = TransformCatalogue()
  ) -> (TransformEngine, StubEnhancer, RecordingInjector) {
    let enhancer = StubEnhancer(transform)
    let injector = RecordingInjector()
    return (
      TransformEngine(enhancer: enhancer, injector: injector, catalogue: catalogue),
      enhancer, injector
    )
  }

  private func selectionContext(_ selection: String) -> TranscriptionContext {
    TranscriptionContext(selectedText: selection)
  }

  // MARK: - The catalogue

  func testEveryBuiltInTransformIsPresentAndHasAUniqueIdentifier() {
    let ids = Transform.builtIns.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "two built-in transforms share an id")
    for kind in Transform.BuiltIn.allCases {
      XCTAssertTrue(ids.contains(kind.rawValue), "\(kind.rawValue) is missing from the catalogue")
    }
  }

  func testTranslateRefusesToRunUntilALanguageIsChosen() {
    let translate = Transform.builtIn(.translate)
    XCTAssertTrue(translate.needsTargetLanguage)
    XCTAssertNil(translate.resolvedInstruction())
    XCTAssertNil(translate.resolvedInstruction(targetLanguage: "   "))
    XCTAssertEqual(
      translate.resolvedInstruction(targetLanguage: "French"),
      translate.instruction + " Translate into French.")
  }

  func testACustomPromptTransformRefusesToRunWithoutAnInstruction() {
    let custom = Transform.builtIn(.customPrompt)
    XCTAssertNil(custom.resolvedInstruction())
    XCTAssertEqual(
      custom.resolvedInstruction(customInstruction: "make it rhyme"),
      custom.instruction + " make it rhyme")
  }

  func testAUserTransformWithTheSameIdentifierShadowsTheBuiltIn() {
    let mine = Transform(
      id: Transform.BuiltIn.shorten.rawValue, name: "Shorten hard",
      instruction: "Half the words.", shortcut: "⌥⌘1")
    let catalogue = TransformCatalogue(custom: [mine])
    XCTAssertEqual(catalogue.transform(id: mine.id)?.name, "Shorten hard")
    XCTAssertEqual(
      catalogue.all.count, Transform.builtIns.count, "shadowing must not add a second entry")
    XCTAssertEqual(catalogue.transform(shortcut: "⌥⌘1")?.id, mine.id)
  }

  func testTransformsAreFoundByNameWhateverTheCasing() {
    let catalogue = TransformCatalogue(
      custom: [Transform(id: "pirate", name: "Pirate", instruction: "Arr.")])
    XCTAssertEqual(catalogue.transform(named: "pirate")?.id, "pirate")
    XCTAssertEqual(catalogue.transform(named: "FIX GRAMMAR")?.id, "fixGrammar")
    XCTAssertNil(catalogue.transform(named: "nonsense"))
  }

  // MARK: - Preview

  func testAPreviewProposesAChangeWithoutTouchingTheDocument() async throws {
    let (engine, enhancer, injector) = makeEngine()
    let preview = try await engine.preview(
      Transform.builtIn(.shorten), context: selectionContext("hello there"))

    XCTAssertEqual(preview.proposed, "HELLO THERE")
    XCTAssertEqual(preview.original, "hello there")
    XCTAssertTrue(injector.requests.isEmpty, "a preview must not write anything")
    XCTAssertEqual(enhancer.calls.count, 1)
    XCTAssertEqual(enhancer.calls.first?.instruction, Transform.builtIn(.shorten).instruction)
  }

  func testAPreviewCarriesTheDiffTheUserWillBeShown() async throws {
    let (engine, _, _) = makeEngine({ $0.replacingOccurrences(of: "Tuesday", with: "Thursday") })
    let preview = try await engine.preview(
      Transform.builtIn(.polish), context: selectionContext("we ship on Tuesday next week"))
    XCTAssertFalse(preview.isUnchanged)
    XCTAssertEqual(preview.summary.inserted, 1)
    XCTAssertEqual(preview.summary.deleted, 1)
  }

  func testATransformThatChangesNothingIsReportedAsUnchanged() async throws {
    let (engine, _, _) = makeEngine({ $0 })
    let preview = try await engine.preview(
      Transform.builtIn(.polish), context: selectionContext("already perfect"))
    XCTAssertTrue(preview.isUnchanged)
  }

  func testTransformingWithNothingSelectedIsRefused() async {
    let (engine, _, _) = makeEngine()
    do {
      _ = try await engine.preview(Transform.builtIn(.polish), context: selectionContext("  "))
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .nothingSelected)
    }
  }

  func testTranslateWithoutALanguageFailsBeforeAnythingIsSent() async {
    let (engine, enhancer, _) = makeEngine()
    do {
      _ = try await engine.preview(
        Transform.builtIn(.translate), context: selectionContext("hello"))
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .missingTargetLanguage)
    }
    XCTAssertTrue(enhancer.calls.isEmpty, "an incomplete instruction must not reach the model")
  }

  func testAnUnknownTransformIdentifierIsRefused() async {
    let (engine, _, _) = makeEngine()
    do {
      _ = try await engine.preview(transformID: "nope", context: selectionContext("hello"))
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .unknownTransform("nope"))
    }
  }

  // MARK: - Password fields

  func testTransformsRefuseToReadOrWriteInASecureField() async {
    let (engine, enhancer, injector) = makeEngine()
    let secure = TranscriptionContext(isSecureField: true, selectedText: "hunter2")
    do {
      _ = try await engine.preview(Transform.builtIn(.polish), context: secure)
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .secureField)
    }
    XCTAssertTrue(enhancer.calls.isEmpty, "a password must never reach an enhancer")
    XCTAssertTrue(injector.requests.isEmpty)
  }

  func testASecureAccessibilityRoleIsRefusedEvenWithoutTheSecureFlag() async {
    let (engine, _, _) = makeEngine()
    let secure = TranscriptionContext(fieldRole: "AXSecureTextField", selectedText: "hunter2")
    do {
      _ = try await engine.preview(Transform.builtIn(.polish), context: secure)
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .secureField)
    }
  }

  // MARK: - Applying

  func testApplyingAPreviewReplacesTheSelection() async throws {
    let (engine, _, injector) = makeEngine()
    let context = selectionContext("hello there")
    let preview = try await engine.preview(Transform.builtIn(.shorten), context: context)
    let outcome = try await engine.apply(preview, context: context)

    XCTAssertEqual(outcome, .insertedDirectly)
    XCTAssertEqual(injector.requests.count, 1)
    XCTAssertEqual(injector.requests.first?.text, "HELLO THERE")
    XCTAssertEqual(injector.requests.first?.target, .replaceSelection)
  }

  /// The only route to the injector is a preview this engine made. Anything else —
  /// another subsystem, a parsed command, a model reply — is refused, which is what
  /// keeps "text is only written after the user saw it" true rather than merely
  /// intended.
  func testAPreviewTheEngineDidNotProduceCannotBeApplied() async {
    let (engine, _, injector) = makeEngine()
    let forged = TransformPreview(
      transformID: "polish", original: "hello", proposed: "rm -rf /", diff: [])
    do {
      _ = try await engine.apply(forged)
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .unknownPreview)
    }
    XCTAssertTrue(injector.requests.isEmpty)
  }

  func testAPreviewCannotBeAppliedTwice() async throws {
    let (engine, _, injector) = makeEngine()
    let preview = try await engine.preview(
      Transform.builtIn(.polish), context: selectionContext("hello"))
    _ = try await engine.apply(preview)
    do {
      _ = try await engine.apply(preview)
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .unknownPreview)
    }
    XCTAssertEqual(injector.requests.count, 1)
  }

  // MARK: - Undo

  func testEverythingATransformWritesCanBeUndone() async throws {
    let (engine, _, injector) = makeEngine()
    let context = selectionContext("hello there")
    _ = try await engine.run(Transform.builtIn(.shorten), context: context)
    let depth = await engine.undoDepth
    XCTAssertEqual(depth, 1)

    _ = try await engine.undoLast(context: context)
    XCTAssertEqual(injector.requests.count, 2)
    XCTAssertEqual(injector.requests.last?.text, "hello there")
    XCTAssertEqual(injector.requests.last?.target, .replaceSelection)
    let remaining = await engine.undoDepth
    XCTAssertEqual(remaining, 0)
  }

  func testUndoingWithNothingToUndoIsRefusedRatherThanGuessed() async {
    let (engine, _, _) = makeEngine()
    do {
      _ = try await engine.undoLast()
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? TransformError, .nothingToUndo)
    }
  }

  func testUndoUnwindsSeveralTransformsInOrder() async throws {
    let (engine, _, injector) = makeEngine()
    _ = try await engine.run(Transform.builtIn(.polish), selection: "first")
    _ = try await engine.run(Transform.builtIn(.polish), selection: "second")
    _ = try await engine.undoLast()
    _ = try await engine.undoLast()
    XCTAssertEqual(injector.requests.map(\.text), ["FIRST", "SECOND", "second", "first"])
  }

  // MARK: - The diff

  func testAnUnchangedTextDiffsToASingleEqualRun() {
    let runs = TextDiff.diff(original: "one two three", result: "one two three")
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.operation, .equal)
    XCTAssertTrue(TextDiff.isUnchanged(runs))
  }

  func testAnInsertionIsReportedAsOneInsertRun() {
    let runs = TextDiff.diff(original: "ship it", result: "ship it on Thursday")
    XCTAssertEqual(runs.map(\.operation), [.equal, .insert])
    XCTAssertEqual(runs.last?.words, ["on", "Thursday"])
  }

  func testADeletionIsReportedAsOneDeleteRun() {
    let runs = TextDiff.diff(original: "we should probably ship it", result: "we should ship it")
    XCTAssertEqual(TextDiff.summary(runs).deleted, 1)
    XCTAssertEqual(TextDiff.summary(runs).inserted, 0)
    XCTAssertTrue(runs.contains { $0.operation == .delete && $0.words == ["probably"] })
  }

  func testASubstitutionShowsBothTheOldAndTheNewWords() {
    let runs = TextDiff.diff(original: "we ship on Tuesday", result: "we ship on Thursday")
    XCTAssertEqual(TextDiff.summary(runs).deleted, 1)
    XCTAssertEqual(TextDiff.summary(runs).inserted, 1)
  }

  func testAnEmptyOriginalIsAllInsertionAndAnEmptyResultIsAllDeletion() {
    XCTAssertEqual(
      TextDiff.diff(original: "", result: "new words").map(\.operation), [.insert])
    XCTAssertEqual(
      TextDiff.diff(original: "old words", result: "").map(\.operation), [.delete])
    XCTAssertTrue(TextDiff.diff(original: "", result: "").isEmpty)
  }

  /// The strongest thing that can be said about a diff: keeping the equal and deleted
  /// words rebuilds the original, and keeping the equal and inserted ones rebuilds the
  /// result. A diff that fails this is showing the user a fiction.
  func testADiffAlwaysRebuildsBothSides() {
    let original = "the quick brown fox jumps over the lazy dog while the cat watches"
    let result = "the quick red fox leaps over a lazy dog while the cat sleeps soundly"
    let runs = TextDiff.diff(original: original, result: result)

    let rebuiltOriginal = runs.filter { $0.operation != .insert }.flatMap(\.words)
    let rebuiltResult = runs.filter { $0.operation != .delete }.flatMap(\.words)
    XCTAssertEqual(rebuiltOriginal, TextDiff.words(original))
    XCTAssertEqual(rebuiltResult, TextDiff.words(result))
  }

  func testNeighbouringRunsAreMergedRatherThanEmittedWordByWord() {
    let runs = TextDiff.diff(
      original: "alpha beta gamma delta", result: "alpha epsilon zeta delta")
    XCTAssertEqual(runs.count, 4, "each side of the change should be one run, not four")
    XCTAssertEqual(runs.first?.words, ["alpha"])
    XCTAssertEqual(runs.last?.words, ["delta"])
    XCTAssertTrue(runs.contains { $0.operation == .delete && $0.words == ["beta", "gamma"] })
    XCTAssertTrue(runs.contains { $0.operation == .insert && $0.words == ["epsilon", "zeta"] })
  }

  func testTheDiffOfALargeDocumentWithASmallEditFinishesQuickly() {
    var words = (0..<4_000).map { "word\($0)" }
    let original = words.joined(separator: " ")
    words[2_000] = "changed"
    let result = words.joined(separator: " ")

    let started = Date()
    let runs = TextDiff.diff(original: original, result: result)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 5, "a four-thousand-word diff should not be slow")
    XCTAssertEqual(TextDiff.summary(runs).inserted, 1)
    XCTAssertEqual(TextDiff.summary(runs).deleted, 1)
  }

  /// Two texts with nothing in common — a translation, say — are the worst case for
  /// an edit-script search. The cap must turn that into a coarse answer quickly rather
  /// than a hang, and the answer must still describe the change truthfully.
  func testTwoCompletelyDifferentDocumentsFallBackInsteadOfHanging() {
    let original = (0..<3_000).map { "alpha\($0)" }.joined(separator: " ")
    let result = (0..<3_000).map { "beta\($0)" }.joined(separator: " ")

    let started = Date()
    let runs = TextDiff.diff(original: original, result: result)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 10, "the fallback exists precisely so this cannot hang")
    XCTAssertEqual(runs.map(\.operation), [.delete, .insert])
    XCTAssertEqual(runs[0].words.count, 3_000)
    XCTAssertEqual(runs[1].words.count, 3_000)
  }

  /// Thousands of identical words with a repeated marker is the shape of input that
  /// hung the cleaner's regular expression. The diff is a token scan, so it must not
  /// care.
  func testAnAdversarialRepetitiveInputDiffsInReasonableTime() {
    let original = Array(repeating: "the same words with markers", count: 2_000)
      .joined(separator: " ")
    let result = original + " and one more clause"

    let started = Date()
    let runs = TextDiff.diff(original: original, result: result)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(TextDiff.summary(runs).inserted, 4)
    XCTAssertEqual(TextDiff.summary(runs).deleted, 0)
  }
}
