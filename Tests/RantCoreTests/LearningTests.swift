import XCTest

@testable import RantCore

/// Learning from corrections is the feature with the most ways to be a betrayal
/// rather than a convenience, so most of these tests are about what it must *not* do:
/// run without being asked, keep the document around the insertion, install a rule
/// nobody approved, or read a password field.
final class LearningTests: XCTestCase {

  private func database() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func engine(
    _ database: Database, enabled: Bool = true, window: TimeInterval = 30
  ) -> LearningEngine {
    var settings = LearningSettings.default
    settings.enabled = enabled
    settings.observationWindow = window
    return LearningEngine(database: database, settings: settings)
  }

  private func context(
    app: String? = "com.apple.mail", role: String? = "AXTextArea", label: String? = "Body",
    secure: Bool = false
  ) -> TranscriptionContext {
    TranscriptionContext(
      appBundleID: app, fieldRole: role, fieldLabel: label, isSecureField: secure)
  }

  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let inserted = "please ask super base about the migration"
  private let corrected = "please ask Supabase about the migration"

  /// Every text column of every row, so a test asserting something was not stored is
  /// checking the table rather than the one column it happened to think of.
  private func tableDump(_ database: Database) throws -> String {
    let columns = try database.query("PRAGMA table_info(learning_candidates);") { $0.string(1) }
    XCTAssertFalse(columns.isEmpty)
    let expression =
      columns.map { "COALESCE(CAST(\($0) AS TEXT), '')" }.joined(separator: " || ' ' || ")
    return try database.query("SELECT \(expression) FROM learning_candidates") { $0.string(0) }
      .joined(separator: "\n")
  }

  // MARK: - Opt-in

  func testTheEngineObservesNothingUntilTheUserTurnsItOn() async throws {
    let database = try database()
    let engine = engine(database, enabled: false)

    await engine.noteInsertion(inserted, context: context(), at: now)
    let observing = await engine.isObserving
    XCTAssertFalse(observing, "a disabled engine must not even hold the inserted text")

    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(2))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
    XCTAssertEqual(try tableDump(database), "")
  }

  func testTurningTheFeatureOffDropsAnInsertionAlreadyBeingWatched() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion(inserted, context: context(), at: now)

    var off = LearningSettings.default
    off.enabled = false
    await engine.update(settings: off)

    let observing = await engine.isObserving
    XCTAssertFalse(observing)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
  }

  // MARK: - Spotting a correction

  func testACorrectedTermBecomesAPendingProposal() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion(inserted, context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(3))
    let proposal = try XCTUnwrap(candidate)
    XCTAssertEqual(proposal.spoken, "super base")
    XCTAssertEqual(proposal.written, "Supabase")
    XCTAssertEqual(proposal.status, .pending)
    XCTAssertEqual(proposal.occurrences, 1)
    XCTAssertEqual(proposal.appBundleID, "com.apple.mail")
  }

  /// The insertion usually lands in the middle of something private. What Rant wrote
  /// is fair game; the letter it was written into is not.
  func testTheSurroundingDocumentIsNeverStored() async throws {
    let database = try database()
    let engine = engine(database)

    let secrets = (0..<200).map { "confidential\($0)" }
    let before = secrets[0..<100].joined(separator: " ")
    let after = secrets[100...].joined(separator: " ")
    await engine.noteInsertion(inserted, context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: "\(before) \(corrected) \(after)", context: context(),
      at: now.addingTimeInterval(4))
    let proposal = try XCTUnwrap(candidate)
    XCTAssertEqual(proposal.spoken, "super base")
    XCTAssertEqual(proposal.correctedText, corrected)

    let dump = try tableDump(database)
    XCTAssertFalse(dump.isEmpty)
    for secret in secrets {
      XCTAssertFalse(dump.contains(secret), "the surrounding document reached the database")
    }
  }

  /// Two unrelated changes are the user rewriting a sentence. There is no dictionary
  /// rule in that, and guessing one would rewrite every later dictation.
  func testAWholesaleRewriteIsDiscardedRatherThanGuessedAt() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion("please ask super base about the migration", context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: "could you ask Supabase about the migration", context: context(),
      at: now.addingTimeInterval(2))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
  }

  /// A substitution that looks nothing like what Rant wrote is a change of mind, not a
  /// mishearing — and below the floor it is not even written down.
  func testALowConfidenceSubstitutionIsNeitherProposedNorStored() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion("let us meet on thursday", context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: "let us meet on the following tuesday", context: context(),
      at: now.addingTimeInterval(5))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
    XCTAssertEqual(try tableDump(database), "")
  }

  // MARK: - The window

  func testAnEditAfterTheWindowHasClosedIsIgnored() async throws {
    let database = try database()
    let engine = engine(database, window: 10)
    await engine.noteInsertion(inserted, context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(11))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
    let observing = await engine.isObserving
    XCTAssertFalse(observing, "a closed window should release the text it was holding")
  }

  func testAnEditInADifferentAppIsIgnored() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion(inserted, context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(app: "com.apple.Safari"),
      at: now.addingTimeInterval(2))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
  }

  func testAnEditInADifferentFieldOfTheSameAppIsIgnored() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion(inserted, context: context(), at: now)

    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(label: "Subject"), at: now.addingTimeInterval(2))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
  }

  // MARK: - Repetition

  func testRepeatingTheSameCorrectionRaisesOccurrencesRatherThanDuplicating() async throws {
    let database = try database()
    let engine = engine(database)

    for step in 0..<3 {
      let at = now.addingTimeInterval(Double(step) * 100)
      await engine.noteInsertion(inserted, context: context(), at: at)
      _ = try await engine.observeEdit(
        fieldText: corrected, context: context(), at: at.addingTimeInterval(2))
    }

    let count = try await engine.count()
    XCTAssertEqual(count, 1)
    let proposals = try await engine.candidates()
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals.first?.occurrences, 3)
  }

  // MARK: - Secure fields

  func testASecureFieldIsNeverLearnedFrom() async throws {
    let database = try database()
    let engine = engine(database)
    let secure = context(role: "AXSecureTextField", label: "Password", secure: true)
    XCTAssertNotNil(
      InjectionPolicy().mustRefuse(secure), "the policy this test relies on has changed")

    await engine.noteInsertion("hunter two", context: secure, at: now)
    let observing = await engine.isObserving
    XCTAssertFalse(observing)

    // And an edit reported for a secure field cannot revive an earlier observation.
    await engine.noteInsertion(inserted, context: context(), at: now)
    let candidate = try await engine.observeEdit(
      fieldText: corrected, context: context(role: "AXSecureTextField", secure: true),
      at: now.addingTimeInterval(2))
    XCTAssertNil(candidate)
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
    XCTAssertEqual(try tableDump(database), "")
  }

  // MARK: - Accepting and rejecting

  func testNothingIsLearnedUntilTheUserAcceptsIt() async throws {
    let database = try database()
    let engine = engine(database)
    let store = VocabularyStore(database: database)

    await engine.noteInsertion(inserted, context: context(), at: now)
    let observed = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(2))
    let proposal = try XCTUnwrap(observed)
    XCTAssertEqual(try store.entries(), [], "a proposal must not change the dictionary")

    let id = try XCTUnwrap(proposal.id)
    let accepted = try await engine.accept(id: id)
    let entry = try XCTUnwrap(accepted)
    XCTAssertEqual(entry.spoken, "super base")
    XCTAssertEqual(entry.written, "Supabase")
    XCTAssertEqual(try store.entries().map(\.written), ["Supabase"])
    let stored = try await engine.candidate(id: id)
    XCTAssertEqual(stored?.status, .accepted)
    let pending = try await engine.candidates()
    XCTAssertTrue(pending.isEmpty)
  }

  func testARejectedProposalIsNeverOfferedAgain() async throws {
    let database = try database()
    let engine = engine(database)

    await engine.noteInsertion(inserted, context: context(), at: now)
    let observed = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(2))
    let proposal = try XCTUnwrap(observed)
    let id = try XCTUnwrap(proposal.id)
    try await engine.reject(id: id)

    await engine.noteInsertion(inserted, context: context(), at: now.addingTimeInterval(100))
    let again = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(102))
    XCTAssertNil(again, "the user has already answered this question")

    let pending = try await engine.candidates()
    XCTAssertTrue(pending.isEmpty)
    let count = try await engine.count()
    XCTAssertEqual(count, 1, "rejecting marks the pair rather than deleting and re-proposing it")
    XCTAssertEqual(try VocabularyStore(database: database).entries(), [])
  }

  func testForgettingEverythingLearnedEmptiesTheTable() async throws {
    let database = try database()
    let engine = engine(database)
    await engine.noteInsertion(inserted, context: context(), at: now)
    _ = try await engine.observeEdit(
      fieldText: corrected, context: context(), at: now.addingTimeInterval(2))

    try await engine.deleteAll()
    let count = try await engine.count()
    XCTAssertEqual(count, 0)
    XCTAssertEqual(try tableDump(database), "")
  }

  // MARK: - Adversarial input

  /// This runs while the user is typing, so the only acceptable behaviour on a hostile
  /// field is to finish. The inputs below are the shapes that break a naive matcher:
  /// a document of one repeated word, a very long insertion, and a field that shares
  /// no words with it at all.
  func testHostileFieldContentsStillFinishQuickly() async throws {
    let database = try database()
    let engine = engine(database)

    let repeated = String(repeating: "aa ", count: 40_000)
    let longInsertion = (0..<2_000).map { "word\($0)" }.joined(separator: " ")
    let unrelated = (0..<5_000).map { "other\($0)" }.joined(separator: " ")
    let nearMiss = (0..<2_000).map { $0 == 900 ? "wrd900" : "word\($0)" }.joined(separator: " ")

    let started = Date()
    for (insertion, field) in [
      (repeated, repeated), (longInsertion, repeated), (repeated, longInsertion),
      (longInsertion, unrelated), (longInsertion, nearMiss),
      (longInsertion, "\(unrelated) \(nearMiss) \(unrelated)"),
    ] {
      await engine.noteInsertion(insertion, context: context(), at: now)
      _ = try await engine.observeEdit(
        fieldText: field, context: context(), at: now.addingTimeInterval(1))
    }
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(elapsed, 5, "matching took \(elapsed)s — that is a stall while typing")
  }
}
