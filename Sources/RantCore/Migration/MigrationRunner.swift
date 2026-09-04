import Foundation

/// The one place records reach the database.
///
/// Adapters parse and nothing else. Every insert, every duplicate check and every
/// audit row happens here, so the guarantees the Migration Center makes — idempotent,
/// inspectable, and silent on a dry run — are properties of a single file rather than
/// of a dozen adapters all remembering to behave.
public struct MigrationSink: Sendable {
  private let database: Database
  private let log = RantLog("Migration")

  public init(database: Database) { self.database = database }

  private struct Audit {
    var kind: String
    var outcome: String
    var detail: String?
    var reference: String?
  }

  /// Writes `records`, or — on a dry run — works out what writing them *would* do.
  ///
  /// A dry run issues reads only. It does not open a `migration_runs` row either:
  /// the audit table is where a user goes to find out what an import did to their
  /// database, and filling it with imports that never happened would make it useless
  /// for exactly that.
  public func commit(
    _ records: MigrationRecords, sourceName: String, sourcePath: String,
    options: MigrationOptions
  ) throws -> MigrationResult {
    var result = MigrationResult(
      sourceName: sourceName, malformedSkipped: records.malformed.count,
      unsupported: records.unsupported.count, errors: records.malformed + records.unsupported,
      dryRun: options.dryRun)

    var audits: [Audit] = []
    audits.reserveCapacity(min(options.maxAuditItems, records.count + result.errors.count))
    for issue in records.malformed {
      audits.append(
        Audit(kind: "record", outcome: "malformed", detail: issue.reason, reference: issue.summary))
    }
    for issue in records.unsupported {
      audits.append(
        Audit(
          kind: "record", outcome: "unsupported", detail: issue.reason, reference: issue.summary))
    }

    // MARK: Transcripts

    let transcripts = SQLiteTranscriptStore(database: database)
    for transcript in records.transcripts {
      let duplicate = try exists("transcripts", hash: transcript.contentHash)
      if duplicate {
        result.duplicatesSkipped += 1
      } else {
        if !options.dryRun { _ = try transcripts.save(transcript) }
        result.imported += 1
      }
      audits.append(
        Audit(
          kind: "transcript", outcome: duplicate ? "duplicate" : "imported", detail: nil,
          reference: transcript.sourceID))
    }

    // MARK: Meetings

    for meeting in records.meetings {
      let duplicate = try exists("meetings", hash: meeting.contentHash)
      if duplicate {
        result.duplicatesSkipped += 1
      } else {
        if !options.dryRun { try insert(meeting) }
        result.imported += 1
      }
      audits.append(
        Audit(
          kind: "meeting", outcome: duplicate ? "duplicate" : "imported", detail: nil,
          reference: nil))
    }

    // MARK: Notes

    for note in records.notes {
      let duplicate = try exists("notes", hash: note.contentHash)
      if duplicate {
        result.duplicatesSkipped += 1
      } else {
        if !options.dryRun { try insert(note) }
        result.imported += 1
      }
      audits.append(
        Audit(
          kind: "note", outcome: duplicate ? "duplicate" : "imported", detail: nil, reference: nil))
    }

    // MARK: Vocabulary

    let vocabulary = VocabularyStore(database: database)
    for entry in records.dictionary {
      let spoken = entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
      let duplicate = try (vocabulary.existingEntry(spoken: spoken, kind: entry.kind) != nil)
      var added = false
      if options.dryRun {
        added = !duplicate && !spoken.isEmpty
      } else {
        added = (try? vocabulary.addOrIgnore(entry)) ?? false
      }
      if added { result.imported += 1 } else { result.duplicatesSkipped += 1 }
      audits.append(
        Audit(
          kind: "dictionary", outcome: added ? "imported" : "duplicate", detail: nil,
          reference: nil))
    }

    for snippet in records.snippets {
      let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
      let duplicate = try (vocabulary.existingSnippet(trigger: trigger) != nil)
      var added = false
      if options.dryRun {
        added = !duplicate && !trigger.isEmpty && !snippet.expansion.isEmpty
      } else {
        added = (try? vocabulary.addOrIgnore(snippet)) ?? false
      }
      if added { result.imported += 1 } else { result.duplicatesSkipped += 1 }
      audits.append(
        Audit(
          kind: "snippet", outcome: added ? "imported" : "duplicate", detail: nil, reference: nil))
    }

    guard !options.dryRun else {
      log.info(
        "dry run of \(sourceName): \(result.imported) new, \(result.duplicatesSkipped) already here")
      return result
    }

    let runID = try database.run(
      """
      INSERT INTO migration_runs
        (started_at, finished_at, source_name, source_path, imported, duplicates, skipped, failed,
         dry_run)
      VALUES (?,?,?,?,?,?,?,?,0)
      """,
      [
        SQLValue(Date()), SQLValue(Date()), .text(sourceName), .text(sourcePath),
        .int(result.imported), .int(result.duplicatesSkipped), .int(result.unsupported),
        .int(result.malformedSkipped),
      ])
    result.runID = runID
    try record(audits, runID: runID, limit: options.maxAuditItems)

    log.info(
      "imported from \(sourceName): \(result.imported) new, \(result.duplicatesSkipped) duplicates, "
        + "\(result.malformedSkipped) malformed, \(result.unsupported) unsupported")
    return result
  }

  private func exists(_ table: String, hash: String) throws -> Bool {
    guard !hash.isEmpty else { return false }
    return try database.query(
      "SELECT 1 FROM \(table) WHERE content_hash = ? LIMIT 1", [.text(hash)]
    ) { _ in true }.first ?? false
  }

  private func insert(_ meeting: ArchiveMeeting) throws {
    try database.transaction {
      let id = try database.run(
        """
        INSERT INTO meetings
          (started_at, ended_at, title, app_name, calendar_event_id, summary, action_items,
           decisions, audio_path, content_hash, source)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """,
        [
          SQLValue(meeting.startedAt), SQLValue(meeting.endedAt), SQLValue(meeting.title),
          SQLValue(meeting.appName), SQLValue(meeting.calendarEventID), SQLValue(meeting.summary),
          SQLValue(ArchiveCoding.encodeTags(meeting.actionItems)),
          SQLValue(ArchiveCoding.encodeTags(meeting.decisions)), SQLValue(meeting.audioPath),
          .text(meeting.contentHash), .text(meeting.source),
        ])
      for segment in meeting.segments {
        try database.run(
          """
          INSERT INTO meeting_segments (meeting_id, started_ms, ended_ms, speaker, channel, text)
          VALUES (?,?,?,?,?,?)
          """,
          [
            .int(Int(id)), .int(segment.startedMilliseconds), SQLValue(segment.endedMilliseconds),
            SQLValue(segment.speaker), .text(segment.channel), .text(segment.text),
          ])
      }
    }
  }

  private func insert(_ note: ArchiveNote) throws {
    try database.run(
      """
      INSERT INTO notes (created_at, updated_at, title, body, pinned, tags, content_hash, source)
      VALUES (?,?,?,?,?,?,?,?)
      """,
      [
        SQLValue(note.createdAt), SQLValue(note.updatedAt), .text(note.title), .text(note.body),
        SQLValue(note.pinned), SQLValue(ArchiveCoding.encodeTags(note.tags)),
        .text(note.contentHash), .text(note.source),
      ])
  }

  /// Writes the per-record audit, up to the ceiling, and says so when it stops. A
  /// truncated log that admits it is truncated is inspectable; one that stops
  /// silently is a lie about what happened.
  private func record(_ audits: [Audit], runID: Int64, limit: Int) throws {
    try database.transaction {
      for audit in audits.prefix(limit) {
        try database.run(
          "INSERT INTO migration_items (run_id, kind, outcome, detail, source_ref) VALUES (?,?,?,?,?)",
          [
            .int(Int(runID)), .text(audit.kind), .text(audit.outcome), SQLValue(audit.detail),
            SQLValue(audit.reference),
          ])
      }
      if audits.count > limit {
        try database.run(
          "INSERT INTO migration_items (run_id, kind, outcome, detail, source_ref) VALUES (?,?,?,?,?)",
          [
            .int(Int(runID)), .text("run"), .text("truncated"),
            .text("item log stopped after \(limit) of \(audits.count) records"), .null,
          ])
      }
    }
  }
}

// MARK: - Inspecting past imports

public struct MigrationRunRecord: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var startedAt: Date
  public var finishedAt: Date?
  public var sourceName: String
  public var sourcePath: String
  public var imported: Int
  public var duplicates: Int
  public var skipped: Int
  public var failed: Int
  public var dryRun: Bool
}

public struct MigrationItemRecord: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var runID: Int64
  public var kind: String
  public var outcome: String
  public var detail: String?
  public var sourceReference: String?
}

// MARK: - The Migration Center

/// Picks the adapter, runs it, and keeps the history of what was imported.
///
/// Adapters are ordered from most specific to most generic and the first one that
/// recognises the source wins. That ordering is the whole detection strategy: a
/// Superwhisper recordings folder is also "a folder with JSON files in it", and the
/// adapter that knows what the fields mean should get it before the one that guesses.
public struct MigrationRunner: Sendable {
  private let database: Database
  public let adapters: [any MigrationAdapter]
  private let log = RantLog("Migration")

  public init(database: Database) {
    self.database = database
    self.adapters = MigrationRunner.defaultAdapters(sink: MigrationSink(database: database))
  }

  public init(database: Database, adapters: [any MigrationAdapter]) {
    self.database = database
    self.adapters = adapters
  }

  public static func defaultAdapters(sink: MigrationSink?) -> [any MigrationAdapter] {
    [
      RantArchiveAdapter(sink: sink),
      SuperwhisperAdapter(sink: sink),
      VoiceInkAdapter(sink: sink),
      WisprFlowAdapter(sink: sink),
      OtterAdapter(sink: sink),
      JSONLinesAdapter(sink: sink),
      JSONAdapter(sink: sink),
      CSVAdapter(sink: sink),
      SubtitleAdapter(sink: sink),
      MarkdownAdapter(sink: sink),
      PlainTextAdapter(sink: sink),
      TranscriptFolderAdapter(sink: sink),
    ]
  }

  /// Every adapter that recognises the source, best first. Exposed because the user
  /// is entitled to overrule the guess when their export is unusual.
  public func candidates(for source: URL) async throws -> [any MigrationAdapter] {
    let root = try SourceGuard.validate(source)
    var matches: [any MigrationAdapter] = []
    for adapter in adapters where await adapter.canRead(root) {
      matches.append(adapter)
    }
    return matches
  }

  public func adapter(for source: URL) async throws -> any MigrationAdapter {
    guard let first = try await candidates(for: source).first else {
      throw MigrationError.noAdapter(source.lastPathComponent)
    }
    return first
  }

  public func preview(_ source: URL) async throws -> MigrationPreview {
    try await adapter(for: source).preview(source)
  }

  public func run(_ source: URL, options: MigrationOptions = MigrationOptions()) async throws
    -> MigrationResult
  {
    let adapter = try await adapter(for: source)
    return try await adapter.importData(source, options: options)
  }

  /// Runs a specific adapter, for when the user disagrees with the detection.
  public func run(
    _ source: URL, using adapter: any MigrationAdapter,
    options: MigrationOptions = MigrationOptions()
  ) async throws -> MigrationResult {
    try await adapter.importData(source, options: options)
  }

  // MARK: History

  public func history(limit: Int = 50) throws -> [MigrationRunRecord] {
    try database.query(
      """
      SELECT id, started_at, finished_at, source_name, source_path, imported, duplicates, skipped,
             failed, dry_run
      FROM migration_runs ORDER BY started_at DESC, id DESC LIMIT ?
      """, [.int(limit)]
    ) { row in
      MigrationRunRecord(
        id: Int64(row.int(0)), startedAt: row.date(1), finishedAt: row.dateOrNil(2),
        sourceName: row.string(3), sourcePath: row.string(4), imported: row.int(5),
        duplicates: row.int(6), skipped: row.int(7), failed: row.int(8), dryRun: row.bool(9))
    }
  }

  public func items(runID: Int64, limit: Int = 500) throws -> [MigrationItemRecord] {
    try database.query(
      """
      SELECT id, run_id, kind, outcome, detail, source_ref FROM migration_items
      WHERE run_id = ? ORDER BY id ASC LIMIT ?
      """, [.int(Int(runID)), .int(limit)]
    ) { row in
      MigrationItemRecord(
        id: Int64(row.int(0)), runID: Int64(row.int(1)), kind: row.string(2),
        outcome: row.string(3), detail: row.stringOrNil(4), sourceReference: row.stringOrNil(5))
    }
  }
}
