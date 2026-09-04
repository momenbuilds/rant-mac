import Foundation

/// The Rant Archive: everything Rant knows about you, in a folder you can read
/// without Rant.
///
/// This is the file format behind the promise that you can always leave. It is a
/// plain directory — `manifest.json`, one JSON object per line in
/// `transcripts.jsonl`, `dictionary.json`, `snippets.json`, and a file per note and
/// per meeting — so that `cat`, `jq` and a text editor are sufficient tools. Nothing
/// is compressed by default and nothing is encrypted, because a format you need our
/// software to open is not an escape route.
///
/// Three properties are load-bearing and tested:
///
/// - **Round trip.** Export then import reproduces the same rows, including the
///   content hashes, so an archive is a faithful copy rather than a summary.
/// - **Idempotence.** Importing the same archive twice imports nothing the second
///   time. The hashes travel *with* the archive rather than being recomputed, so
///   this holds even if a later release changes how hashes are derived.
/// - **Versioning.** The manifest carries a format version, and an archive from a
///   newer Rant is refused with an explanation instead of half-read.
public struct RantArchive: Sendable {
  public static let formatVersion = 1
  public static let manifestName = "manifest.json"
  public static let transcriptsName = "transcripts.jsonl"
  public static let dictionaryName = "dictionary.json"
  public static let snippetsName = "snippets.json"
  public static let notesDirectory = "notes"
  public static let meetingsDirectory = "meetings"

  private let database: Database
  private let appVersion: String
  private let log = RantLog("Archive")

  public init(database: Database, appVersion: String = RantArchive.currentAppVersion) {
    self.database = database
    self.appVersion = appVersion
  }

  public static var currentAppVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
  }

  // MARK: - Export

  /// Writes the whole archive into `directory`, creating it if needed.
  @discardableResult
  public func export(to directory: URL) throws -> ArchiveManifest {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try manager.createDirectory(
      at: directory.appendingPathComponent(Self.notesDirectory), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: directory.appendingPathComponent(Self.meetingsDirectory),
      withIntermediateDirectories: true)

    let encoder = ArchiveCoding.encoder()

    let transcripts = try exportedTranscripts()
    var jsonl = Data()
    for record in transcripts {
      jsonl.append(try encoder.encode(record))
      jsonl.append(0x0A)
    }
    try jsonl.write(to: directory.appendingPathComponent(Self.transcriptsName), options: .atomic)

    let dictionary = try exportedDictionary()
    try encoder.encode(dictionary).write(
      to: directory.appendingPathComponent(Self.dictionaryName), options: .atomic)

    let snippets = try exportedSnippets()
    try encoder.encode(snippets).write(
      to: directory.appendingPathComponent(Self.snippetsName), options: .atomic)

    let notes = try exportedNotes()
    for note in notes {
      let name = ArchiveCoding.fileName(for: note.contentHash)
      try encoder.encode(note).write(
        to: directory.appendingPathComponent(Self.notesDirectory).appendingPathComponent(name),
        options: .atomic)
    }

    let meetings = try exportedMeetings()
    for meeting in meetings {
      let name = ArchiveCoding.fileName(for: meeting.contentHash)
      try encoder.encode(meeting).write(
        to: directory.appendingPathComponent(Self.meetingsDirectory).appendingPathComponent(name),
        options: .atomic)
    }

    let manifest = ArchiveManifest(
      format: ArchiveManifest.formatIdentifier,
      version: Self.formatVersion,
      exportedAt: Date(),
      appVersion: appVersion,
      counts: ArchiveManifest.Counts(
        transcripts: transcripts.count, meetings: meetings.count, notes: notes.count,
        dictionaryEntries: dictionary.count, snippets: snippets.count))
    try encoder.encode(manifest).write(
      to: directory.appendingPathComponent(Self.manifestName), options: .atomic)

    log.info(
      "exported archive: \(transcripts.count) transcripts, \(meetings.count) meetings, "
        + "\(notes.count) notes, \(dictionary.count) dictionary entries, "
        + "\(snippets.count) snippets")
    return manifest
  }

  private func exportedTranscripts() throws -> [ArchiveTranscript] {
    try database.query(
      """
      SELECT created_at, raw_text, final_text, provider, language, cleanup_level, mode, style,
             app_bundle_id, app_name, browser_host, category, duration_ms, word_count,
             words_per_minute, enhanced, audio_path, content_hash, source, source_id, favourite
      FROM transcripts ORDER BY created_at ASC, id ASC
      """
    ) { row in
      ArchiveTranscript(
        createdAt: row.date(0), rawText: row.string(1), finalText: row.string(2),
        provider: row.string(3), language: row.stringOrNil(4), cleanupLevel: row.string(5),
        mode: row.stringOrNil(6), style: row.stringOrNil(7), appBundleID: row.stringOrNil(8),
        appName: row.stringOrNil(9), browserHost: row.stringOrNil(10), category: row.string(11),
        durationMilliseconds: row.int(12), wordCount: row.int(13),
        wordsPerMinute: row.intOrNil(14) == nil ? nil : row.double(14), enhanced: row.bool(15),
        audioPath: row.stringOrNil(16), contentHash: row.string(17), source: row.string(18),
        sourceID: row.stringOrNil(19), favourite: row.bool(20))
    }
  }

  private func exportedDictionary() throws -> [DictionaryEntry] {
    try database.query(
      """
      SELECT spoken, written, kind, category, enabled, favourite, case_sensitive, created_at,
             use_count, source
      FROM dictionary_entries ORDER BY spoken COLLATE NOCASE
      """
    ) { row in
      DictionaryEntry(
        spoken: row.string(0), written: row.string(1),
        kind: DictionaryEntry.Kind(rawValue: row.string(2)) ?? .replacement,
        category: row.stringOrNil(3), enabled: row.bool(4), favourite: row.bool(5),
        caseSensitive: row.bool(6), createdAt: row.date(7), useCount: row.int(8),
        source: row.string(9))
    }
  }

  private func exportedSnippets() throws -> [Snippet] {
    try database.query(
      """
      SELECT trigger, expansion, folder, enabled, created_at, use_count, source
      FROM snippets ORDER BY trigger COLLATE NOCASE
      """
    ) { row in
      Snippet(
        trigger: row.string(0), expansion: row.string(1), folder: row.stringOrNil(2),
        enabled: row.bool(3), createdAt: row.date(4), useCount: row.int(5), source: row.string(6))
    }
  }

  private func exportedNotes() throws -> [ArchiveNote] {
    try database.query(
      """
      SELECT created_at, updated_at, title, body, pinned, tags, content_hash, source
      FROM notes ORDER BY created_at ASC, id ASC
      """
    ) { row in
      ArchiveNote(
        createdAt: row.date(0), updatedAt: row.date(1), title: row.string(2), body: row.string(3),
        pinned: row.bool(4), tags: ArchiveCoding.decodeTags(row.stringOrNil(5)),
        contentHash: row.string(6), source: row.string(7))
    }
  }

  private func exportedMeetings() throws -> [ArchiveMeeting] {
    let meetings = try database.query(
      """
      SELECT id, started_at, ended_at, title, app_name, calendar_event_id, summary, action_items,
             decisions, audio_path, content_hash, source
      FROM meetings ORDER BY started_at ASC, id ASC
      """
    ) { row -> (Int, ArchiveMeeting) in
      (
        row.int(0),
        ArchiveMeeting(
          startedAt: row.date(1), endedAt: row.dateOrNil(2), title: row.stringOrNil(3),
          appName: row.stringOrNil(4), calendarEventID: row.stringOrNil(5),
          summary: row.stringOrNil(6), actionItems: ArchiveCoding.decodeTags(row.stringOrNil(7)),
          decisions: ArchiveCoding.decodeTags(row.stringOrNil(8)), audioPath: row.stringOrNil(9),
          contentHash: row.string(10), source: row.string(11), segments: [])
      )
    }

    return try meetings.map { id, meeting in
      var copy = meeting
      copy.segments = try database.query(
        """
        SELECT started_ms, ended_ms, speaker, channel, text FROM meeting_segments
        WHERE meeting_id = ? ORDER BY started_ms ASC, id ASC
        """, [.int(id)]
      ) { row in
        ArchiveMeetingSegment(
          startedMilliseconds: row.int(0), endedMilliseconds: row.intOrNil(1),
          speaker: row.stringOrNil(2), channel: row.string(3), text: row.string(4))
      }
      return copy
    }
  }

  // MARK: - Reading an archive back

  public static func manifest(at directory: URL) -> ArchiveManifest? {
    guard
      let data = try? SourceGuard.data(
        at: directory.appendingPathComponent(manifestName), limit: 1024 * 1024)
    else { return nil }
    return try? ArchiveCoding.decoder().decode(ArchiveManifest.self, from: data)
  }

  /// True when `directory` looks like a Rant archive. Structure, not extension: the
  /// manifest has to say so.
  public static func looksLikeArchive(_ directory: URL) -> Bool {
    guard let manifest = manifest(at: directory) else { return false }
    return manifest.format == ArchiveManifest.formatIdentifier || manifest.version > 0
  }

  /// Parses an archive directory into the neutral record shape.
  ///
  /// Every part is optional and every record is parsed independently, so an archive
  /// with one corrupted note still restores the other nine thousand. That matters
  /// more here than anywhere else in the app: this is the copy someone restores from
  /// after losing the original.
  public static func read(_ directory: URL, options: MigrationOptions = .preview) throws
    -> MigrationRecords
  {
    var records = MigrationRecords()
    guard let manifest = manifest(at: directory) else {
      records.malformed.append(
        MigrationIssue(file: manifestName, reason: "not a Rant archive"))
      return records
    }
    guard manifest.version <= formatVersion else {
      records.unsupported.append(
        MigrationIssue(
          file: manifestName,
          reason: "archive format version \(manifest.version) is newer than this Rant understands"))
      return records
    }
    let decoder = ArchiveCoding.decoder()

    // Transcripts: one object per line, so a single bad line costs one record.
    let transcriptsURL = directory.appendingPathComponent(transcriptsName)
    if FileManager.default.fileExists(atPath: transcriptsURL.path) {
      records.estimatedBytes += SourceGuard.byteCount(of: transcriptsURL)
      let text = try SourceGuard.text(at: transcriptsURL, limit: options.maxFileBytes)
      for line in LineScanner.lines(of: text) {
        if line.tooLong {
          records.malformed.append(
            MigrationIssue(file: transcriptsName, reason: "line too long", line: line.number))
          continue
        }
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let data = Data(trimmed.utf8)
        guard SafeJSON.depthIsSafe(data),
          let record = try? decoder.decode(ArchiveTranscript.self, from: data)
        else {
          records.malformed.append(
            MigrationIssue(file: transcriptsName, reason: "unreadable record", line: line.number))
          continue
        }
        records.transcripts.append(record.transcript)
        if records.transcripts.count >= options.maxRecords { break }
      }
    }

    func decodeArray<T: Decodable>(_ name: String, _ type: T.Type) -> [T] {
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      records.estimatedBytes += SourceGuard.byteCount(of: url)
      guard let data = try? SourceGuard.data(at: url, limit: options.maxFileBytes),
        SafeJSON.depthIsSafe(data), let decoded = try? decoder.decode([T].self, from: data)
      else {
        records.malformed.append(MigrationIssue(file: name, reason: "unreadable record"))
        return []
      }
      return decoded
    }

    records.dictionary = decodeArray(dictionaryName, DictionaryEntry.self)
    records.snippets = decodeArray(snippetsName, Snippet.self)

    for (name, isNote) in [(notesDirectory, true), (meetingsDirectory, false)] {
      let folder = directory.appendingPathComponent(name)
      guard SourceGuard.isDirectory(folder) else { continue }
      for file in SourceGuard.files(under: folder)
      where file.pathExtension.lowercased() == "json" {
        records.estimatedBytes += SourceGuard.byteCount(of: file)
        let reference = "\(name)/\(file.lastPathComponent)"
        guard let data = try? SourceGuard.data(at: file, limit: options.maxFileBytes),
          SafeJSON.depthIsSafe(data)
        else {
          records.malformed.append(MigrationIssue(file: reference, reason: "unreadable record"))
          continue
        }
        if isNote {
          guard let note = try? decoder.decode(ArchiveNote.self, from: data) else {
            records.malformed.append(MigrationIssue(file: reference, reason: "unreadable record"))
            continue
          }
          records.notes.append(note)
        } else {
          guard let meeting = try? decoder.decode(ArchiveMeeting.self, from: data) else {
            records.malformed.append(MigrationIssue(file: reference, reason: "unreadable record"))
            continue
          }
          records.meetings.append(meeting)
        }
      }
    }
    return records
  }

  /// Restores an archive into this database. Safe to run twice; the second run
  /// reports every record as a duplicate and writes nothing.
  @discardableResult
  public func importArchive(from directory: URL, options: MigrationOptions = MigrationOptions())
    throws -> MigrationResult
  {
    let root = try SourceGuard.validate(directory)
    let records = try Self.read(root, options: options).filtered(by: options)
    let sink = MigrationSink(database: database)
    return try sink.commit(
      records, sourceName: "Rant archive", sourcePath: root.path, options: options)
  }

  // MARK: - Zip

  /// The same folder, as a single file to hand to someone or drop in a backup.
  ///
  /// `ditto` rather than a bundled zip library: it ships with macOS, it is the tool
  /// Finder's "Compress" uses, and one fewer dependency in the code that handles
  /// the user's entire history is worth an exec.
  @discardableResult
  public func exportZip(to zipURL: URL) throws -> ArchiveManifest {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("rant-archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: staging) }
    let manifest = try export(to: staging)
    try FileManager.default.createDirectory(
      at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: zipURL)
    try Self.ditto(["-c", "-k", "--sequesterRsrc", staging.path, zipURL.path])
    return manifest
  }

  /// Unpacks an archive zip into `directory` and returns the folder holding the
  /// manifest — which may be a level down, since zips are habitually made with a
  /// wrapping folder.
  @discardableResult
  public static func unzip(_ zipURL: URL, to directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ditto(["-x", "-k", zipURL.path, directory.path])
    if looksLikeArchive(directory) { return directory }
    for child in (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    where SourceGuard.isDirectory(child) && looksLikeArchive(child) {
      return child
    }
    return directory
  }

  private static func ditto(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MigrationError.unreadable(arguments.last ?? "archive")
    }
  }
}

// MARK: - The records on disk

public struct ArchiveManifest: Codable, Sendable, Equatable {
  public static let formatIdentifier = "rant-archive"

  public struct Counts: Codable, Sendable, Equatable {
    public var transcripts: Int
    public var meetings: Int
    public var notes: Int
    public var dictionaryEntries: Int
    public var snippets: Int

    public init(
      transcripts: Int = 0, meetings: Int = 0, notes: Int = 0, dictionaryEntries: Int = 0,
      snippets: Int = 0
    ) {
      self.transcripts = transcripts
      self.meetings = meetings
      self.notes = notes
      self.dictionaryEntries = dictionaryEntries
      self.snippets = snippets
    }
  }

  public var format: String
  public var version: Int
  public var exportedAt: Date
  public var appVersion: String
  public var counts: Counts

  public init(
    format: String = ArchiveManifest.formatIdentifier, version: Int = RantArchive.formatVersion,
    exportedAt: Date = Date(), appVersion: String = "0.0.0", counts: Counts = Counts()
  ) {
    self.format = format
    self.version = version
    self.exportedAt = exportedAt
    self.appVersion = appVersion
    self.counts = counts
  }
}

/// One dictation, as it appears in `transcripts.jsonl`.
///
/// Deliberately a separate type from `Transcript`: the archive is a published file
/// format that other tools read, and it must not change shape every time an internal
/// struct gains a field. Enumerations travel as their raw strings for the same
/// reason — an unknown value degrades to the default rather than failing the record.
public struct ArchiveTranscript: Codable, Sendable, Equatable {
  public var createdAt: Date
  public var rawText: String
  public var finalText: String
  public var provider: String
  public var language: String?
  public var cleanupLevel: String
  public var mode: String?
  public var style: String?
  public var appBundleID: String?
  public var appName: String?
  public var browserHost: String?
  public var category: String
  public var durationMilliseconds: Int
  public var wordCount: Int
  public var wordsPerMinute: Double?
  public var enhanced: Bool
  public var audioPath: String?
  public var contentHash: String
  public var source: String
  public var sourceID: String?
  public var favourite: Bool

  public init(
    createdAt: Date, rawText: String, finalText: String, provider: String, language: String? = nil,
    cleanupLevel: String = "medium", mode: String? = nil, style: String? = nil,
    appBundleID: String? = nil, appName: String? = nil, browserHost: String? = nil,
    category: String = "other", durationMilliseconds: Int = 0, wordCount: Int = 0,
    wordsPerMinute: Double? = nil, enhanced: Bool = false, audioPath: String? = nil,
    contentHash: String, source: String = "rant", sourceID: String? = nil, favourite: Bool = false
  ) {
    self.createdAt = createdAt
    self.rawText = rawText
    self.finalText = finalText
    self.provider = provider
    self.language = language
    self.cleanupLevel = cleanupLevel
    self.mode = mode
    self.style = style
    self.appBundleID = appBundleID
    self.appName = appName
    self.browserHost = browserHost
    self.category = category
    self.durationMilliseconds = durationMilliseconds
    self.wordCount = wordCount
    self.wordsPerMinute = wordsPerMinute
    self.enhanced = enhanced
    self.audioPath = audioPath
    self.contentHash = contentHash
    self.source = source
    self.sourceID = sourceID
    self.favourite = favourite
  }

  public init(_ transcript: Transcript) {
    self.init(
      createdAt: transcript.createdAt, rawText: transcript.rawText,
      finalText: transcript.finalText, provider: transcript.provider,
      language: transcript.language, cleanupLevel: transcript.cleanupLevel.rawValue,
      mode: transcript.mode, style: transcript.style, appBundleID: transcript.appBundleID,
      appName: transcript.appName, browserHost: transcript.browserHost,
      category: transcript.category.rawValue,
      durationMilliseconds: transcript.durationMilliseconds, wordCount: transcript.wordCount,
      wordsPerMinute: transcript.wordsPerMinute, enhanced: transcript.enhanced,
      audioPath: transcript.audioPath, contentHash: transcript.contentHash,
      source: transcript.source, sourceID: transcript.sourceID, favourite: transcript.favourite)
  }

  /// The hash travels with the record rather than being recomputed on import, so an
  /// archive stays idempotent across a release that changes how hashes are derived.
  public var transcript: Transcript {
    Transcript(
      createdAt: createdAt, rawText: rawText, finalText: finalText, provider: provider,
      language: language, cleanupLevel: CleanupLevel(rawValue: cleanupLevel) ?? .medium,
      mode: mode, style: style, appBundleID: appBundleID, appName: appName,
      browserHost: browserHost, category: UsageCategory(rawValue: category) ?? .other,
      durationMilliseconds: durationMilliseconds, wordCount: wordCount,
      wordsPerMinute: wordsPerMinute, enhanced: enhanced, audioPath: audioPath,
      contentHash: contentHash.isEmpty ? nil : contentHash, source: source, sourceID: sourceID,
      favourite: favourite)
  }
}

public struct ArchiveNote: Codable, Sendable, Equatable {
  public var createdAt: Date
  public var updatedAt: Date
  public var title: String
  public var body: String
  public var pinned: Bool
  public var tags: [String]
  public var contentHash: String
  public var source: String

  public init(
    createdAt: Date, updatedAt: Date? = nil, title: String = "", body: String = "",
    pinned: Bool = false, tags: [String] = [], contentHash: String? = nil, source: String = "rant"
  ) {
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.title = title
    self.body = body
    self.pinned = pinned
    self.tags = tags
    self.source = source
    self.contentHash =
      contentHash
      ?? Transcript.hash(text: "\(title)\n\(body)", createdAt: createdAt, source: source)
  }
}

public struct ArchiveMeetingSegment: Codable, Sendable, Equatable {
  public var startedMilliseconds: Int
  public var endedMilliseconds: Int?
  public var speaker: String?
  /// `me` for the microphone, `them` for system audio — the distinction the notetaker
  /// can always make, unlike diarisation.
  public var channel: String
  public var text: String

  public init(
    startedMilliseconds: Int, endedMilliseconds: Int? = nil, speaker: String? = nil,
    channel: String = "me", text: String
  ) {
    self.startedMilliseconds = startedMilliseconds
    self.endedMilliseconds = endedMilliseconds
    self.speaker = speaker
    self.channel = channel
    self.text = text
  }
}

public struct ArchiveMeeting: Codable, Sendable, Equatable {
  public var startedAt: Date
  public var endedAt: Date?
  public var title: String?
  public var appName: String?
  public var calendarEventID: String?
  public var summary: String?
  public var actionItems: [String]
  public var decisions: [String]
  public var audioPath: String?
  public var contentHash: String
  public var source: String
  public var segments: [ArchiveMeetingSegment]

  public init(
    startedAt: Date, endedAt: Date? = nil, title: String? = nil, appName: String? = nil,
    calendarEventID: String? = nil, summary: String? = nil, actionItems: [String] = [],
    decisions: [String] = [], audioPath: String? = nil, contentHash: String? = nil,
    source: String = "rant", segments: [ArchiveMeetingSegment] = []
  ) {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.title = title
    self.appName = appName
    self.calendarEventID = calendarEventID
    self.summary = summary
    self.actionItems = actionItems
    self.decisions = decisions
    self.audioPath = audioPath
    self.source = source
    self.segments = segments
    self.contentHash =
      contentHash
      ?? ArchiveMeeting.hash(
        title: title, segments: segments, startedAt: startedAt, source: source)
  }

  /// A meeting's identity is its title plus what was said in it, not its row id —
  /// otherwise re-importing the same export creates a second copy of the meeting.
  public static func hash(
    title: String?, segments: [ArchiveMeetingSegment], startedAt: Date, source: String
  ) -> String {
    let body = ([title ?? ""] + segments.map(\.text)).joined(separator: "\n")
    return Transcript.hash(text: body, createdAt: startedAt, source: source)
  }
}

// MARK: - Coding

/// One encoder configuration for the whole format.
enum ArchiveCoding {
  nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let lock = NSLock()

  /// Dates are written as ISO 8601 strings rather than epoch numbers, because the
  /// archive is meant to be read by a human with a text editor and `1700000000` is
  /// not a date to anyone. They are *read* through `FlexibleDate`, so an archive
  /// hand-edited into a different but sane format still restores.
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(lock.withLock { isoFormatter.string(from: date) })
    }
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let text = try? container.decode(String.self), let date = FlexibleDate.parse(text) {
        return date
      }
      if let seconds = try? container.decode(Double.self),
        let date = FlexibleDate.fromEpoch(seconds)
      {
        return date
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "unreadable date")
    }
    return decoder
  }

  /// Content-addressed file names: stable across exports, so a diff of two archives
  /// shows what actually changed rather than everything renumbering.
  static func fileName(for hash: String) -> String {
    let safe = hash.filter { $0.isHexDigit }
    return (safe.isEmpty ? UUID().uuidString : String(safe.prefix(64))) + ".json"
  }

  /// The list columns (`tags`, `action_items`, `decisions`) hold JSON arrays, but
  /// older rows and hand-edited databases hold a comma-separated string. Both read.
  static func decodeTags(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    if let data = raw.data(using: .utf8), let array = SafeJSON.object(from: data) as? [Any] {
      return array.compactMap { $0 as? String }
    }
    return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  static func encodeTags(_ values: [String]) -> String? {
    guard !values.isEmpty else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: values) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
