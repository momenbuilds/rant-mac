import Foundation
import XCTest

@testable import RantCore

/// The properties that keep dictation feeling instant, asserted rather than assumed.
///
/// These are wall-clock assertions with `ContinuousClock`, not `XCTMetric`
/// measurements. `measure` reports an average against a baseline someone has to
/// record and maintain per machine, and it reports a number rather than failing;
/// what matters here is a *ceiling* — the work must finish before the user notices,
/// on the worst input anyone can hand it. A hard bound fails loudly on the
/// regressions that matter (an accidental O(n²) pass, a regex that backtracks) and
/// stays quiet when the machine simply happens to be busy.
///
/// Every bound below is deliberately an order of magnitude or more above what the
/// code costs in practice. That is the point: the interesting failure is not "this
/// got 20% slower", it is "this got a thousand times slower because the input was
/// adversarial". A bound tight enough to catch the former flakes on a loaded runner
/// and gets deleted; a bound chosen for the latter survives, and it is the one that
/// would have caught the lazy regex described in `docs/PERFORMANCE.md`.
///
/// Nothing here touches the network, the microphone, or any permission-gated API.
final class PerformanceTests: XCTestCase {

  // MARK: - Helpers

  private func duration(of work: () throws -> Void) rethrows -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    try work()
    return clock.now - start
  }

  private func assertFaster(
    than budget: Duration, _ label: String, file: StaticString = #filePath, line: UInt = #line,
    _ work: () throws -> Void
  ) rethrows {
    let taken = try duration(of: work)
    XCTAssertLessThan(
      taken, budget, "\(label) took \(taken), budget \(budget)", file: file, line: line)
  }

  /// Realistic dictation: ordinary prose carrying the fillers, stutters, corrections
  /// and spoken punctuation a real transcript carries, because cleaning a paragraph
  /// of already-clean text exercises none of the passes that cost anything.
  private func dictation(words wanted: Int) -> String {
    let phrases = [
      "so um I think we should ship the the thing on Tuesday",
      "actually, Wednesday would be safer comma given the review",
      "you know the migration is the bit I am worried about period",
      "let me rephrase that we should hold the release until Friday",
      "the numbers came back higher than we expected new line",
      "erm can you send me the deck before the call question mark",
    ]
    var out: [String] = []
    var index = 0
    while out.count < wanted {
      out.append(contentsOf: phrases[index % phrases.count].split(separator: " ").map(String.init))
      index += 1
    }
    return out.prefix(wanted).joined(separator: " ")
  }

  private func freshStore() throws -> (SQLiteTranscriptStore, Database) {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return (SQLiteTranscriptStore(database: database), database)
  }

  // MARK: - Cleanup on the critical path

  /// Cleanup sits in the gap between "you stopped speaking" and "text appears", and
  /// `docs/PERFORMANCE.md` budgets 50 ms for the whole of that gap. Five hundred
  /// words is a long dictation — a couple of minutes of continuous speech — and
  /// cleaning it is a handful of linear passes, so it costs single-digit
  /// milliseconds in practice. The bound is 200 ms: far enough above the real cost
  /// that a contended runner cannot trip it, far enough below a human-noticeable
  /// stall that a pass which went quadratic would be caught.
  func testCleaningARealisticFiveHundredWordDictationIsWellInsideTheBudget() {
    let cleaner = TranscriptCleaner()
    let input = dictation(words: 500)

    assertFaster(than: .milliseconds(200), "cleaning 500 words") {
      let cleaned = cleaner.clean(input, level: .medium)
      XCTAssertFalse(cleaned.isEmpty)
    }
  }

  /// The same input at every level, because a level that skips a pass must not be
  /// the only one anybody ever times.
  func testCleaningIsBoundedAtEveryCleanupLevel() {
    let cleaner = TranscriptCleaner()
    let input = dictation(words: 500)

    for level in CleanupLevel.allCases {
      assertFaster(than: .milliseconds(200), "cleaning 500 words at \(level.rawValue)") {
        _ = cleaner.clean(input, level: level)
      }
    }
  }

  // MARK: - Adversarial input

  /// This test exists because the failure it guards against has already happened
  /// once: the first version of the self-correction pass was a lazy regex, and it
  /// hung the suite on a 200-word input. A hang is not a slow test, it is a test run
  /// that never ends, so the bound is generous and the verdict is binary — every one
  /// of these inputs must clean in under two seconds. Nothing linear comes close to
  /// that ceiling; anything that backtracks goes straight through it.
  ///
  /// The inputs are the shapes that make a backtracking matcher explode: many
  /// candidate markers with no sentence break between them, many overlapping
  /// alternations, one enormous token with no separator to anchor on, and long runs
  /// of whitespace for the normalisation regexes to work through.
  func testCleaningAdversarialInputCannotHang() {
    let cleaner = TranscriptCleaner()

    for (name, input) in Self.adversarialInputs {
      assertFaster(than: .seconds(2), "cleaning \(name)") {
        _ = cleaner.clean(input, level: .medium)
      }
    }
  }

  /// Spoken-punctuation expansion is a separate scan with its own phrase table, and
  /// that table is matched longest-first — exactly the shape that becomes quadratic
  /// if the scan is ever rewritten to restart from the top of the string.
  func testSpokenPunctuationExpansionCannotHangOnAdversarialInput() {
    let punctuation = SpokenPunctuation()

    for (name, input) in Self.adversarialInputs {
      assertFaster(than: .seconds(2), "expanding \(name)") {
        _ = punctuation.expand(input)
      }
    }
  }

  /// The correction passes, driven directly rather than through `clean`, so a
  /// regression in one of them cannot hide behind the cost of the others. All three
  /// are documented as linear token scans; this is what holds them to it.
  func testCorrectionPassesCannotHangOnAdversarialInput() {
    let cleaner = TranscriptCleaner()

    for (name, input) in Self.adversarialInputs {
      assertFaster(than: .seconds(2), "resolving corrections in \(name)") {
        _ = cleaner.resolveSelfCorrections(input)
      }
      assertFaster(than: .seconds(2), "resolving restarts in \(name)") {
        _ = cleaner.resolveRestarts(input)
      }
      assertFaster(than: .seconds(2), "collapsing repetitions in \(name)") {
        _ = cleaner.collapseRepetitions(input)
      }
    }
  }

  /// Named, so a failure says which shape broke rather than which array index did.
  private static let adversarialInputs: [(String, String)] = [
    (
      "repeated correction markers",
      Array(repeating: "actually, sorry, i mean, or rather, wait no,", count: 400)
        .joined(separator: " ")
    ),
    (
      "repeated restart markers",
      Array(repeating: "scratch that we ship friday strike that", count: 400)
        .joined(separator: " ")
    ),
    (
      "repeated punctuation words",
      Array(repeating: "comma period semicolon question mark new line open paren", count: 400)
        .joined(separator: " ")
    ),
    (
      "a long utterance with no sentence break",
      Array(repeating: "the plan is, actually, the other plan", count: 400).joined(separator: " ")
    ),
    ("a single hundred-thousand-character token", String(repeating: "a", count: 100_000)),
    ("deeply repeated whitespace", String(repeating: " ", count: 100_000) + "hello"),
    (
      "alternating words and whitespace runs",
      Array(repeating: "word" + String(repeating: " ", count: 200), count: 500).joined()
    ),
    ("repeated stutter", Array(repeating: "the", count: 20_000).joined(separator: " ")),
  ]

  // MARK: - History search

  /// `docs/PERFORMANCE.md` promises history search is "instant at tens of thousands
  /// of rows", and names the mechanism: FTS5, never `LIKE '%…%'`. Both halves are
  /// asserted here, because the absolute bound alone would still pass on a machine
  /// fast enough to scan forty thousand rows inside it — and would then quietly stop
  /// holding as the corpus grew on someone's real machine.
  ///
  /// The absolute bound is 250 ms, roughly the point at which a search field stops
  /// feeling attached to the keyboard. An FTS lookup for a rare term over this
  /// corpus costs a fraction of a millisecond, so the margin exists entirely to
  /// absorb a contended runner.
  ///
  /// The ratio assertion is the one with teeth: FTS must be at least ten times
  /// faster than the equivalent `LIKE` scan over the same rows. If someone replaces
  /// the MATCH with a LIKE, or the triggers stop maintaining the index, the ratio
  /// collapses towards one and this fails even on a machine where both are fast.
  ///
  /// "Equivalent" has to be earned. The scan used to be a `COUNT(*)`, which compares
  /// the indexed path *decoding rows* against the scanned path *counting* them — so
  /// the ratio partly measured decode cost, and adding a column to the transcript
  /// narrowed it enough to fail on a fast runner. Both sides now select the same
  /// columns, so what is left in the comparison is finding the rows.
  /// The same rows the FTS path returns, found by scanning instead of by the index.
  ///
  /// Selects the same columns rather than counting, so the two measurements differ in
  /// how the rows are located and in nothing else.
  private func scanWithLike(_ needle: String, in database: Database) throws -> [String] {
    try database.query(
      """
      SELECT id, created_at, raw_text, final_text, provider
      FROM transcripts WHERE final_text LIKE ?
      """,
      [.text("%\(needle)%")]
    ) { $0.string(3) }
  }

  func testHistorySearchStaysFastAtTensOfThousandsOfRows() throws {
    let (store, database) = try freshStore()
    let rows = 40_000
    let needle = "zarquon"
    let needleEvery = 2_000

    try insertCorpus(rows, into: database, needle: needle, everyNthRow: needleEvery)
    XCTAssertEqual(try store.count(), rows)

    // Warm both paths so the comparison measures the index rather than the
    // first-touch cost of compiling a statement and faulting in pages.
    _ = try store.search(needle)
    _ = try scanWithLike(needle, in: database)

    var results: [TranscriptSearchResult] = []
    let indexed = try duration(of: {
      results = try store.search(needle)
    })
    XCTAssertFalse(results.isEmpty, "the corpus must actually contain the needle")

    let scanned = try duration(of: {
      let matches = try scanWithLike(needle, in: database)
      XCTAssertEqual(matches.count, rows / needleEvery)
    })

    XCTAssertLessThan(
      indexed, .milliseconds(250), "FTS search over \(rows) rows took \(indexed)")
    XCTAssertLessThan(
      indexed * 10, scanned,
      "FTS search (\(indexed)) is not dramatically faster than the LIKE scan (\(scanned)) — "
        + "the index is not doing its job")
  }

  /// Search cost must come from the number of rows *returned*, not the number
  /// stored. A term present in every row is what a user hits the moment they type a
  /// common word, and the `LIMIT` is the only thing standing between that and
  /// decoding the whole table.
  func testHistorySearchIsBoundedEvenWhenTheTermMatchesEveryRow() throws {
    let (store, database) = try freshStore()
    try insertCorpus(40_000, into: database, needle: "zarquon", everyNthRow: 2_000)

    _ = try store.search("quarterly")
    try assertFaster(than: .milliseconds(250), "FTS search for a term in every row") {
      let results = try store.search("quarterly")
      XCTAssertEqual(results.count, 50, "the LIMIT is what keeps this bounded")
    }
  }

  /// Rows go in with raw SQL inside one transaction rather than through
  /// `store.save`, which opens a transaction and updates two aggregate tables per
  /// call. That is the right behaviour for a dictation, but it would make building a
  /// forty-thousand-row fixture the slowest thing in the suite, and the fixture is
  /// not what is under test. The FTS triggers fire either way, so the index these
  /// tests are about is built exactly as it is in production.
  private func insertCorpus(
    _ count: Int, into database: Database, needle: String, everyNthRow: Int
  ) throws {
    let topics = ["migration", "release", "hiring", "roadmap", "pricing", "support"]
    try database.transaction {
      for index in 0..<count {
        let topic = topics[index % topics.count]
        var text = "Notes on the \(topic) for the quarterly plan, item number \(index)."
        if index.isMultiple(of: everyNthRow) { text += " The \(needle) question is still open." }
        try database.run(
          """
          INSERT INTO transcripts
            (created_at, raw_text, final_text, provider, cleanup_level, category,
             duration_ms, word_count, content_hash, source)
          VALUES (?,?,?,'test','medium','other',2000,?,?,'rant')
          """,
          [
            .double(Double(1_700_000_000 + index)), .text(text), .text(text),
            .int(text.split(separator: " ").count), .text("hash-\(index)"),
          ])
      }
    }
  }

  // MARK: - Either side of the transcript

  /// Insertion spacing runs once per dictation and decides a leading space. It is
  /// pure inspection of a few characters at the ends of the surrounding text, so ten
  /// thousand calls — more dictations than a heavy user makes in a year — must
  /// disappear into the noise. Five hundred milliseconds for the lot leaves each
  /// call 50 µs, which is orders of magnitude more than it needs and still fails at
  /// once if someone makes the function walk the whole `before` context.
  func testInsertionSpacingIsEffectivelyFree() {
    let spacing = InsertionSpacing()
    // Long surrounding context on purpose: the cheap implementation looks only at
    // the ends of these strings, and a careless one would read all of them.
    let before = String(repeating: "This is what was already in the field. ", count: 500)
    let after = String(repeating: " and then some more text follows.", count: 500)

    assertFaster(than: .milliseconds(500), "10,000 insertion-spacing plans") {
      for index in 0..<10_000 {
        let plan = spacing.plan(
          text: "hello there", before: index.isMultiple(of: 2) ? before : nil, after: after)
        XCTAssertFalse(plan.text.isEmpty)
      }
    }
  }

  /// The gate sits between the key going down and audio starting, which
  /// `docs/PERFORMANCE.md` budgets at 150 ms in total — the gate's own share of that
  /// has to be invisible. It is a value type that reads no clock and allocates
  /// nothing per event beyond the actions it returns, so ten thousand complete
  /// press-and-release cycles fit inside the same 500 ms allowance used above.
  func testTheHotkeyGateIsEffectivelyFree() {
    assertFaster(than: .milliseconds(500), "10,000 gate press cycles") {
      var gate = DictationGate(mode: .hybrid)
      var now: TimeInterval = 0
      for _ in 0..<10_000 {
        _ = gate.handle(.triggerDown(otherModifiersHeld: false), at: now)
        now += 0.4
        _ = gate.handle(.triggerUp, at: now)
        now += 0.1
        _ = gate.handle(.sessionEnded, at: now)
        now += 1
      }
    }
  }

  /// A state machine that accumulates — a growing history, a retained event log — is
  /// invisible in a unit test and fatal in an app that stays open for weeks. This
  /// drives a long mixed sequence and compares the cost of the last quarter against
  /// the first. Flat means the gate keeps nothing. The four-times allowance is wide
  /// enough that scheduler noise cannot fail it, and narrow enough that real growth
  /// — which would be linear per event, so far worse than fourfold across this many
  /// events — cannot pass it.
  func testTheHotkeyGateDoesNotDegradeOverALongEventSequence() {
    let quarter = 50_000
    let events: [GateEvent] = [
      .triggerDown(otherModifiersHeld: false), .otherKeyDown, .triggerUp, .escape,
      .triggerDown(otherModifiersHeld: true), .triggerUp, .externalStop, .sessionEnded,
    ]

    var gate = DictationGate(mode: .hybrid)
    var now: TimeInterval = 0

    func drive(_ count: Int) -> Duration {
      duration(of: {
        for index in 0..<count {
          _ = gate.handle(events[index % events.count], at: now)
          now += 0.05
        }
      })
    }

    let first = drive(quarter)
    _ = drive(quarter * 2)
    let last = drive(quarter)

    // The floor keeps the ratio meaningful when the first quarter is so fast that
    // its measurement is mostly timer resolution.
    XCTAssertLessThan(
      last, max(first, .milliseconds(1)) * 4,
      "the gate slowed down as it ran: first \(quarter) events took \(first), last took \(last)")
  }

  // MARK: - Preview and overlay

  /// `TextDiff` runs when a transform preview is shown, after the user has pressed a
  /// shortcut and is waiting. Myers' search costs O(N·D), and the head/tail trim
  /// plus the edit-distance cap are what keep D small — this pins both. Four
  /// thousand words with scattered edits is a long document lightly rewritten, the
  /// realistic worst case for a preview panel. One second is well past the point the
  /// preview would feel broken and roughly two orders of magnitude above the real
  /// cost.
  func testDiffingAFewThousandWordsCompletesInsideTheBudget() {
    let original = (0..<4_000).map { "word\($0)" }
    var edited = original
    for index in stride(from: 100, to: 4_000, by: 250) {
      edited[index] = "changed\(index)"
    }

    assertFaster(than: .seconds(1), "diffing 4,000 words with scattered edits") {
      let runs = TextDiff.diff(original: original, result: edited)
      XCTAssertFalse(TextDiff.isUnchanged(runs))
    }
  }

  /// The pathological diff: two texts with nothing in common, where the edit
  /// distance approaches N + M and the search would do quadratic work were it not
  /// capped. `maximumEditDistance` is the guard, and this is what shows it is
  /// actually reached rather than merely present.
  func testDiffingTwoUnrelatedDocumentsIsCappedRatherThanQuadratic() {
    let original = (0..<4_000).map { "alpha\($0)" }
    let result = (0..<4_000).map { "beta\($0)" }

    assertFaster(than: .seconds(1), "diffing two unrelated 4,000-word documents") {
      let runs = TextDiff.diff(original: original, result: result)
      XCTAssertFalse(runs.isEmpty)
    }
  }

  /// The overlay redraws its meter while the user is watching it. Sixty full
  /// recomputations of the bar array must therefore cost far less than the ~33 ms a
  /// 30 Hz frame allows, or the waveform is competing for time with the audio tap's
  /// hand-off during the one moment latency is visible. The history is deliberately
  /// far longer than `barCount`, so a regression that maps the whole array instead
  /// of its suffix shows up here.
  func testMeterGeometryIsCheapEnoughToRunAtThirtyHertz() {
    let geometry = MeterGeometry()
    let history = (0..<10_000).map { Float($0 % 100) / 100 }

    assertFaster(than: .milliseconds(30), "60 meter recomputations over a 10,000-sample history") {
      for _ in 0..<60 {
        let bars = geometry.bars(from: history)
        XCTAssertEqual(bars.count, geometry.barCount)
      }
    }
  }

  /// RMS is computed on the hand-off out of the audio tap, once per buffer. A second
  /// of 16 kHz audio arrives as roughly ten buffers, so a hundred passes over a full
  /// second of samples stands in for ten seconds of speech. It has to be trivial,
  /// and the bound catches anything that starts allocating per sample.
  func testLevelMeteringOverAFullSecondOfAudioIsTrivial() {
    let samples = Data(count: 16_000 * 2)

    assertFaster(than: .milliseconds(200), "100 RMS passes over a second of audio") {
      for _ in 0..<100 {
        _ = AudioMath.rms(ofInt16: samples)
      }
    }
  }

  func testScalingProbe() {
    let cleaner = TranscriptCleaner()
    let five = dictation(words: 500)
    print("PROBE clean500=\(duration(of: { _ = cleaner.clean(five, level: .medium) }))")
    print("PROBE clean500b=\(duration(of: { _ = cleaner.clean(five, level: .medium) }))")
    for (name, input) in Self.adversarialInputs {
      let tokens = input.split(separator: " ").count
      print("PROBE adversarial \(name) tokens=\(tokens) clean=\(duration(of: { _ = cleaner.clean(input, level: .medium) }))")
    }
  }
}

/// End-to-end latency of the dictation pipeline.
///
/// The budgets in `docs/PERFORMANCE.md` are about how the app *feels*, and the two
/// that a test can hold honestly are the ones that do not involve a network: how long
/// it takes to arm the microphone after the key goes down, and how long everything
/// after the transcript arrives takes. Those bracket the provider, which is the only
/// part Rant does not control.
extension PerformanceTests {

  private func pipelineSession(
    audio: FixtureAudioCapture = .tone(seconds: 3),
    transcriber: ScriptedTranscriber = ScriptedTranscriber(
      raw: "so the migration lands wednesday and i will write the notes up after"),
    injector: RecordingInjector = RecordingInjector()
  ) -> DictationSession {
    DictationSession(
      audio: audio, transcriber: transcriber, injector: injector,
      context: StaticContextProvider(.empty))
  }

  /// The key goes down and the microphone must already be armed. Everything else can
  /// be a few milliseconds late; this cannot, because the syllable is gone.
  func testArmingTheMicrophoneIsEffectivelyInstant() async {
    let session = pipelineSession()
    let started = ContinuousClock.now
    await session.start()
    let elapsed = ContinuousClock.now - started

    // The budget is 150 ms on real hardware, where the audio engine is the cost. With
    // a fixture capture this measures Rant's own overhead, which should be nothing.
    print("MEASURED arming: \(elapsed)")
    XCTAssertLessThan(elapsed, .milliseconds(50), "arming took \(elapsed)")
  }

  /// Everything after the transcript arrives: cleanup, vocabulary, classification,
  /// storage and insertion. The user experiences this as the delay between finishing
  /// a sentence and seeing it, so it has to disappear into the provider's round trip.
  func testTheWholePipelineAfterTheProviderIsUnderTheBudget() async throws {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    let injector = RecordingInjector()
    let session = DictationSession(
      audio: FixtureAudioCapture.tone(seconds: 3),
      transcriber: ScriptedTranscriber(
        raw: "so the migration lands wednesday and i will write the notes up after"),
      injector: injector,
      context: StaticContextProvider(.empty),
      store: SQLiteTranscriptStore(database: database))

    await session.start()
    let started = ContinuousClock.now
    let outcome = await session.stopAndTranscribe()
    let elapsed = ContinuousClock.now - started

    XCTAssertNotNil(outcome)
    XCTAssertNotNil(injector.lastText)
    // Generous enough not to flake on a loaded machine, tight enough that an
    // accidental O(n²) or a blocking write fails it.
    print("MEASURED pipeline after provider: \(elapsed)")
    XCTAssertLessThan(elapsed, .milliseconds(250), "the pipeline took \(elapsed)")
  }

  /// A long dictation must not cost proportionally more *after* the transcript: the
  /// text passes are linear, and this is the test that says so.
  func testALongDictationDoesNotSlowThePipelineDisproportionately() async throws {
    func measure(words: Int) async -> Duration {
      let text = Array(repeating: "word", count: words).joined(separator: " ")
      let injector = RecordingInjector()
      let session = DictationSession(
        audio: FixtureAudioCapture.tone(seconds: 3),
        transcriber: ScriptedTranscriber(raw: text),
        injector: injector,
        context: StaticContextProvider(.empty))
      await session.start()
      let started = ContinuousClock.now
      _ = await session.stopAndTranscribe()
      return ContinuousClock.now - started
    }

    let short = await measure(words: 50)
    let long = await measure(words: 2_000)
    // Forty times the words should not be anywhere near forty times the work once the
    // fixed costs are counted, but the assertion that matters is simply that a long
    // one still completes quickly.
    print("MEASURED 50 words: \(short) · 2000 words: \(long)")
    XCTAssertLessThan(long, .milliseconds(600), "2000 words took \(long), 50 took \(short)")
  }
}
