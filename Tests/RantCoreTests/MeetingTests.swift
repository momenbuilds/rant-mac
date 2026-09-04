import XCTest

@testable import RantCore

/// The notetaker, end to end, with no microphone, no screen-recording permission and
/// no calendar. Everything that could need hardware sits behind a protocol, and these
/// tests only ever meet the fixtures.
final class MeetingTests: XCTestCase {

  // MARK: - Helpers

  private func segment(
    _ text: String, _ channel: MeetingChannel = .me, at start: Int, to end: Int? = nil,
    speaker: String? = nil
  ) -> MeetingSegment {
    MeetingSegment(
      startedMilliseconds: start, endedMilliseconds: end, speaker: speaker, channel: channel,
      text: text)
  }

  private func freshStore() throws -> (MeetingStore, Database) {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return (MeetingStore(database: database), database)
  }

  // MARK: - Session state machine

  func testAMeetingStartsIdleAndBeginsCaptureWhenStarted() {
    var session = MeetingSession()
    XCTAssertEqual(session.state, .idle)
    XCTAssertEqual(session.handle(.start(at: Date())), [.beginCapture])
    XCTAssertEqual(session.state, .recording)
  }

  func testStartingATwiceStartedMeetingDoesNothing() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    XCTAssertEqual(session.handle(.start(at: Date())), [])
    XCTAssertEqual(session.state, .recording)
  }

  func testTranscriptArrivingWhilePausedIsDroppedAndCounted() {
    var session = MeetingSession()
    let start = Date()
    session.handle(.start(at: start))
    session.handle(.heard(segment("before the break", .me, at: 0, to: 1_000)))
    XCTAssertEqual(session.handle(.pause(at: start.addingTimeInterval(2))), [.pauseCapture])
    session.handle(.heard(segment("in flight when pause was pressed", .them, at: 2_000)))

    XCTAssertEqual(session.segments.count, 1)
    XCTAssertEqual(session.droppedWhilePaused, 1)
  }

  func testResumingAMeetingKeepsOffsetsFromDriftingAcrossTheBreak() {
    var session = MeetingSession()
    let start = Date()
    session.handle(.start(at: start))
    session.handle(.pause(at: start.addingTimeInterval(10)))
    XCTAssertEqual(session.handle(.resume(at: start.addingTimeInterval(70))), [.resumeCapture])

    // Sixty seconds of wall clock passed inside the pause and must not appear in the
    // transcript timeline.
    XCTAssertEqual(session.offsetMilliseconds(at: start.addingTimeInterval(80)), 20_000)
  }

  func testStoppingAnEmptyMeetingDiscardsRatherThanWritingARow() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    XCTAssertEqual(session.handle(.stop(at: Date())), [.endCapture, .discard])
    XCTAssertEqual(session.state, .done)
  }

  func testStoppingAMeetingWithTranscriptPersistsAndSummarises() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    session.handle(.heard(segment("we shipped it", .me, at: 0, to: 900)))
    XCTAssertEqual(session.handle(.stop(at: Date())), [.endCapture, .persist, .summarise])
    XCTAssertEqual(session.state, .finalising)
    XCTAssertEqual(session.handle(.finalised), [])
    XCTAssertEqual(session.state, .done)
  }

  func testFinalisedIsIgnoredUnlessTheMeetingIsFinalising() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    XCTAssertEqual(session.handle(.finalised), [])
    XCTAssertEqual(session.state, .recording)
  }

  func testAFailureMidMeetingStillPersistsWhatWasAlreadyHeard() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    session.handle(.heard(segment("forty nine minutes of this", .them, at: 0, to: 1_000)))
    XCTAssertEqual(session.handle(.failed("the provider went away")), [.endCapture, .persist])
    XCTAssertEqual(session.state, .failed("the provider went away"))
  }

  func testAFailureBeforeAnythingWasHeardDiscards() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    XCTAssertEqual(session.handle(.failed("no audio")), [.endCapture, .discard])
  }

  func testPartialTextShowsInTheLiveTranscriptButIsNeverStored() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    session.handle(.heard(segment("settled text", .me, at: 0, to: 500)))
    session.handle(.partial(channel: .them, text: "still speaking"))

    XCTAssertTrue(session.liveTranscript().contains("Them: still speaking…"))
    XCTAssertEqual(session.segments.count, 1)
    XCTAssertFalse(session.transcript().contains("still speaking"))
  }

  func testASettledSegmentReplacesThePartialForThatChannel() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    session.handle(.partial(channel: .me, text: "half a sen"))
    session.handle(.heard(segment("half a sentence", .me, at: 0, to: 500)))
    XCTAssertFalse(session.liveTranscript().contains("half a sen…"))
  }

  func testResetClearsTheTranscriptButKeepsTheLabels() {
    var session = MeetingSession(labels: MeetingSpeakerLabels(me: "Dan", them: "Priya"))
    session.handle(.start(at: Date()))
    session.handle(.heard(segment("hello", .me, at: 0)))
    session.handle(.reset)

    XCTAssertEqual(session.state, .idle)
    XCTAssertTrue(session.segments.isEmpty)
    XCTAssertEqual(session.labels.them, "Priya")
  }

  // MARK: - Labelling and coalescing

  func testMeAndThemAreLabelledFromTheChannelRatherThanDiarisation() {
    let segments = [segment("mine", .me, at: 0, to: 500), segment("theirs", .them, at: 600, to: 900)]
    let lines = MeetingSession.render(segments, labels: .default)
    XCTAssertEqual(lines, ["Me: mine", "Them: theirs"])
  }

  func testADiarisedSpeakerNameWinsOverTheChannelLabel() {
    let named = segment("hello", .them, at: 0, to: 500, speaker: "Priya")
    XCTAssertEqual(named.displayName(.default), "Priya")
  }

  func testConsecutiveSegmentsFromTheSameChannelAreJoined() {
    let segments = [
      segment("we should", .me, at: 0, to: 1_000),
      segment("ship it today", .me, at: 1_200, to: 2_000),
    ]
    let joined = MeetingSession.coalesce(segments, gapMilliseconds: 1_500)
    XCTAssertEqual(joined.count, 1)
    XCTAssertEqual(joined[0].text, "we should ship it today")
    XCTAssertEqual(joined[0].endedMilliseconds, 2_000)
  }

  func testSegmentsFromDifferentChannelsAreNeverJoined() {
    let segments = [
      segment("we should", .me, at: 0, to: 1_000),
      segment("ship it today", .them, at: 1_100, to: 2_000),
    ]
    XCTAssertEqual(MeetingSession.coalesce(segments, gapMilliseconds: 1_500).count, 2)
  }

  func testALongSilenceStopsSegmentsBeingJoined() {
    let segments = [
      segment("we should", .me, at: 0, to: 1_000),
      segment("ship it today", .me, at: 30_000, to: 31_000),
    ]
    XCTAssertEqual(MeetingSession.coalesce(segments, gapMilliseconds: 1_500).count, 2)
  }

  func testAMeetingKnowsWhetherItHeardBothSides() {
    var session = MeetingSession()
    session.handle(.start(at: Date()))
    session.handle(.heard(segment("only me", .me, at: 0, to: 500)))
    XCTAssertFalse(session.hasBothChannels)
    session.handle(.heard(segment("and them", .them, at: 600, to: 900)))
    XCTAssertTrue(session.hasBothChannels)
  }

  // MARK: - Capture

  func testTheFixtureCaptureDeliversBothChannelsWithoutHardware() async throws {
    let capture = FixtureMeetingCapture.conversation()
    var channels: [MeetingChannel] = []
    for await chunk in try await capture.start() { channels.append(chunk.channel) }
    XCTAssertEqual(channels, [.me, .them])

    let recording = await capture.stop()
    XCTAssertFalse(recording.me.isEmpty)
    XCTAssertFalse(recording.them.isEmpty)
    XCTAssertEqual(recording.durationMilliseconds, 500)
  }

  func testCancellingCaptureThrowsTheAudioAway() async throws {
    let capture = FixtureMeetingCapture.conversation()
    for await _ in try await capture.start() {}
    await capture.cancel()
    let recording = await capture.stop()
    XCTAssertTrue(recording.isEmpty)
    XCTAssertEqual(capture.cancelCount, 1)
  }

  func testARefusedPermissionSurfacesAsAThrownErrorRatherThanASilentEmptyMeeting() async {
    let capture = FixtureMeetingCapture()
    capture.startError = MeetingCaptureError.screenRecordingPermissionDenied
    do {
      _ = try await capture.start()
      XCTFail("start should have thrown")
    } catch {
      XCTAssertEqual(error as? MeetingCaptureError, .screenRecordingPermissionDenied)
    }
  }

  func testDownsamplingProducesProportionallyFewerSamples() {
    let samples = [Float](repeating: 0.5, count: 48_000)
    let data = MeetingAudioConversion.downsampleToInt16(samples, from: 48_000, to: 16_000)
    XCTAssertEqual(data.count, 16_000 * 2)
    XCTAssertEqual(
      MeetingAudioConversion.milliseconds(ofInt16: data.count, sampleRate: 16_000), 1_000)
  }

  func testLoudSamplesAreClippedRatherThanWrapped() {
    let data = MeetingAudioConversion.int16Data([2, -2])
    let values: [Int16] = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    XCTAssertEqual(values, [32_767, -32_767])
  }

  // MARK: - Store

  func testSavingAMeetingStoresItsSegments() throws {
    let (store, _) = try freshStore()
    let meeting = Meeting(startedAt: Date(), endedAt: Date().addingTimeInterval(600),
                          title: "Roadmap", transcript: "we shipped it")
    let saved = try store.save(meeting, segments: [
      segment("we shipped it", .me, at: 0, to: 1_000),
      segment("about time", .them, at: 1_200, to: 2_000),
    ])
    let id = try XCTUnwrap(saved.id)

    XCTAssertEqual(try store.count(), 1)
    let stored = try store.segments(forMeeting: id)
    XCTAssertEqual(stored.map(\.channel), [.me, .them])
    XCTAssertEqual(stored.first?.meetingID, id)
  }

  func testSavingTheSameMeetingTwiceKeepsOneRowAndOneTranscript() throws {
    let (store, _) = try freshStore()
    let start = Date()
    let segments = [segment("say it once", .me, at: 0, to: 1_000)]
    let first = try store.save(
      Meeting(startedAt: start, transcript: "say it once"), segments: segments)
    let second = try store.save(
      Meeting(startedAt: start, transcript: "say it once"), segments: segments)

    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.segments(forMeeting: XCTUnwrap(first.id)).count, 1)
  }

  func testSearchFindsAMeetingByWhatWasSaidInIt() throws {
    let (store, _) = try freshStore()
    let saved = try store.save(
      Meeting(startedAt: Date(), title: "Ops", transcript: "the artichoke deployment"),
      segments: [segment("the artichoke deployment went out", .them, at: 0, to: 2_000)])

    let results = try store.search("artichoke")
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.meeting.id, saved.id)
    XCTAssertEqual(results.first?.segment.channel, .them)
    XCTAssertTrue(results.first?.snippet.contains("artichoke") ?? false)
  }

  func testSearchSurvivesPunctuationTheUserTypes() throws {
    let (store, _) = try freshStore()
    try store.save(
      Meeting(startedAt: Date(), transcript: "we won't ship on Friday"),
      segments: [segment("we won't ship on Friday", .me, at: 0, to: 2_000)])

    XCTAssertFalse(try store.search("won't").isEmpty)
    XCTAssertTrue(try store.search("???").isEmpty)
  }

  /// Deleting the row is not enough: the FTS index is maintained by a trigger on
  /// `meeting_segments`, so a deletion that reaches only the `meetings` table leaves
  /// the words of the meeting searchable.
  func testDeletingAMeetingAlsoRemovesItFromSearch() throws {
    let (store, _) = try freshStore()
    let saved = try store.save(
      Meeting(startedAt: Date(), transcript: "the artichoke deployment"),
      segments: [segment("the artichoke deployment went out", .them, at: 0, to: 2_000)])

    try store.delete(id: XCTUnwrap(saved.id))
    XCTAssertEqual(try store.count(), 0)
    XCTAssertTrue(try store.search("artichoke").isEmpty)
  }

  func testDeletingEverythingLeavesNothingSearchable() throws {
    let (store, _) = try freshStore()
    try store.save(
      Meeting(startedAt: Date(), transcript: "one"),
      segments: [segment("the artichoke deployment", .me, at: 0)])
    try store.deleteAll()
    XCTAssertTrue(try store.search("artichoke").isEmpty)
  }

  func testASummaryCanBeAttachedAfterTheMeetingIsAlreadySafeOnDisk() throws {
    let (store, _) = try freshStore()
    let saved = try store.save(
      Meeting(startedAt: Date(), transcript: "hello"),
      segments: [segment("hello", .me, at: 0)])
    let id = try XCTUnwrap(saved.id)

    try store.setSummary(
      "We agreed to ship.", actionItems: ["Dan to write the release note"],
      decisions: ["Ship on Friday"], forMeeting: id)

    let reloaded = try XCTUnwrap(store.meeting(id: id))
    XCTAssertEqual(reloaded.summary, "We agreed to ship.")
    XCTAssertEqual(reloaded.actionItems, ["Dan to write the release note"])
    XCTAssertEqual(reloaded.decisions, ["Ship on Friday"])
  }

  func testAnActionItemContainingANewlineSurvivesTheRoundTrip() {
    let items = ["Send the deck,\nthen chase Priya"]
    XCTAssertEqual(MeetingList.decode(MeetingList.encode(items)), items)
  }

  func testAListImportedAsPlainBulletsIsStillReadable() {
    XCTAssertEqual(
      MeetingList.decode("- first\n- second\n\n* third"), ["first", "second", "third"])
  }

  func testAppendingSegmentsToALiveMeetingKeepsThemInTimeOrder() throws {
    let (store, _) = try freshStore()
    let saved = try store.save(
      Meeting(startedAt: Date(), transcript: "start"),
      segments: [segment("start", .me, at: 0, to: 500)])
    let id = try XCTUnwrap(saved.id)
    try store.append([segment("later", .them, at: 5_000, to: 6_000)], toMeeting: id)

    XCTAssertEqual(try store.segments(forMeeting: id).map(\.text), ["start", "later"])
  }

  // MARK: - Summariser

  private var conversation: [MeetingSegment] {
    [
      segment("Morning. How did the deployment go?", .them, at: 0, to: 3_000),
      segment(
        "Fine in the end. I'll write up the release note this afternoon.", .me, at: 3_500,
        to: 8_000),
      segment(
        "Good. We decided to ship on Friday rather than waiting for the redesign.", .them,
        at: 8_500, to: 14_000),
      segment("Can you tell support before then?", .them, at: 14_500, to: 17_000),
      segment("Yes, I'll email them today.", .me, at: 17_500, to: 20_000),
    ]
  }

  func testWithNoEnhancerAtAllTheSummariserStillProducesUsefulNotes() async {
    let summariser = MeetingSummariser(enhancer: nil)
    let summary = await summariser.summarise(
      title: "Deployment", segments: conversation, durationMilliseconds: 20_000)

    XCTAssertTrue(summary.isFallback)
    XCTAssertNil(summary.producedBy)
    XCTAssertFalse(summary.overview.isEmpty)
    XCTAssertFalse(summary.actionItems.isEmpty)
    XCTAssertFalse(summary.decisions.isEmpty)
    XCTAssertFalse(summary.questions.isEmpty)
    XCTAssertFalse(summary.keyMoments.isEmpty)
  }

  func testTheStructuralExtractionKeepsDecisionsOutOfTheActionItems() {
    let decisions = MeetingStructure.decisions(in: conversation)
    let actions = MeetingStructure.actionItems(in: conversation, excluding: Set(decisions))
    XCTAssertTrue(decisions.contains { $0.contains("We decided to ship on Friday") })
    XCTAssertFalse(actions.contains { $0.contains("We decided to ship on Friday") })
    XCTAssertTrue(actions.contains { $0.contains("release note") })
  }

  func testQuestionsAreFoundByPunctuationRatherThanCuePhrases() {
    let questions = MeetingStructure.questions(in: conversation)
    XCTAssertEqual(questions.count, 2)
    XCTAssertTrue(questions.allSatisfy { $0.hasSuffix("?") })
  }

  func testKeyMomentsComeBackInTimeOrder() {
    let moments = MeetingStructure.keyMoments(in: conversation, limit: 3)
    XCTAssertLessThanOrEqual(moments.count, 3)
    XCTAssertEqual(moments.map(\.startedMilliseconds), moments.map(\.startedMilliseconds).sorted())
  }

  func testSentenceSplittingKeepsTheTerminator() {
    XCTAssertEqual(
      MeetingStructure.sentences(in: "One. Two! Three? Four"),
      ["One.", "Two!", "Three?", "Four"])
  }

  func testALocalEnhancerReplacesTheOverviewAndIsNamedOnTheSummary() async {
    let enhancer = StubEnhancer { _ in
      """
      Summary: The deployment landed and the team chose a ship date.

      Action items:
      - Dan to write the release note
      - Dan to email support

      Decisions:
      - Ship on Friday

      Open questions:
      - Does support need a runbook?
      """
    }
    let summariser = MeetingSummariser(enhancer: enhancer)
    let summary = await summariser.summarise(segments: conversation)

    XCTAssertFalse(summary.isFallback)
    XCTAssertEqual(summary.producedBy, "stub")
    XCTAssertFalse(summary.sentTextOffDevice)
    XCTAssertEqual(summary.overview, "The deployment landed and the team chose a ship date.")
    XCTAssertEqual(summary.actionItems, ["Dan to write the release note", "Dan to email support"])
    XCTAssertEqual(summary.decisions, ["Ship on Friday"])
    XCTAssertEqual(summary.questions, ["Does support need a runbook?"])
  }

  func testAnEnhancerThatWouldSendTheTranscriptOffDeviceIsRefusedByDefault() async {
    let cloud = RecordingCloudEnhancer()
    let summariser = MeetingSummariser(enhancer: cloud)
    let summary = await summariser.summarise(segments: conversation)

    XCTAssertTrue(summary.isFallback)
    XCTAssertFalse(summary.sentTextOffDevice)
    XCTAssertEqual(cloud.callCount, 0, "the transcript must not have been sent")
  }

  func testAnOffDeviceEnhancerIsUsedOnlyWhenThePolicySaysSoAndIsRecordedOnTheSummary() async {
    let cloud = RecordingCloudEnhancer()
    let summariser = MeetingSummariser(
      enhancer: cloud, policy: MeetingSummariserPolicy(allowOffDeviceText: true))
    let summary = await summariser.summarise(segments: conversation)

    XCTAssertFalse(summary.isFallback)
    XCTAssertTrue(summary.sentTextOffDevice)
    XCTAssertEqual(cloud.callCount, 1)
  }

  func testAFailingModelLeavesTheStructuralNotesStanding() async {
    let summariser = MeetingSummariser(enhancer: FailingEnhancer())
    let summary = await summariser.summarise(segments: conversation)

    XCTAssertTrue(summary.isFallback)
    XCTAssertFalse(summary.actionItems.isEmpty)
  }

  func testAModelThatRepliesWithNothingUsableDoesNotWipeTheNotes() async {
    let summariser = MeetingSummariser(enhancer: StubEnhancer { _ in "   \n  " })
    let summary = await summariser.summarise(segments: conversation)
    XCTAssertTrue(summary.isFallback)
    XCTAssertFalse(summary.decisions.isEmpty)
  }

  func testAModelThatForgetsASectionKeepsTheOnesWeFoundOurselves() async {
    let summariser = MeetingSummariser(enhancer: StubEnhancer { _ in "Summary: it went well." })
    let summary = await summariser.summarise(segments: conversation)

    XCTAssertEqual(summary.overview, "it went well.")
    XCTAssertFalse(summary.decisions.isEmpty, "the structural decisions should have survived")
  }

  func testTheTranscriptSentToAModelIsTruncatedOnALineBoundary() {
    let text = MeetingStructure.transcript(conversation, labels: .default, limit: 40)
    XCTAssertTrue(text.hasSuffix("[transcript truncated]"))
    XCTAssertFalse(text.contains("release note"))
  }

  func testAnEmptyMeetingSummarisesToAnHonestSentence() async {
    let summary = await MeetingSummariser(enhancer: StubEnhancer()).summarise(segments: [])
    XCTAssertEqual(summary.overview, "Nothing was transcribed.")
    XCTAssertTrue(summary.isFallback)
  }

  // MARK: - Calendar: join links

  func testAZoomLinkIsFoundInTheEventNotes() {
    let event = CalendarEvent(
      id: "1", title: "Roadmap", startDate: Date(), endDate: Date(),
      notes: "Join here: https://acme.zoom.us/j/91234567890?pwd=abc\nDial in otherwise.")
    XCTAssertEqual(event.joinLink?.platform, .zoom)
    XCTAssertEqual(event.joinLink?.url, "https://acme.zoom.us/j/91234567890?pwd=abc")
  }

  func testTheLocationIsPreferredOverTheNotesForAJoinLink() {
    let event = CalendarEvent(
      id: "1", title: "Roadmap", startDate: Date(), endDate: Date(),
      location: "https://meet.google.com/abc-defg-hij",
      notes: "Old link: https://acme.zoom.us/j/1")
    XCTAssertEqual(event.joinLink?.platform, .googleMeet)
  }

  func testATeamsLinkIsRecognised() {
    let links = MeetingLinkExtractor.links(in: "https://teams.microsoft.com/l/meetup-join/xyz")
    XCTAssertEqual(links.first?.platform, .microsoftTeams)
  }

  func testABareHostWithoutASchemeIsStillAJoinLink() {
    let links = MeetingLinkExtractor.links(in: "call me on zoom.us/j/12345 at three")
    XCTAssertEqual(links.first?.url, "https://zoom.us/j/12345")
  }

  func testTrailingPunctuationIsTrimmedFromAPastedLink() {
    let links = MeetingLinkExtractor.links(in: "Use https://meet.google.com/abc-defg-hij.")
    XCTAssertEqual(links.first?.url, "https://meet.google.com/abc-defg-hij")
  }

  func testAngleBracketsFromMailClientsAreStrippedFromALink() {
    let links = MeetingLinkExtractor.links(in: "<https://teams.live.com/meet/99>")
    XCTAssertEqual(links.first?.url, "https://teams.live.com/meet/99")
  }

  func testALookalikeHostIsNotTreatedAsAJoinLink() {
    XCTAssertTrue(MeetingLinkExtractor.links(in: "https://notzoom.us/j/1").isEmpty)
    XCTAssertTrue(MeetingLinkExtractor.links(in: "https://example.com/zoom.us/j/1").isEmpty)
  }

  func testASubdomainedZoomHostIsRecognised() {
    XCTAssertEqual(MeetingLinkExtractor.platform(forHost: "acme.zoom.us"), .zoom)
    XCTAssertEqual(MeetingLinkExtractor.platform(forHost: "zoom.us"), .zoom)
    XCTAssertNil(MeetingLinkExtractor.platform(forHost: "zoom.us.example.com"))
  }

  func testCredentialsAndPortsAreStrippedFromTheHost() {
    XCTAssertEqual(
      MeetingLinkExtractor.host(of: "https://user@acme.zoom.us:443/j/1"), "acme.zoom.us")
  }

  func testTheSameLinkAppearingTwiceIsReportedOnce() {
    let notes = "https://zoom.us/j/5 and again https://zoom.us/j/5"
    XCTAssertEqual(MeetingLinkExtractor.links(in: notes).count, 1)
  }

  /// A calendar invitation can be tens of thousands of characters of pasted mail. The
  /// extractor scans linearly on purpose; this fails loudly if it is ever rewritten
  /// with a pattern that backtracks.
  func testLinkExtractionStaysFastOnAVeryLongInvitation() {
    let notes = String(repeating: "Please do not reply to this message. ", count: 20_000)
      + "https://acme.zoom.us/j/42"
    let started = Date()
    let links = MeetingLinkExtractor.links(in: notes)
    XCTAssertEqual(links.first?.url, "https://acme.zoom.us/j/42")
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  // MARK: - Calendar: matching and vocabulary

  private func event(
    _ id: String, _ title: String, start: TimeInterval, minutes: Double, allDay: Bool = false
  ) -> CalendarEvent {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    return CalendarEvent(
      id: id, title: title, startDate: base.addingTimeInterval(start),
      endDate: base.addingTimeInterval(start + minutes * 60), isAllDay: allDay)
  }

  func testTheEventContainingTheStartTimeIsTheMatch() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [event("a", "Standup", start: 0, minutes: 15),
                  event("b", "Retro", start: 3_600, minutes: 60)]
    let match = CalendarMatcher.event(matching: base.addingTimeInterval(300), in: events)
    XCTAssertEqual(match?.id, "a")
  }

  func testAMeetingStartedJustBeforeTheInviteStillMatchesIt() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [event("a", "Standup", start: 300, minutes: 15)]
    XCTAssertEqual(CalendarMatcher.event(matching: base, in: events)?.id, "a")
  }

  func testAMeetingFarFromAnyInviteMatchesNothing() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [event("a", "Standup", start: 7_200, minutes: 15)]
    XCTAssertNil(CalendarMatcher.event(matching: base, in: events))
  }

  func testAnAllDayEntryNeverMatchesAMeeting() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [event("a", "Focus day", start: -3_600, minutes: 1_440, allDay: true)]
    XCTAssertNil(CalendarMatcher.event(matching: base, in: events))
  }

  /// A stand-up nested inside a day-long block is the meeting you are actually in.
  func testTheShorterEventWinsWhenTwoBothContainTheStart() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [event("long", "Focus block", start: 0, minutes: 480),
                  event("short", "Standup", start: 0, minutes: 15)]
    XCTAssertEqual(CalendarMatcher.event(matching: base.addingTimeInterval(60), in: events)?.id,
                   "short")
  }

  func testTheSuggestedTitleComesFromTheMatchedInvite() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(
      CalendarMatcher.suggestedTitle(
        for: base, events: [event("a", "Roadmap review", start: 0, minutes: 30)]),
      "Roadmap review")
  }

  func testAttendeeNamesBecomeVocabularyForTheTranscriber() {
    let invite = CalendarEvent(
      id: "1", title: "Kubernetes migration sync", startDate: Date(), endDate: Date(),
      attendees: ["Siobhán Ó Braonáin", "Dan Lawson"], organiser: "Priya Raghunathan")
    let words = CalendarMatcher.vocabulary(for: invite)

    XCTAssertTrue(words.contains("Siobhán"))
    XCTAssertTrue(words.contains("Raghunathan"))
    XCTAssertTrue(words.contains("Kubernetes"))
    XCTAssertFalse(words.contains("sync"), "generic meeting words are not vocabulary")
  }

  func testAFixtureCalendarNeedsNoPermissionPromptAndReturnsNothingWhenRefused() async {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let refused = FixtureCalendar(
      events: [event("a", "Standup", start: 0, minutes: 15)], granted: false)
    let granted = await refused.requestAccess()
    XCTAssertFalse(granted)
    let upcoming = await refused.upcomingEvents(within: 3_600, from: base)
    XCTAssertTrue(upcoming.isEmpty)
  }

  func testUpcomingEventsIncludeOneThatHasAlreadyStarted() async {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = FixtureCalendar(events: [event("a", "Standup", start: -120, minutes: 15)])
    let upcoming = await calendar.upcomingEvents(within: 3_600, from: base)
    XCTAssertEqual(upcoming.map(\.id), ["a"])
  }
}

// MARK: - Test doubles

/// An enhancer that claims to send text off the machine, and counts whether it was
/// actually called. The count is the assertion that matters: a policy that refuses
/// the provider but sends the transcript anyway would still look correct from the
/// summary alone.
private final class RecordingCloudEnhancer: EnhancementProvider, @unchecked Sendable {
  let identifier = "cloud"
  let displayName = "Cloud"
  let sendsTextOffDevice = true
  private let lock = NSLock()
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }

  func enhance(_ text: String, instruction: String, context: TranscriptionContext?) async throws
    -> String
  {
    lock.withLock { calls += 1 }
    return "Summary: a cloud model wrote this."
  }

  func isAvailable() async -> Bool { true }
}

private struct FailingEnhancer: EnhancementProvider {
  let identifier = "failing"
  let displayName = "Failing"
  let sendsTextOffDevice = false

  func enhance(_ text: String, instruction: String, context: TranscriptionContext?) async throws
    -> String
  {
    throw TranscriptionError.network("the model died")
  }

  func isAvailable() async -> Bool { true }
}
