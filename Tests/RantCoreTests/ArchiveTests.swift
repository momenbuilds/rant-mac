import XCTest

@testable import RantCore

/// The archive is the promise that you can always leave, so these tests are written
/// against the promise rather than against the implementation: the layout is plain
/// files, the round trip is lossless, and importing the same archive twice changes
/// nothing.
final class ArchiveTests: XCTestCase {

  // MARK: - Fixtures

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rant-archive-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private let day = Date(timeIntervalSince1970: 1_700_000_000)

  private func populated() throws -> Database {
    let database = try freshDatabase()
    let store = SQLiteTranscriptStore(database: database)
    _ = try store.save(
      Transcript(
        createdAt: day, rawText: "um the build is green", finalText: "The build is green.",
        provider: "assemblyai", language: "en", appBundleID: "com.tinyspeck.slackmacgap",
        appName: "Slack", category: .work, durationMilliseconds: 40_000))
    _ = try store.save(
      Transcript(
        createdAt: day.addingTimeInterval(600), rawText: "lunch at one",
        finalText: "Lunch at one.", provider: "assemblyai", category: .personal,
        durationMilliseconds: 1_500, favourite: true))
    _ = try store.save(
      Transcript(
        createdAt: day.addingTimeInterval(1_200), rawText: "ship it", finalText: "Ship it.",
        provider: "whisper", source: "wispr_flow", sourceID: "f-42"))

    let vocabulary = VocabularyStore(database: database)
    _ = try vocabulary.add(DictionaryEntry(spoken: "super base", written: "Supabase"))
    _ = try vocabulary.add(DictionaryEntry(spoken: "ver sell", written: "Vercel", kind: .boost))
    _ = try vocabulary.add(Snippet(trigger: "my address", expansion: "12 Example Street"))
    _ = try vocabulary.add(Snippet(trigger: "sign off", expansion: "Kind regards,\nDaniel"))

    for (title, body) in [("Groceries", "Milk, bread."), ("Ideas", "A better hotkey.")] {
      let note = ArchiveNote(
        createdAt: day, title: title, body: body, tags: ["personal"], source: "rant")
      try database.run(
        """
        INSERT INTO notes (created_at, updated_at, title, body, pinned, tags, content_hash, source)
        VALUES (?,?,?,?,0,?,?,'rant')
        """,
        [
          SQLValue(note.createdAt), SQLValue(note.updatedAt), .text(note.title), .text(note.body),
          SQLValue(ArchiveCoding.encodeTags(note.tags)), .text(note.contentHash),
        ])
    }

    let segments = [
      ArchiveMeetingSegment(
        startedMilliseconds: 0, endedMilliseconds: 4_200, speaker: "Alice", channel: "them",
        text: "Let us ship on Friday."),
      ArchiveMeetingSegment(
        startedMilliseconds: 4_200, speaker: "Me", channel: "me", text: "Agreed."),
    ]
    let meeting = ArchiveMeeting(
      startedAt: day, endedAt: day.addingTimeInterval(1_800), title: "Weekly sync",
      appName: "Zoom", summary: "We ship on Friday.", actionItems: ["Ship the migration"],
      segments: segments)
    let meetingID = try database.run(
      """
      INSERT INTO meetings
        (started_at, ended_at, title, app_name, summary, action_items, content_hash, source)
      VALUES (?,?,?,?,?,?,?,'rant')
      """,
      [
        SQLValue(meeting.startedAt), SQLValue(meeting.endedAt), SQLValue(meeting.title),
        SQLValue(meeting.appName), SQLValue(meeting.summary),
        SQLValue(ArchiveCoding.encodeTags(meeting.actionItems)), .text(meeting.contentHash),
      ])
    for segment in segments {
      try database.run(
        """
        INSERT INTO meeting_segments (meeting_id, started_ms, ended_ms, speaker, channel, text)
        VALUES (?,?,?,?,?,?)
        """,
        [
          .int(Int(meetingID)), .int(segment.startedMilliseconds),
          SQLValue(segment.endedMilliseconds), SQLValue(segment.speaker), .text(segment.channel),
          .text(segment.text),
        ])
    }
    return database
  }

  private func rowCount(_ database: Database, _ table: String) throws -> Int {
    try database.query("SELECT COUNT(*) FROM \(table)") { $0.int(0) }.first ?? 0
  }

  // MARK: - Layout

  func testExportWritesTheDocumentedLayout() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated(), appVersion: "1.2.3").export(to: directory)

    for name in ["manifest.json", "transcripts.jsonl", "dictionary.json", "snippets.json"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
        "\(name) is missing from the archive")
    }
    XCTAssertEqual(
      SourceGuard.files(under: directory.appendingPathComponent("notes")).count, 2)
    XCTAssertEqual(
      SourceGuard.files(under: directory.appendingPathComponent("meetings")).count, 1)
  }

  func testTheManifestRecordsTheFormatVersionAndTheCounts() throws {
    let directory = try temporaryDirectory()
    let manifest = try RantArchive(database: try populated(), appVersion: "1.2.3")
      .export(to: directory)

    XCTAssertEqual(manifest.format, "rant-archive")
    XCTAssertEqual(manifest.version, RantArchive.formatVersion)
    XCTAssertEqual(manifest.appVersion, "1.2.3")
    XCTAssertEqual(manifest.counts.transcripts, 3)
    XCTAssertEqual(manifest.counts.dictionaryEntries, 2)
    XCTAssertEqual(manifest.counts.snippets, 2)
    XCTAssertEqual(manifest.counts.notes, 2)
    XCTAssertEqual(manifest.counts.meetings, 1)
    let reread = try XCTUnwrap(RantArchive.manifest(at: directory))
    XCTAssertEqual(reread.counts, manifest.counts)
    XCTAssertEqual(reread.version, manifest.version)
    XCTAssertEqual(reread.appVersion, manifest.appVersion)
  }

  /// The point of the format is that Rant is not required to read it.
  func testTheArchiveIsPlainFilesAnybodyCanRead() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)

    let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let manifest = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    XCTAssertEqual(manifest["format"] as? String, "rant-archive")

    let jsonl = try String(
      contentsOf: directory.appendingPathComponent("transcripts.jsonl"), encoding: .utf8)
    let lines = jsonl.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 3, "one JSON object per line, nothing else")
    for line in lines {
      XCTAssertNotNil(
        try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        "every line must stand on its own as JSON")
    }
  }

  func testDatesAreWrittenAsReadableTimestampsRatherThanEpochNumbers() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let jsonl = try String(
      contentsOf: directory.appendingPathComponent("transcripts.jsonl"), encoding: .utf8)
    XCTAssertTrue(jsonl.contains("2023-11-14T"), "expected an ISO 8601 date in \(jsonl.prefix(200))")
  }

  // MARK: - Round trip

  func testExportAndImportRoundTripEverySortOfRecord() throws {
    let source = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: source)

    let restored = try freshDatabase()
    let result = try RantArchive(database: restored).importArchive(from: source)

    XCTAssertEqual(result.imported, 3 + 2 + 2 + 2 + 1)
    XCTAssertEqual(result.duplicatesSkipped, 0)
    XCTAssertEqual(try rowCount(restored, "transcripts"), 3)
    XCTAssertEqual(try rowCount(restored, "dictionary_entries"), 2)
    XCTAssertEqual(try rowCount(restored, "snippets"), 2)
    XCTAssertEqual(try rowCount(restored, "notes"), 2)
    XCTAssertEqual(try rowCount(restored, "meetings"), 1)
    XCTAssertEqual(try rowCount(restored, "meeting_segments"), 2)
  }

  /// The strongest statement of losslessness available: re-exporting a restored
  /// database produces byte-identical files.
  func testARestoredArchiveExportsToTheSameBytes() throws {
    let first = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: first)

    let restored = try freshDatabase()
    try RantArchive(database: restored).importArchive(from: first)
    let second = try temporaryDirectory()
    try RantArchive(database: restored).export(to: second)

    for name in ["transcripts.jsonl", "dictionary.json", "snippets.json"] {
      XCTAssertEqual(
        try Data(contentsOf: first.appendingPathComponent(name)),
        try Data(contentsOf: second.appendingPathComponent(name)),
        "\(name) changed on the round trip")
    }
    for folder in ["notes", "meetings"] {
      let originals = SourceGuard.files(under: first.appendingPathComponent(folder))
      XCTAssertFalse(originals.isEmpty)
      for file in originals {
        let mirror = second.appendingPathComponent(folder)
          .appendingPathComponent(file.lastPathComponent)
        XCTAssertEqual(
          try Data(contentsOf: file), try? Data(contentsOf: mirror),
          "\(folder)/\(file.lastPathComponent) changed on the round trip")
      }
    }
  }

  func testTheDetailOfATranscriptSurvivesTheRoundTrip() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()
    try RantArchive(database: restored).importArchive(from: directory)

    let all = try SQLiteTranscriptStore(database: restored).recent(limit: 10)
    let slack = try XCTUnwrap(all.first { $0.appName == "Slack" })
    XCTAssertEqual(slack.rawText, "um the build is green")
    XCTAssertEqual(slack.finalText, "The build is green.")
    XCTAssertEqual(slack.provider, "assemblyai")
    XCTAssertEqual(slack.language, "en")
    XCTAssertEqual(slack.appBundleID, "com.tinyspeck.slackmacgap")
    XCTAssertEqual(slack.category, .work)
    XCTAssertEqual(slack.durationMilliseconds, 40_000)
    XCTAssertEqual(slack.createdAt.timeIntervalSince1970, day.timeIntervalSince1970, accuracy: 0.001)

    let imported = try XCTUnwrap(all.first { $0.source == "wispr_flow" })
    XCTAssertEqual(
      imported.sourceID, "f-42", "an earlier migration's provenance must survive an archive")
    XCTAssertTrue(all.contains { $0.favourite })
  }

  func testMeetingSegmentsKeepTheirSpeakersAndChannels() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()
    try RantArchive(database: restored).importArchive(from: directory)

    let segments = try restored.query(
      "SELECT speaker, channel, text, started_ms FROM meeting_segments ORDER BY started_ms"
    ) { ($0.string(0), $0.string(1), $0.string(2), $0.int(3)) }
    XCTAssertEqual(segments.map(\.0), ["Alice", "Me"])
    XCTAssertEqual(segments.map(\.1), ["them", "me"])
    XCTAssertEqual(segments.map(\.3), [0, 4_200])
  }

  func testNoteTagsAndMeetingActionItemsSurviveAsLists() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let records = try RantArchive.read(directory)
    XCTAssertEqual(records.notes.first?.tags, ["personal"])
    XCTAssertEqual(records.meetings.first?.actionItems, ["Ship the migration"])
  }

  // MARK: - Idempotence

  func testImportingTheSameArchiveTwiceIsANoOp() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()

    let first = try RantArchive(database: restored).importArchive(from: directory)
    let second = try RantArchive(database: restored).importArchive(from: directory)

    XCTAssertEqual(second.imported, 0, "the second import invented rows")
    XCTAssertEqual(second.duplicatesSkipped, first.imported)
    XCTAssertEqual(try rowCount(restored, "transcripts"), 3)
    XCTAssertEqual(try rowCount(restored, "notes"), 2)
    XCTAssertEqual(try rowCount(restored, "meetings"), 1)
    XCTAssertEqual(try rowCount(restored, "meeting_segments"), 2)
  }

  /// Re-importing must stay a no-op even after the hashing rule changes, which is why
  /// the hash travels inside the archive rather than being recomputed.
  func testTheContentHashTravelsWithTheArchive() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let hashes = try RantArchive.read(directory).transcripts.map(\.contentHash)
    XCTAssertEqual(hashes.count, 3)
    for hash in hashes { XCTAssertEqual(hash.count, 64) }

    let original = try populated()
    let stored = try original.query("SELECT content_hash FROM transcripts ORDER BY created_at") {
      $0.string(0)
    }
    XCTAssertEqual(hashes.sorted(), stored.sorted())
  }

  func testImportingIntoADatabaseThatAlreadyHasTheDataChangesNothing() throws {
    let database = try populated()
    let directory = try temporaryDirectory()
    try RantArchive(database: database).export(to: directory)

    let result = try RantArchive(database: database).importArchive(from: directory)
    XCTAssertEqual(result.imported, 0)
    XCTAssertEqual(try rowCount(database, "transcripts"), 3)
  }

  // MARK: - Versioning and damage

  func testAnArchiveFromANewerRantIsRefusedRatherThanHalfRead() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let manifest = directory.appendingPathComponent("manifest.json")
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: manifest)) as? [String: Any])
    object["version"] = RantArchive.formatVersion + 1
    try JSONSerialization.data(withJSONObject: object).write(to: manifest)

    let records = try RantArchive.read(directory)
    XCTAssertTrue(records.transcripts.isEmpty)
    XCTAssertEqual(records.unsupported.count, 1)
    XCTAssertTrue(records.unsupported[0].reason.contains("newer"))
  }

  func testAFolderWithoutAManifestIsNotAnArchive() throws {
    let directory = try temporaryDirectory()
    try "hello".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    XCTAssertFalse(RantArchive.looksLikeArchive(directory))
    XCTAssertEqual(try RantArchive.read(directory).malformed.count, 1)
  }

  /// The archive is what somebody restores from after losing the original, so one
  /// damaged line must cost one record and not the file.
  func testACorruptedTranscriptLineCostsOnlyThatRecord() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let url = directory.appendingPathComponent("transcripts.jsonl")
    var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    lines[1] = String(lines[1].prefix(30))
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let records = try RantArchive.read(directory)
    XCTAssertEqual(records.transcripts.count, 2)
    XCTAssertEqual(records.malformed.count, 1)
    XCTAssertEqual(records.malformed[0].line, 2)
  }

  func testACorruptedNoteFileCostsOnlyThatNote() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let notes = SourceGuard.files(under: directory.appendingPathComponent("notes"))
    try "{ not json".write(to: notes[0], atomically: true, encoding: .utf8)

    let records = try RantArchive.read(directory)
    XCTAssertEqual(records.notes.count, 1)
    XCTAssertEqual(records.malformed.count, 1)
  }

  /// A truncated archive must never take the process down with it.
  func testAnArchiveOfNothingButOpenBracketsIsRefusedNotParsed() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    try String(repeating: "[", count: 200_000).write(
      to: directory.appendingPathComponent("dictionary.json"), atomically: true, encoding: .utf8)

    let started = Date()
    let records = try RantArchive.read(directory)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "reading an archive should not hang")
    XCTAssertTrue(records.dictionary.isEmpty)
    XCTAssertEqual(records.malformed.count, 1)
  }

  // MARK: - Dry run and audit

  func testADryRunImportOfAnArchiveWritesNothing() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()

    let result = try RantArchive(database: restored).importArchive(
      from: directory, options: MigrationOptions(dryRun: true))

    XCTAssertTrue(result.dryRun)
    XCTAssertEqual(result.imported, 10, "a dry run should still report what it would do")
    XCTAssertNil(result.runID)
    for table in [
      "transcripts", "notes", "meetings", "meeting_segments", "dictionary_entries", "snippets",
      "migration_runs", "migration_items", "usage_daily", "app_usage",
    ] {
      XCTAssertEqual(try rowCount(restored, table), 0, "\(table) was written during a dry run")
    }
  }

  func testAnArchiveRestoreIsRecordedInTheAuditTables() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()
    let result = try RantArchive(database: restored).importArchive(from: directory)

    let runID = try XCTUnwrap(result.runID)
    let runs = try MigrationRunner(database: restored).history()
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].id, runID)
    XCTAssertEqual(runs[0].sourceName, "Rant archive")
    XCTAssertEqual(runs[0].imported, 10)
    XCTAssertFalse(runs[0].dryRun)

    let items = try MigrationRunner(database: restored).items(runID: runID)
    XCTAssertEqual(items.count, 10)
    XCTAssertEqual(Set(items.map(\.outcome)), ["imported"])
    XCTAssertTrue(items.contains { $0.kind == "meeting" })
  }

  /// The audit trail must never become a second copy of the user's transcripts.
  func testTheAuditTrailQuotesNoTranscriptText() throws {
    let directory = try temporaryDirectory()
    try RantArchive(database: try populated()).export(to: directory)
    let restored = try freshDatabase()
    try RantArchive(database: restored).importArchive(from: directory)

    let details = try restored.query(
      "SELECT COALESCE(detail,'') || '|' || COALESCE(source_ref,'') FROM migration_items"
    ) { $0.string(0) }
    for detail in details {
      XCTAssertFalse(detail.contains("The build is green"))
      XCTAssertFalse(detail.contains("Lunch at one"))
    }
  }

  // MARK: - Zip

  func testTheArchiveAlsoTravelsAsASingleZip() throws {
    let workspace = try temporaryDirectory()
    let zip = workspace.appendingPathComponent("rant-archive.zip")
    let manifest = try RantArchive(database: try populated(), appVersion: "9.9.9").exportZip(to: zip)
    XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    XCTAssertEqual(manifest.counts.transcripts, 3)

    let unpacked = try RantArchive.unzip(zip, to: workspace.appendingPathComponent("unpacked"))
    XCTAssertTrue(RantArchive.looksLikeArchive(unpacked))

    let restored = try freshDatabase()
    let result = try RantArchive(database: restored).importArchive(from: unpacked)
    XCTAssertEqual(result.imported, 10)
    XCTAssertEqual(try rowCount(restored, "transcripts"), 3)
  }

  // MARK: - Empty databases

  func testExportingAnEmptyDatabaseProducesAValidEmptyArchive() throws {
    let directory = try temporaryDirectory()
    let manifest = try RantArchive(database: try freshDatabase()).export(to: directory)
    XCTAssertEqual(manifest.counts.transcripts, 0)
    XCTAssertTrue(RantArchive.looksLikeArchive(directory))

    let restored = try freshDatabase()
    let result = try RantArchive(database: restored).importArchive(from: directory)
    XCTAssertEqual(result.imported, 0)
    XCTAssertTrue(result.errors.isEmpty)
  }
}
