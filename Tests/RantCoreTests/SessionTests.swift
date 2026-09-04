import XCTest
@testable import RantCore

/// The whole loop, end to end, with no microphone, no network and no permissions —
/// fixture audio in, recording injector out. If this suite is green the pipeline is
/// wired correctly; only the OS-level edges need a human.
final class SessionTests: XCTestCase {

  private func makeSession(
    audio: FixtureAudioCapture = .tone(),
    transcriber: ScriptedTranscriber = ScriptedTranscriber(raw: "um hello there"),
    injector: RecordingInjector = RecordingInjector(),
    context: TranscriptionContext = .empty,
    store: (any TranscriptStore)? = nil,
    enhancer: (any EnhancementProvider)? = nil,
    vocabulary: VocabularyApplier = VocabularyApplier()
  ) -> DictationSession {
    DictationSession(
      audio: audio, transcriber: transcriber, injector: injector,
      context: StaticContextProvider(context), store: store, enhancer: enhancer,
      vocabulary: vocabulary,
      now: { Date(timeIntervalSince1970: 1_700_000_000) })
  }

  private func store() throws -> SQLiteTranscriptStore {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return SQLiteTranscriptStore(database: database)
  }

  // MARK: - The happy path

  func testAFullDictationReachesTheCursorAsCleanText() async throws {
    let injector = RecordingInjector()
    let session = makeSession(
      transcriber: ScriptedTranscriber(raw: "um so we should ship it"), injector: injector)

    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)

    XCTAssertEqual(outcome.transcript.finalText, "So we should ship it.")
    XCTAssertEqual(injector.lastText, "So we should ship it.")
    XCTAssertEqual(outcome.injection, .insertedDirectly)
  }

  func testTheProvidersOwnCleanupIsPreferredWhenItSuppliesOne() async throws {
    let session = makeSession(
      transcriber: ScriptedTranscriber(raw: "um so we ship", cleaned: "We ship on Friday."))
    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.finalText, "We ship on Friday.")
    XCTAssertEqual(outcome.transcript.rawText, "um so we ship",
                   "the verbatim transcript must be kept alongside")
  }

  func testStateProgressesThroughTheExpectedStages() async throws {
    let session = makeSession()
    let recorder = StateRecorder()
    await session.observeState { state in recorder.append(state) }

    await session.start()
    _ = await session.stopAndTranscribe()

    let states = recorder.states
    XCTAssertTrue(states.contains(.listening))
    XCTAssertTrue(states.contains(.transcribing))
    XCTAssertTrue(states.contains(.inserting))
    XCTAssertEqual(states.last, .idle)
  }

  func testLatencyIsRecordedForEachStage() async throws {
    let session = makeSession()
    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)
    XCTAssertNotNil(outcome.latency.transcriptionMs)
    XCTAssertNotNil(outcome.latency.injectionMs)
    XCTAssertNotNil(outcome.latency.totalMs)
  }

  // MARK: - Ordering guarantees

  /// Capture must be running before we spend time on context or connection warm-up,
  /// or the first syllable is lost to work the user did not ask for.
  func testAudioStartsBeforeContextIsGatheredAndTheConnectionIsWarmed() async {
    let audio = FixtureAudioCapture.tone()
    let transcriber = ScriptedTranscriber(raw: "hello")
    let session = makeSession(audio: audio, transcriber: transcriber)

    await session.start()
    XCTAssertEqual(audio.startCount, 1)
    XCTAssertEqual(transcriber.warmUpCount, 1, "warm-up should have happened, but after start")
  }

  func testStartingTwiceDoesNotBeginASecondRecording() async {
    let audio = FixtureAudioCapture.tone()
    let session = makeSession(audio: audio)
    await session.start()
    await session.start()
    XCTAssertEqual(audio.startCount, 1)
  }

  func testStoppingWithoutStartingDoesNothing() async {
    let injector = RecordingInjector()
    let session = makeSession(injector: injector)
    let nilResult = await session.stopAndTranscribe()
    XCTAssertNil(nilResult)
    XCTAssertTrue(injector.requests.isEmpty)
  }

  // MARK: - Cancel

  func testCancelDiscardsTheRecordingAndInsertsNothing() async {
    let audio = FixtureAudioCapture.tone()
    let injector = RecordingInjector()
    let session = makeSession(audio: audio, injector: injector)

    await session.start()
    await session.cancel()

    XCTAssertEqual(audio.cancelCount, 1)
    XCTAssertTrue(injector.requests.isEmpty, "a cancelled dictation must insert nothing")
    let state = await session.state
    XCTAssertEqual(state, .idle)
  }

  func testSilentRecordingsAreDroppedWithoutSpendingARequest() async {
    let transcriber = ScriptedTranscriber(raw: "should never be asked for")
    let injector = RecordingInjector()
    let session = makeSession(
      audio: .silence(), transcriber: transcriber, injector: injector)

    await session.start()
    let nilResult = await session.stopAndTranscribe()
    XCTAssertNil(nilResult)
    XCTAssertTrue(transcriber.receivedContexts.isEmpty, "no request should have been made")
    XCTAssertTrue(injector.requests.isEmpty)
  }

  // MARK: - Failure and recovery

  func testAFailedTranscriptionIsReportedAndRetryable() async {
    let session = makeSession(
      transcriber: ScriptedTranscriber(failure: TranscriptionError.network("offline")))
    await session.start()
    let nilResult = await session.stopAndTranscribe()
    XCTAssertNil(nilResult)

    let state = await session.state
    guard case .failure(_, let retryable) = state else {
      return XCTFail("expected a failure state, got \(state)")
    }
    XCTAssertTrue(retryable)
  }

  /// Losing a recording to a flaky network is the failure people remember. Retry must
  /// not require saying it all again.
  func testRetryReusesTheRecordingWithoutAskingTheUserToRepeatThemselves() async throws {
    let transcriber = ScriptedTranscriber([
      .failure(TranscriptionError.network("offline")),
      .success(TranscriptionResult(raw: "second time lucky", provider: "scripted")),
    ])
    let injector = RecordingInjector()
    let session = makeSession(transcriber: transcriber, injector: injector)

    await session.start()
    let nilResult = await session.stopAndTranscribe()
    XCTAssertNil(nilResult)
    let produced = await session.retryLast()
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.finalText, "Second time lucky.")
    XCTAssertEqual(injector.lastText, "Second time lucky.")
  }

  func testRetryWithNothingToRetryIsHarmless() async {
    let session = makeSession()
    let nilResult = await session.retryLast()
    XCTAssertNil(nilResult)
  }

  func testAnUnauthorizedFailureIsNotOfferedAsRetryable() async {
    let session = makeSession(transcriber: ScriptedTranscriber(failure: TranscriptionError.unauthorized))
    await session.start()
    _ = await session.stopAndTranscribe()
    let state = await session.state
    guard case .failure(_, let retryable) = state else { return XCTFail("expected failure") }
    XCTAssertFalse(retryable, "retrying a rejected key just fails again")
  }

  /// If injection fails the text still exists and the user still earned it.
  func testTextSurvivesAnInjectionFailureSoItCanStillBePasted() async {
    let injector = RecordingInjector()
    injector.error = InjectionError.noFocusedElement
    let session = makeSession(injector: injector)

    await session.start()
    _ = await session.stopAndTranscribe()
    let last = await session.lastSuccessfulText
    XCTAssertEqual(last, "Hello there.")
  }

  func testPasteLastReinsertsTheMostRecentTranscript() async {
    let injector = RecordingInjector()
    let session = makeSession(injector: injector)
    await session.start()
    _ = await session.stopAndTranscribe()

    _ = await session.pasteLast()
    XCTAssertEqual(injector.requests.count, 2)
    XCTAssertEqual(injector.lastText, "Hello there.")
  }

  func testPasteLastWithNoHistoryDoesNothing() async {
    let session = makeSession()
    let nilResult = await session.pasteLast()
    XCTAssertNil(nilResult)
  }

  // MARK: - Local only

  /// The promise is that "local only" means local only: a cloud provider must be
  /// refused before any audio is captured, not fall back silently.
  func testLocalOnlyRefusesACloudProviderBeforeRecording() async {
    let audio = FixtureAudioCapture.tone()
    let session = makeSession(
      audio: audio, transcriber: ScriptedTranscriber(raw: "x", sendsAudioOffDevice: true))

    await session.start(settings: DictationSettings(localOnly: true))
    XCTAssertEqual(audio.startCount, 0, "not a single sample should be captured")
    let state = await session.state
    guard case .failure(let message, _) = state else { return XCTFail("expected a refusal") }
    XCTAssertTrue(message.contains("local only"))
  }

  func testLocalOnlyAllowsAnOnDeviceProvider() async throws {
    let session = makeSession(
      transcriber: ScriptedTranscriber(raw: "on device", sendsAudioOffDevice: false))
    await session.start(settings: DictationSettings(localOnly: true))
    let produced = await session.stopAndTranscribe(settings: DictationSettings(localOnly: true))
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.finalText, "On device.")
  }

  // MARK: - Context and history

  func testContextReachesTheProvider() async {
    let transcriber = ScriptedTranscriber(raw: "hello")
    let session = makeSession(
      transcriber: transcriber,
      context: TranscriptionContext(appBundleID: "com.apple.Notes", textBeforeCursor: "Dear all,"))
    await session.start()
    _ = await session.stopAndTranscribe()
    XCTAssertEqual(transcriber.receivedContexts.first??.textBeforeCursor, "Dear all,")
  }

  func testTheTranscriptIsClassifiedByWhereItWasDictated() async throws {
    let session = makeSession(
      context: TranscriptionContext(appBundleID: "com.apple.dt.Xcode"))
    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.category, .developer)
  }

  func testASuccessfulDictationIsSavedToHistory() async throws {
    let store = try store()
    let session = makeSession(store: store)
    await session.start()
    _ = await session.stopAndTranscribe()
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.recent(limit: 1, offset: 0).first?.finalText, "Hello there.")
  }

  func testAFailedDictationIsNotSavedToHistory() async throws {
    let store = try store()
    let session = makeSession(
      transcriber: ScriptedTranscriber(failure: TranscriptionError.network("x")), store: store)
    await session.start()
    _ = await session.stopAndTranscribe()
    XCTAssertEqual(try store.count(), 0)
  }

  // MARK: - Vocabulary and enhancement

  /// The user's own dictionary must beat the model, always.
  func testDictionaryReplacementsAreAppliedAfterTheModel() async throws {
    let session = makeSession(
      transcriber: ScriptedTranscriber(raw: "we deploy on super base and ver sell"),
      vocabulary: VocabularyApplier(replacements: [
        ("super base", "Supabase", false), ("ver sell", "Vercel", false),
      ]))
    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.finalText, "We deploy on Supabase and Vercel.")
  }

  func testSnippetsExpandInsideALongerDictation() async throws {
    let session = makeSession(
      transcriber: ScriptedTranscriber(raw: "you can reach me at my meeting link any time"),
      vocabulary: VocabularyApplier(snippets: [("my meeting link", "https://cal.com/rant")]))
    await session.start()
    let produced = await session.stopAndTranscribe()
    let outcome = try XCTUnwrap(produced)
    XCTAssertTrue(outcome.transcript.finalText.contains("https://cal.com/rant"))
  }

  func testEnhancementRunsOnlyAtTheHighestCleanupLevel() async throws {
    let enhancer = StubEnhancer { "ENHANCED: \($0)" }
    let session = makeSession(enhancer: enhancer)

    await session.start()
    _ = await session.stopAndTranscribe(settings: DictationSettings(cleanupLevel: .medium))
    XCTAssertTrue(enhancer.calls.isEmpty, "medium cleanup should not call a model")

    await session.start()
    let produced = await session.stopAndTranscribe(settings: DictationSettings(cleanupLevel: .high))
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(enhancer.calls.count, 1)
    XCTAssertTrue(outcome.transcript.finalText.hasPrefix("ENHANCED:"))
    XCTAssertTrue(outcome.transcript.enhanced)
  }

  /// A failing enhancer must not lose the transcript.
  func testAFailingEnhancerFallsBackToTheCleanedText() async throws {
    struct Failing: EnhancementProvider {
      let identifier = "failing"
      let displayName = "Failing"
      let sendsTextOffDevice = false
      func enhance(_ text: String, instruction: String, context: TranscriptionContext?) async throws -> String {
        throw TranscriptionError.network("no")
      }
      func isAvailable() async -> Bool { true }
    }
    let session = makeSession(enhancer: Failing())
    await session.start()
    let produced = await session.stopAndTranscribe(settings: DictationSettings(cleanupLevel: .high))
    let outcome = try XCTUnwrap(produced)
    XCTAssertEqual(outcome.transcript.finalText, "Hello there.")
    XCTAssertFalse(outcome.transcript.enhanced)
  }

  func testPreferLocalCleanupAsksTheProviderNotToRewrite() async {
    let transcriber = ScriptedTranscriber(raw: "um hello")
    let session = makeSession(transcriber: transcriber)
    await session.start()
    _ = await session.stopAndTranscribe(settings: DictationSettings(preferLocalCleanup: true))
    XCTAssertEqual(transcriber.receivedOptions.first?.allowProviderCleanup, false)
  }
}

/// Collects state changes from the session's observer.
private final class StateRecorder: @unchecked Sendable {
  private var storage: [DictationState] = []
  private let lock = NSLock()
  func append(_ state: DictationState) { lock.withLock { storage.append(state) } }
  var states: [DictationState] { lock.withLock { storage } }
}
