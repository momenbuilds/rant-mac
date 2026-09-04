import CryptoKit
import XCTest

@testable import RantCore

/// Migration tests are mostly safety tests.
///
/// The parsers matter, but the promises matter more: Rant reads the folder you chose
/// and nothing else, it never writes to it, a dry run leaves the database untouched,
/// and no file — however truncated, enormous or deliberately hostile — makes the
/// importer crash or hang. Each of those is asserted below rather than assumed.
final class MigrationTests: XCTestCase {

  // MARK: - Fixtures

  private var fixtures: URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/migration")
  }

  private func fixture(_ path: String) -> URL { fixtures.appendingPathComponent(path) }

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rant-migration-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// A writable copy of a fixture, for the tests that need to prove nothing was
  /// written to it.
  private func copiedFixture(_ path: String) throws -> URL {
    let destination = try temporaryDirectory().appendingPathComponent(
      fixture(path).lastPathComponent)
    try FileManager.default.copyItem(at: fixture(path), to: destination)
    return destination
  }

  private func write(_ contents: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func rowCount(_ database: Database, _ table: String) throws -> Int {
    try database.query("SELECT COUNT(*) FROM \(table)") { $0.int(0) }.first ?? 0
  }

  private let allTables = [
    "transcripts", "latency_samples", "meetings", "meeting_segments", "notes",
    "dictionary_entries", "snippets", "styles", "modes", "migration_runs", "migration_items",
    "usage_daily", "app_usage", "learning_candidates", "mcp_audit",
  ]

  // MARK: - Generic parsers

  func testJSONLinesImportsTranscriptsDictionaryEntriesAndSnippets() throws {
    let adapter = JSONLinesAdapter(sink: nil)
    let records = try adapter.parse(fixture("generic/transcripts.jsonl"), options: .preview)
    XCTAssertEqual(records.transcripts.map(\.finalText), [
      "First imported line.", "Second imported line.",
    ])
    XCTAssertEqual(records.dictionary.map(\.written), ["Supabase"])
    XCTAssertEqual(records.snippets.map(\.trigger), ["my address"])
    XCTAssertTrue(records.malformed.isEmpty)
  }

  func testCSVHandlesQuotedCommasAndDoubledQuotes() throws {
    let records = try CSVAdapter(sink: nil).parse(fixture("generic/history.csv"), options: .preview)
    XCTAssertEqual(records.transcripts.map(\.finalText), [
      "Hello, world.", "He said \"ship it\" and left.",
    ])
    XCTAssertEqual(records.transcripts.first?.appName, "Mail")
    XCTAssertEqual(records.transcripts.first?.durationMilliseconds, 1_200)
  }

  /// A row with no text is reported, never salvaged by picking some other column.
  func testACSVRowWithNoTextIsReportedAsUnsupported() throws {
    let records = try CSVAdapter(sink: nil).parse(fixture("generic/history.csv"), options: .preview)
    XCTAssertEqual(records.unsupported.count, 1)
    XCTAssertEqual(records.unsupported[0].reason, "no transcript text")
    XCTAssertEqual(records.unsupported[0].line, 4)
  }

  func testCSVEmbeddedNewlinesStayInsideTheirField() {
    let rows = CSVReader.rows("a,b\n\"one\ntwo\",three\n")
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[1], ["one\ntwo", "three"])
  }

  func testSRTBecomesOneTranscriptWithItsSpeakersKept() throws {
    let records = try SubtitleAdapter(sink: nil).parse(
      fixture("generic/session.srt"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertEqual(
      records.transcripts[0].finalText, "Alice: Let us ship on Friday.\nBob: Agreed.")
    XCTAssertEqual(records.transcripts[0].durationMilliseconds, 5_000)
  }

  func testWebVTTHeadersAreNotMistakenForBrokenCues() throws {
    let records = try SubtitleAdapter(sink: nil).parse(
      fixture("generic/session.vtt"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertEqual(records.transcripts[0].finalText, "The first cue.\nThe second cue.")
    XCTAssertTrue(records.malformed.isEmpty)
  }

  func testMarkdownSplitsOnHeadingsAndTakesTheirDates() throws {
    let records = try MarkdownAdapter(sink: nil).parse(
      fixture("generic/notes.md"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.transcripts[0].finalText, "The first dictated section.")
    XCTAssertEqual(
      records.transcripts[0].createdAt,
      Date(timeIntervalSince1970: 1_706_950_800), "2024-02-03 09:00 UTC")
  }

  /// Splitting a text file on blank lines would shatter one dictation into several,
  /// which is far harder to undo than leaving it whole.
  func testAPlainTextFileIsOneDictationRatherThanOnePerParagraph() throws {
    let records = try PlainTextAdapter(sink: nil).parse(
      fixture("generic/plain.txt"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertTrue(records.transcripts[0].finalText.contains("\n"))
  }

  func testAFolderOfMixedExportsImportsWhatItCanAndNamesTheRest() throws {
    let folder = try temporaryDirectory()
    _ = try write("Just some words.", named: "one.txt", in: folder)
    _ = try write("{\"text\":\"from json lines\"}", named: "two.jsonl", in: folder)
    _ = try write("not a transcript", named: "audio.wav", in: folder)

    let adapter = TranscriptFolderAdapter(sink: nil)
    XCTAssertTrue(adapter.detect(folder))
    let records = try adapter.parse(folder, options: .preview)
    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.unsupported.map(\.file), ["audio.wav"])
  }

  // MARK: - Competitor shapes

  func testWisprFlowKeepsBothTheHeardAndTheFormattedText() throws {
    let adapter = WisprFlowAdapter(sink: nil)
    XCTAssertTrue(adapter.detect(fixture("wispr_flow_export.json")))
    let records = try adapter.parse(fixture("wispr_flow_export.json"), options: .preview)

    XCTAssertEqual(records.transcripts.count, 2)
    let first = records.transcripts[0]
    XCTAssertEqual(first.finalText, "So the API migration is done, I think.")
    XCTAssertEqual(first.rawText, "um so the api migration is done i think")
    XCTAssertEqual(first.appName, "Slack")
    XCTAssertEqual(first.durationMilliseconds, 4_200)
    XCTAssertEqual(first.source, "wispr_flow")
    XCTAssertEqual(first.sourceID, "f1")
  }

  func testAWisprRecordWithNoTextIsCountedNotInvented() throws {
    let records = try WisprFlowAdapter(sink: nil).parse(
      fixture("wispr_flow_export.json"), options: .preview)
    XCTAssertEqual(records.unsupported.count, 1)
    XCTAssertEqual(records.unsupported[0].reason, "no transcript text")
  }

  func testVoiceInkEnhancementBecomesTheFinalTextAndTheOriginalTheRawText() throws {
    let adapter = VoiceInkAdapter(sink: nil)
    XCTAssertTrue(adapter.detect(fixture("voiceink_export.json")))
    let records = try adapter.parse(fixture("voiceink_export.json"), options: .preview)

    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.transcripts[0].finalText, "The build is green.")
    XCTAssertEqual(records.transcripts[0].rawText, "the build is green")
    XCTAssertEqual(records.transcripts[0].provider, "whisper-large-v3")
    XCTAssertEqual(records.transcripts[0].durationMilliseconds, 3_400, "seconds became milliseconds")
    // An un-enhanced recording has one text, which fills both fields.
    XCTAssertEqual(records.transcripts[1].finalText, records.transcripts[1].rawText)
  }

  func testSuperwhisperReadsEveryRecordingFolderAndDatesTheUndatedOnes() throws {
    let adapter = SuperwhisperAdapter(sink: nil)
    XCTAssertTrue(adapter.detect(fixture("superwhisper")))
    let records = try adapter.parse(fixture("superwhisper"), options: .preview)

    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.transcripts.map(\.source), ["superwhisper", "superwhisper"])
    let undated = try XCTUnwrap(records.transcripts.first { $0.finalText.hasPrefix("Book") })
    XCTAssertEqual(
      undated.createdAt, Date(timeIntervalSince1970: 1_709_290_800),
      "the recording folder name is the only timestamp this record has")
  }

  func testOtterConversationsBecomeMeetingsWithSpeakers() throws {
    let adapter = OtterAdapter(sink: nil)
    XCTAssertTrue(adapter.detect(fixture("otter_export.json")))
    let records = try adapter.parse(fixture("otter_export.json"), options: .preview)

    XCTAssertEqual(records.meetings.count, 1)
    let meeting = records.meetings[0]
    XCTAssertEqual(meeting.title, "Weekly sync")
    XCTAssertEqual(meeting.segments.map(\.speaker), ["Alice", "Bob"])
    XCTAssertEqual(meeting.segments.map(\.startedMilliseconds), [0, 4_200])
    XCTAssertEqual(meeting.actionItems, ["Ship the migration", "Update the changelog"])
    XCTAssertEqual(
      meeting.segments.map(\.channel), ["them", "them"],
      "nothing in a conversation export can be claimed as the user's own microphone")
  }

  func testAnOtterConversationWithNoSegmentsIsUnsupportedNotFlattened() throws {
    let records = try OtterAdapter(sink: nil).parse(
      fixture("otter_export.json"), options: .preview)
    XCTAssertEqual(records.unsupported.count, 1)
    XCTAssertEqual(records.unsupported[0].reason, "conversation has no segments")
  }

  // MARK: - Detection

  func testEachExportIsRoutedToTheAdapterThatUnderstandsIt() async throws {
    let runner = MigrationRunner(database: try freshDatabase())
    let expectations: [(String, String)] = [
      ("wispr_flow_export.json", "Wispr Flow"),
      ("voiceink_export.json", "VoiceInk"),
      ("superwhisper", "Superwhisper"),
      ("otter_export.json", "Otter"),
      ("generic/transcripts.jsonl", "JSON Lines"),
      ("generic/history.csv", "CSV"),
      ("generic/session.srt", "Subtitles"),
      ("generic/notes.md", "Markdown"),
      ("generic/plain.txt", "Plain text"),
      ("generic", "Folder of transcripts"),
    ]
    for (path, expected) in expectations {
      let adapter = try await runner.adapter(for: fixture(path))
      XCTAssertEqual(adapter.sourceName, expected, "\(path) was routed to \(adapter.sourceName)")
    }
  }

  /// Detection is structural, so renaming an export must not change the answer.
  func testARenamedExportIsStillRecognised() async throws {
    let folder = try temporaryDirectory()
    let renamed = folder.appendingPathComponent("some-old-backup.json")
    try FileManager.default.copyItem(at: fixture("wispr_flow_export.json"), to: renamed)
    let runner = MigrationRunner(database: try freshDatabase())
    let adapter = try await runner.adapter(for: renamed)
    XCTAssertEqual(adapter.sourceName, "Wispr Flow")
  }

  func testAFolderWithNothingWeUnderstandIsRefusedRatherThanImportedEmpty() async throws {
    let folder = try temporaryDirectory()
    _ = try write("binary-ish", named: "recording.wav", in: folder)
    let runner = MigrationRunner(database: try freshDatabase())
    do {
      _ = try await runner.adapter(for: folder)
      XCTFail("a folder of audio should not match an adapter")
    } catch {
      XCTAssertEqual(error as? MigrationError, .noAdapter(folder.lastPathComponent))
    }
  }

  func testAJSONFileThatIsNotAnExportIsNotClaimedByTheJSONAdapter() throws {
    let folder = try temporaryDirectory()
    let settings = try write("{\"theme\":\"dark\",\"volume\":3}", named: "settings.json", in: folder)
    XCTAssertFalse(JSONAdapter(sink: nil).detect(settings))
  }

  // MARK: - Safety: the source is never touched

  func testAnImportNeverWritesToTheSourceFolder() async throws {
    let source = try copiedFixture("generic")
    let before = try snapshot(of: source)

    let database = try freshDatabase()
    _ = try await MigrationRunner(database: database).run(source)

    XCTAssertEqual(try snapshot(of: source), before, "the source folder was modified by an import")
  }

  func testAPreviewNeverWritesToTheSourceFolder() async throws {
    let source = try copiedFixture("superwhisper")
    let before = try snapshot(of: source)
    _ = try await MigrationRunner(database: try freshDatabase()).preview(source)
    XCTAssertEqual(try snapshot(of: source), before)
  }

  private func snapshot(of directory: URL) throws -> [String] {
    try SourceGuard.files(under: directory).map { url in
      let data = try Data(contentsOf: url)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return "\(url.lastPathComponent)|\(data.count)|\(digest)"
    }.sorted()
  }

  /// A symlink inside the chosen folder must not become a way to read the rest of
  /// the disk.
  func testSymlinksOutOfTheChosenFolderAreNotFollowed() throws {
    let workspace = try temporaryDirectory()
    let outside = workspace.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    _ = try write("a private sentence nobody chose to import", named: "secret.txt", in: outside)

    let chosen = workspace.appendingPathComponent("chosen")
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    _ = try write("the one file that was chosen", named: "real.txt", in: chosen)
    try FileManager.default.createSymbolicLink(
      at: chosen.appendingPathComponent("escape.txt"),
      withDestinationURL: outside.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(
      at: chosen.appendingPathComponent("elsewhere"), withDestinationURL: outside)

    let records = try TranscriptFolderAdapter(sink: nil).parse(chosen, options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertEqual(records.transcripts[0].finalText, "the one file that was chosen")
    for transcript in records.transcripts {
      XCTAssertFalse(transcript.finalText.contains("private sentence"))
    }
  }

  func testCredentialStoresAreRefusedOutright() throws {
    let workspace = try temporaryDirectory()
    for forbidden in ["Library/Keychains", "Library/Cookies", ".ssh"] {
      let directory = workspace.appendingPathComponent(forbidden)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      XCTAssertThrowsError(try SourceGuard.validate(directory), forbidden) { error in
        XCTAssertEqual(error as? MigrationError, .forbiddenLocation(directory.path))
      }
    }
  }

  func testAnotherAppsDatabaseIsListedAsUnsupportedRatherThanOpened() throws {
    let folder = try temporaryDirectory()
    _ = try write("a real transcript", named: "notes.txt", in: folder)
    _ = try write("SQLite format 3", named: "Cookies.binarycookies", in: folder)
    _ = try write("SQLite format 3", named: "login.keychain-db", in: folder)

    let records = try TranscriptFolderAdapter(sink: nil).parse(folder, options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertEqual(
      Set(records.unsupported.map(\.file)), ["Cookies.binarycookies", "login.keychain-db"])
    XCTAssertTrue(records.unsupported.allSatisfy { $0.reason == "unrecognised file type" })
  }

  func testScanningAWholeHomeDirectoryIsRefused() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    XCTAssertThrowsError(try SourceGuard.validate(home)) { error in
      XCTAssertEqual(error as? MigrationError, .sourceTooBroad(home.path))
    }
    XCTAssertThrowsError(try SourceGuard.validate(URL(fileURLWithPath: "/")))
  }

  func testAMissingSourceIsReportedRatherThanScanningSomethingElse() {
    let missing = URL(fileURLWithPath: "/tmp/rant-does-not-exist-\(UUID().uuidString)")
    XCTAssertThrowsError(try SourceGuard.validate(missing)) { error in
      XCTAssertEqual(error as? MigrationError, .sourceMissing(missing.path))
    }
  }

  // MARK: - Safety: the database

  func testDryRunWritesNothingToTheDatabase() async throws {
    let database = try freshDatabase()
    let result = try await MigrationRunner(database: database).run(
      fixture("wispr_flow_export.json"), options: MigrationOptions(dryRun: true))

    XCTAssertTrue(result.dryRun)
    XCTAssertEqual(result.imported, 2, "a dry run still reports what it would do")
    XCTAssertNil(result.runID)
    for table in allTables {
      XCTAssertEqual(try rowCount(database, table), 0, "\(table) was written during a dry run")
    }
  }

  func testImportingTheSameExportTwiceIsANoOp() async throws {
    let database = try freshDatabase()
    let runner = MigrationRunner(database: database)
    let first = try await runner.run(fixture("wispr_flow_export.json"))
    let second = try await runner.run(fixture("wispr_flow_export.json"))

    XCTAssertEqual(first.imported, 2)
    XCTAssertEqual(second.imported, 0)
    XCTAssertEqual(second.duplicatesSkipped, 2)
    XCTAssertEqual(try rowCount(database, "transcripts"), 2)
  }

  func testImportedRowsCarryTheirProvenance() async throws {
    let database = try freshDatabase()
    _ = try await MigrationRunner(database: database).run(fixture("voiceink_export.json"))
    let sources = try database.query("SELECT DISTINCT source FROM transcripts") { $0.string(0) }
    XCTAssertEqual(sources, ["voiceink"])
  }

  func testAnOtterImportStoresTheMeetingAndItsSegments() async throws {
    let database = try freshDatabase()
    let result = try await MigrationRunner(database: database).run(fixture("otter_export.json"))
    XCTAssertEqual(result.imported, 1)
    XCTAssertEqual(result.unsupported, 1)
    XCTAssertEqual(try rowCount(database, "meetings"), 1)
    XCTAssertEqual(try rowCount(database, "meeting_segments"), 2)
  }

  func testEveryRunIsRecordedSoAnImportCanBeInspectedAfterwards() async throws {
    let database = try freshDatabase()
    let runner = MigrationRunner(database: database)
    let result = try await runner.run(fixture("wispr_flow_export.json"))

    let runs = try runner.history()
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].sourceName, "Wispr Flow")
    XCTAssertEqual(runs[0].imported, 2)
    XCTAssertEqual(runs[0].skipped, 1, "the record with no text")
    XCTAssertNotNil(runs[0].finishedAt)

    let items = try runner.items(runID: try XCTUnwrap(result.runID))
    XCTAssertEqual(items.filter { $0.outcome == "imported" }.count, 2)
    XCTAssertEqual(items.filter { $0.outcome == "unsupported" }.count, 1)
    XCTAssertEqual(items.first { $0.outcome == "unsupported" }?.detail, "no transcript text")
  }

  func testTheAuditTrailNamesTheFileButNeverQuotesTheText() async throws {
    let database = try freshDatabase()
    _ = try await MigrationRunner(database: database).run(fixture("wispr_flow_export.json"))
    let rows = try database.query(
      "SELECT COALESCE(detail,'') || '|' || COALESCE(source_ref,'') FROM migration_items"
    ) { $0.string(0) }
    for row in rows {
      XCTAssertFalse(row.contains("API migration"))
      XCTAssertFalse(row.contains("Lunch at one"))
    }
  }

  func testTheAuditLogIsCappedAndSaysSoRatherThanStoppingSilently() async throws {
    let database = try freshDatabase()
    let folder = try temporaryDirectory()
    let lines = (0..<50).map { "{\"text\":\"line \($0)\",\"createdAt\":\(1_700_000_000 + $0)}" }
    _ = try write(lines.joined(separator: "\n"), named: "many.jsonl", in: folder)

    let runner = MigrationRunner(database: database)
    let result = try await runner.run(
      folder.appendingPathComponent("many.jsonl"), options: MigrationOptions(maxAuditItems: 10))
    let items = try runner.items(runID: try XCTUnwrap(result.runID))
    XCTAssertEqual(items.count, 11)
    XCTAssertEqual(items.last?.outcome, "truncated")
    XCTAssertEqual(result.imported, 50, "the run row still carries the true total")
  }

  func testOnlyTheSelectedKindsAreImported() async throws {
    let database = try freshDatabase()
    _ = try await MigrationRunner(database: database).run(
      fixture("generic/transcripts.jsonl"), options: MigrationOptions(importVocabulary: false))
    XCTAssertEqual(try rowCount(database, "transcripts"), 2)
    XCTAssertEqual(try rowCount(database, "dictionary_entries"), 0)
    XCTAssertEqual(try rowCount(database, "snippets"), 0)
  }

  func testTheSinceFilterLeavesOlderHistoryBehind() async throws {
    let database = try freshDatabase()
    let cutoff = Date(timeIntervalSince1970: 1_709_290_000)
    _ = try await MigrationRunner(database: database).run(
      fixture("voiceink_export.json"), options: MigrationOptions(since: cutoff))
    XCTAssertEqual(try rowCount(database, "transcripts"), 1)
  }

  func testThePreviewReportsCountsAndTheDateRangeWithoutImporting() async throws {
    let database = try freshDatabase()
    let preview = try await MigrationRunner(database: database).preview(
      fixture("wispr_flow_export.json"))

    XCTAssertEqual(preview.sourceName, "Wispr Flow")
    XCTAssertEqual(preview.transcripts, 2)
    XCTAssertEqual(preview.unsupported, 1)
    XCTAssertGreaterThan(preview.estimatedBytes, 0)
    XCTAssertEqual(preview.earliest, Date(timeIntervalSince1970: 1_709_284_500))
    XCTAssertNotNil(preview.dateRange)
    XCTAssertEqual(try rowCount(database, "transcripts"), 0)
  }

  func testAnAdapterWithNowhereToWriteRefusesARealImport() async throws {
    do {
      _ = try await WisprFlowAdapter(sink: nil).importData(
        fixture("wispr_flow_export.json"), options: MigrationOptions())
      XCTFail("a parse-only adapter must not claim to have imported anything")
    } catch {
      XCTAssertEqual(error as? MigrationError, .noDestination)
    }
  }

  // MARK: - Hostile input

  func testATruncatedJSONFileIsReportedRatherThanPartlyImported() throws {
    let records = try JSONAdapter(sink: nil).parse(
      fixture("malformed/truncated.json"), options: .preview)
    XCTAssertTrue(records.transcripts.isEmpty)
    XCTAssertEqual(records.malformed.count, 1)
    XCTAssertFalse(JSONAdapter(sink: nil).detect(fixture("malformed/truncated.json")))
  }

  func testOneBadLineInJSONLinesCostsOnlyThatLine() throws {
    let records = try JSONLinesAdapter(sink: nil).parse(
      fixture("malformed/broken.jsonl"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.malformed.count, 2)
    XCTAssertEqual(records.malformed.map(\.line), [2, 3])
    XCTAssertEqual(records.unsupported.count, 1)
  }

  /// Deeply nested JSON overflows the stack inside `JSONSerialization`, so depth is
  /// checked with a flat byte scan before the parser ever sees the file.
  func testDeeplyNestedJSONIsRefusedBeforeItIsParsed() throws {
    XCTAssertFalse(
      SafeJSON.depthIsSafe(try Data(contentsOf: fixture("malformed/deep.json"))))
    let records = try JSONAdapter(sink: nil).parse(
      fixture("malformed/deep.json"), options: .preview)
    XCTAssertTrue(records.transcripts.isEmpty)
    XCTAssertEqual(records.malformed.count, 1)
  }

  func testInvalidUTF8IsRepairedRatherThanLosingTheWholeFile() throws {
    let records = try PlainTextAdapter(sink: nil).parse(
      fixture("malformed/invalid-utf8.txt"), options: .preview)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertTrue(records.transcripts[0].finalText.contains("valid start"))
    XCTAssertTrue(records.transcripts[0].finalText.contains("end"))
  }

  func testAnEnormousSingleLineIsSkippedRatherThanParsed() throws {
    let folder = try temporaryDirectory()
    let enormous = "{\"text\":\"" + String(repeating: "a", count: 6_000_000) + "\"}"
    let url = try write(
      "{\"text\":\"small\"}\n" + enormous + "\n", named: "huge.jsonl", in: folder)

    let started = Date()
    let records = try JSONLinesAdapter(sink: nil).parse(url, options: .preview)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(records.transcripts.count, 1)
    XCTAssertEqual(records.malformed.map(\.reason), ["line too long"])
  }

  func testAFileLargerThanTheCeilingIsRefusedRatherThanTruncated() throws {
    let folder = try temporaryDirectory()
    let url = try write(String(repeating: "x", count: 5_000), named: "big.txt", in: folder)
    let records = try PlainTextAdapter(sink: nil).parse(
      url, options: MigrationOptions(dryRun: true, maxFileBytes: 1_000))
    XCTAssertTrue(records.transcripts.isEmpty)
    XCTAssertEqual(records.unsupported.map(\.reason), ["too large or unreadable"])
  }

  /// A lazy regular expression once hung this codebase for minutes on ordinary
  /// input. Nothing in the parsers uses one, and this is the shape that would prove
  /// it if something crept back in.
  func testPathologicalInputParsesInLinearTime() throws {
    let folder = try temporaryDirectory()
    let nastyCSV = "text,created_at\n"
      + String(repeating: "\"" + String(repeating: "a,\"\"", count: 200) + "\",2024-01-01\n", count: 200)
    let csv = try write(nastyCSV, named: "nasty.csv", in: folder)
    let subtitles = try write(
      String(repeating: "00:00:00,000 --> not a timecode\nsomething\n\n", count: 5_000),
      named: "nasty.srt", in: folder)

    let started = Date()
    _ = try CSVAdapter(sink: nil).parse(csv, options: .preview)
    _ = try SubtitleAdapter(sink: nil).parse(subtitles, options: .preview)
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 10, "a parser is backtracking on hostile input")
  }

  func testAnEmptyFileIsReportedRatherThanImportedAsAnEmptyTranscript() throws {
    let folder = try temporaryDirectory()
    let url = try write("   \n\n", named: "blank.txt", in: folder)
    let records = try PlainTextAdapter(sink: nil).parse(url, options: .preview)
    XCTAssertTrue(records.transcripts.isEmpty)
    XCTAssertEqual(records.unsupported.map(\.reason), ["empty file"])
  }

  // MARK: - Units and dates

  func testTimestampsAreUnderstoodInSecondsMillisecondsAndISOForm() {
    let expected = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(FlexibleDate.parse("1700000000"), expected)
    XCTAssertEqual(FlexibleDate.parse("1700000000000"), expected)
    XCTAssertEqual(FlexibleDate.parse("2023-11-14T22:13:20Z"), expected)
    XCTAssertEqual(FlexibleDate.parse("2023-11-14 22:13:20"), expected)
    XCTAssertNil(FlexibleDate.parse("last Tuesday"))
    XCTAssertNil(FlexibleDate.parse(""))
  }

  func testDurationsAreReadInWhicheverUnitTheExporterMeant() {
    XCTAssertEqual(RecordMapper.milliseconds(FieldMap(["durationMs": 4_200])), 4_200)
    XCTAssertEqual(RecordMapper.milliseconds(FieldMap(["duration": 3.4])), 3_400)
    XCTAssertEqual(RecordMapper.milliseconds(FieldMap(["duration": 120_000])), 120_000)
    XCTAssertEqual(RecordMapper.milliseconds(FieldMap([:])), 0)
  }

  func testFieldNamesAreMatchedWhateverTheirSpelling() {
    let map = FieldMap(["Created At": 1_700_000_000, "final_text": "hello"])
    XCTAssertEqual(map.date(["createdAt"]), Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(map.string(["finalText"]), "hello")
  }
}
