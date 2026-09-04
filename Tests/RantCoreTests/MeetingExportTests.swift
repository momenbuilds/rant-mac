import XCTest

@testable import RantCore

/// Export is where a meeting stops being Rant's problem and becomes a file somebody
/// else's software has to read. Subtitle players are unforgiving — a comma where a
/// full stop belongs and the whole file is rejected — so the timestamp formats get
/// their own tests, including the boundaries nobody hits until they do.
final class MeetingExportTests: XCTestCase {

  private let started = Date(timeIntervalSince1970: 1_700_000_000)

  private func segment(
    _ text: String, _ channel: MeetingChannel = .me, at start: Int, to end: Int? = nil,
    speaker: String? = nil
  ) -> MeetingSegment {
    MeetingSegment(
      startedMilliseconds: start, endedMilliseconds: end, speaker: speaker, channel: channel,
      text: text)
  }

  private func meeting(title: String? = "Roadmap review") -> Meeting {
    Meeting(
      startedAt: started, endedAt: started.addingTimeInterval(1_800), title: title,
      appName: "zoom.us", transcript: "roadmap")
  }

  private var segments: [MeetingSegment] {
    [
      segment("Morning, shall we start?", .them, at: 0, to: 2_500),
      segment("Yes. I'll take the notes.", .me, at: 3_000, to: 5_750),
    ]
  }

  // MARK: - Timestamps

  func testSrtTimestampsUseACommaBeforeMilliseconds() {
    XCTAssertEqual(MeetingExport.srtTimestamp(3_661_500), "01:01:01,500")
  }

  func testVttTimestampsUseAFullStopBeforeMilliseconds() {
    XCTAssertEqual(MeetingExport.vttTimestamp(3_661_500), "01:01:01.500")
  }

  func testAZeroTimestampIsStillFullyPadded() {
    XCTAssertEqual(MeetingExport.srtTimestamp(0), "00:00:00,000")
    XCTAssertEqual(MeetingExport.vttTimestamp(0), "00:00:00.000")
  }

  func testASubSecondTimestampKeepsItsMilliseconds() {
    XCTAssertEqual(MeetingExport.srtTimestamp(1), "00:00:00,001")
    XCTAssertEqual(MeetingExport.srtTimestamp(250), "00:00:00,250")
    XCTAssertEqual(MeetingExport.srtTimestamp(999), "00:00:00,999")
  }

  func testATimestampPastOneHourRollsIntoTheHoursField() {
    XCTAssertEqual(MeetingExport.srtTimestamp(3_600_000), "01:00:00,000")
    XCTAssertEqual(MeetingExport.srtTimestamp(3_599_999), "00:59:59,999")
  }

  func testATimestampPastTenHoursIsNotTruncatedToTwoDigits() {
    XCTAssertEqual(MeetingExport.srtTimestamp(36_000_000), "10:00:00,000")
    XCTAssertEqual(MeetingExport.srtTimestamp(360_000_000), "100:00:00,000")
  }

  func testANegativeTimestampIsClampedRatherThanPrintedWithAMinus() {
    XCTAssertEqual(MeetingExport.srtTimestamp(-5), "00:00:00,000")
  }

  func testTheReadableClockDropsTheHoursUntilThereAreSome() {
    XCTAssertEqual(MeetingExport.clock(milliseconds: 65_000), "01:05")
    XCTAssertEqual(MeetingExport.clock(milliseconds: 3_665_000), "01:01:05")
  }

  // MARK: - Cue ends

  func testASegmentWithNoEndTimeIsGivenAnAssumedLength() {
    let end = MeetingExport.cueEnd(for: segment("hello", at: 1_000), next: nil)
    XCTAssertEqual(end, 3_000)
  }

  func testAZeroLengthSegmentIsStretchedIntoAVisibleCue() {
    let end = MeetingExport.cueEnd(for: segment("hello", at: 4_000, to: 4_000), next: nil)
    XCTAssertEqual(end, 5_000)
  }

  func testACueNeverRunsIntoTheNextSpeaker() {
    let end = MeetingExport.cueEnd(
      for: segment("hello", at: 0), next: segment("hi", .them, at: 900))
    XCTAssertEqual(end, 900)
  }

  func testTwoSegmentsStartingOnTheSameMillisecondStillProduceANonEmptyCue() {
    let end = MeetingExport.cueEnd(
      for: segment("hello", at: 5_000, to: 5_000), next: segment("hi", .them, at: 5_000))
    XCTAssertGreaterThan(end, 5_000)
  }

  // MARK: - SRT

  func testSrtNumbersCuesFromOneAndSeparatesThemWithABlankLine() {
    let output = MeetingExport.srt(segments)
    XCTAssertEqual(
      output,
      """
      1
      00:00:00,000 --> 00:00:02,500
      Them: Morning, shall we start?

      2
      00:00:03,000 --> 00:00:05,750
      Me: Yes. I'll take the notes.

      """)
  }

  func testSrtLabelsEachCueWithTheChannelItCameFrom() {
    let output = MeetingExport.srt(segments)
    XCTAssertTrue(output.contains("Them: Morning"))
    XCTAssertTrue(output.contains("Me: Yes."))
  }

  func testSrtUsesADiarisedNameWhenThereIsOne() {
    let output = MeetingExport.srt([segment("Hello", .them, at: 0, to: 500, speaker: "Priya")])
    XCTAssertTrue(output.contains("Priya: Hello"))
  }

  func testSrtOfAnEmptyMeetingIsAnEmptyFileRatherThanAStrayNewline() {
    XCTAssertEqual(MeetingExport.srt([]), "")
  }

  func testSrtRendersASegmentWithNoEndTimeUsingTheAssumedLength() {
    let output = MeetingExport.srt([segment("Hello", at: 0)])
    XCTAssertTrue(output.contains("00:00:00,000 --> 00:00:02,000"))
  }

  // MARK: - VTT

  func testVttStartsWithTheWebvttHeaderAndABlankLine() {
    let output = MeetingExport.vtt(segments)
    XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"))
  }

  func testVttEmitsAHeaderEvenForAMeetingWithNoSegments() {
    XCTAssertEqual(MeetingExport.vtt([]), "WEBVTT\n")
  }

  func testVttCuesAreNotNumberedAndUseTheArrowFormat() {
    let output = MeetingExport.vtt(segments)
    XCTAssertTrue(output.contains("00:00:00.000 --> 00:00:02.500"))
    XCTAssertFalse(output.contains("\n1\n"))
  }

  func testVttAndSrtDifferOnlyInTheirSeparatorAndHeader() {
    let vtt = MeetingExport.vtt(segments)
    let srt = MeetingExport.srt(segments)
    XCTAssertTrue(vtt.contains("00:00:03.000"))
    XCTAssertTrue(srt.contains("00:00:03,000"))
    XCTAssertFalse(vtt.contains("00:00:03,000"))
    XCTAssertFalse(srt.contains("00:00:03.000"))
  }

  func testAMeetingOverAnHourExportsSubtitlesThatKeepTheHoursField() {
    let long = [segment("Still going", .me, at: 3_725_000, to: 3_727_500)]
    XCTAssertTrue(MeetingExport.srt(long).contains("01:02:05,000 --> 01:02:07,500"))
    XCTAssertTrue(MeetingExport.vtt(long).contains("01:02:05.000 --> 01:02:07.500"))
  }

  // MARK: - Markdown and text

  func testMarkdownLeadsWithTheTitleAndTheTranscript() {
    let output = MeetingExport.markdown(meeting: meeting(), segments: segments)
    XCTAssertTrue(output.hasPrefix("# Roadmap review\n"))
    XCTAssertTrue(output.contains("## Transcript"))
    XCTAssertTrue(output.contains("**Them:** Morning, shall we start?"))
  }

  func testMarkdownFallsBackToAPlainTitleWhenTheMeetingHasNone() {
    let output = MeetingExport.markdown(meeting: meeting(title: nil), segments: segments)
    XCTAssertTrue(output.hasPrefix("# Meeting\n"))
  }

  func testMarkdownIncludesTheSummarySectionsThatHaveContent() {
    let summary = MeetingSummary(
      overview: "We agreed a date.", actionItems: ["Dan to write the note"],
      decisions: ["Ship on Friday"], questions: [], producedBy: "ollama", isFallback: false)
    let output = MeetingExport.markdown(meeting: meeting(), segments: segments, summary: summary)

    XCTAssertTrue(output.contains("## Summary"))
    XCTAssertTrue(output.contains("- Dan to write the note"))
    XCTAssertTrue(output.contains("## Decisions"))
    XCTAssertFalse(output.contains("## Open questions"))
  }

  /// The user has to be able to tell "a model summarised this" from "we pulled out
  /// the sentences that looked like commitments", because only one of those is a
  /// summary.
  func testMarkdownSaysWhenTheNotesCameFromNoModelAtAll() {
    let summary = MeetingSummary(overview: "A 30 minute conversation.", isFallback: true)
    let output = MeetingExport.markdown(meeting: meeting(), segments: segments, summary: summary)
    XCTAssertTrue(output.contains("without a language model"))
  }

  func testTimestampsCanBeLeftOutOfTheReadableFormats() {
    let options = MeetingExportOptions(includeTimestamps: false)
    let output = MeetingExport.markdown(meeting: meeting(), segments: segments, options: options)
    XCTAssertFalse(output.contains("`00:00`"))
    XCTAssertTrue(output.contains("**Me:** Yes."))
  }

  func testPlainTextCarriesNoMarkdownMarkers() {
    let output = MeetingExport.plainText(meeting: meeting(), segments: segments)
    XCTAssertFalse(output.contains("**"))
    XCTAssertFalse(output.contains("# "))
    XCTAssertTrue(output.contains("[00:00] Them: Morning, shall we start?"))
  }

  func testCustomSpeakerLabelsReachEveryFormat() {
    let options = MeetingExportOptions(labels: MeetingSpeakerLabels(me: "Dan", them: "Priya"))
    XCTAssertTrue(MeetingExport.srt(segments, options: options).contains("Priya: Morning"))
    XCTAssertTrue(MeetingExport.vtt(segments, options: options).contains("Dan: Yes."))
    XCTAssertTrue(
      MeetingExport.plainText(meeting: meeting(), segments: segments, options: options)
        .contains("Dan: Yes."))
  }

  // MARK: - JSON

  func testJsonRoundTripsBackIntoTheSameSegments() throws {
    let text = try MeetingExport.json(meeting: meeting(), segments: segments)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(
      MeetingExport.Document.self, from: Data(text.utf8))

    XCTAssertEqual(document.formatVersion, 1)
    XCTAssertEqual(document.meeting.title, "Roadmap review")
    XCTAssertEqual(document.meeting.durationMilliseconds, 1_800_000)
    XCTAssertEqual(document.segments, segments)
  }

  func testJsonCarriesTheSummaryIncludingWhetherItLeftTheMachine() throws {
    let summary = MeetingSummary(
      overview: "We agreed a date.", keyMoments: [
        MeetingKeyMoment(startedMilliseconds: 3_000, channel: .me, text: "I'll take the notes.")
      ], producedBy: "cloud", isFallback: false, sentTextOffDevice: true)
    let text = try MeetingExport.json(meeting: meeting(), segments: segments, summary: summary)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(MeetingExport.Document.self, from: Data(text.utf8))

    XCTAssertEqual(document.summary?.sentTextOffDevice, true)
    XCTAssertEqual(document.summary?.keyMoments.first?.channel, .me)
  }

  func testJsonIsStableAcrossRunsSoAnExportCanBeDiffed() throws {
    let first = try MeetingExport.json(meeting: meeting(), segments: segments)
    let second = try MeetingExport.json(meeting: meeting(), segments: segments)
    XCTAssertEqual(first, second)
  }

  func testJsonDoesNotEscapeSlashesInsideALink() throws {
    let text = try MeetingExport.json(
      meeting: meeting(),
      segments: [segment("Join at https://acme.zoom.us/j/1", at: 0, to: 1_000)])
    XCTAssertTrue(text.contains("https://acme.zoom.us/j/1"))
  }

  // MARK: - Dispatch and file names

  func testEveryFormatRendersSomething() throws {
    for format in MeetingExportFormat.allCases {
      let output = try MeetingExport.render(format, meeting: meeting(), segments: segments)
      XCTAssertFalse(output.isEmpty, "\(format.rawValue) rendered nothing")
    }
  }

  func testEveryFormatHasItsOwnExtension() {
    let extensions = MeetingExportFormat.allCases.map(\.fileExtension)
    XCTAssertEqual(Set(extensions).count, extensions.count)
  }

  func testFileNamesSortByDateAndContainNothingAFileSystemDislikes() {
    let name = MeetingExport.fileName(for: meeting(title: "Roadmap / Q4 review!"), format: .markdown)
    XCTAssertTrue(name.hasSuffix("-roadmap-q4-review.md"))
    XCTAssertFalse(name.contains("/"))
  }

  func testAMeetingWithNoTitleStillGetsAUsableFileName() {
    let name = MeetingExport.fileName(for: meeting(title: nil), format: .srt)
    XCTAssertTrue(name.hasSuffix("-meeting.srt"))
  }
}
