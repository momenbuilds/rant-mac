import Foundation

/// Turning an arbitrary JSON object into a record, without inventing anything.
///
/// Every dictation exporter picks its own names for the same four ideas: the text,
/// when it happened, how long it took and which app it went into. Rather than one
/// adapter per spelling, the field names are listed here and looked up
/// case-insensitively. A record with no recognisable text is reported as unsupported
/// — never salvaged by picking the longest string in the object, which is how an
/// importer ends up filling someone's history with file paths.
public enum RecordMapper {
  /// Order is the whole trick. Where an exporter kept both a recogniser output and a
  /// tidied version, the tidied one is what was actually inserted and therefore what
  /// Rant calls the final text — so the polished names come first here, and the plain
  /// `text` appears in *both* lists so that a record carrying only `text` still fills
  /// both fields rather than losing one.
  static let textKeys = [
    "finalText", "formattedText", "enhancedText", "cleanedText", "transcript", "transcription",
    "result", "text", "content", "body", "message", "output",
  ]
  static let rawTextKeys = [
    "rawText", "asrText", "rawResult", "originalText", "unformattedText", "original", "text",
    "input",
  ]
  static let dateKeys = [
    "createdAt", "timestamp", "datetime", "date", "recordedAt", "startTime", "start", "time",
    "when", "updatedAt",
  ]
  static let appKeys = ["appName", "app", "application", "target", "destination"]
  static let bundleKeys = ["appBundleId", "bundleId", "bundleIdentifier"]
  static let millisecondKeys = ["durationMs", "durationMilliseconds", "elapsedMs", "lengthMs"]
  static let secondKeys = ["duration", "durationSeconds", "elapsed", "length", "seconds"]
  static let languageKeys = ["language", "languageCode", "locale", "lang"]
  static let providerKeys = ["provider", "modelName", "transcriptionModelName", "model", "engine"]
  static let identifierKeys = ["id", "uuid", "identifier", "recordingId", "speechId"]

  public enum Mapped {
    case transcript(Transcript)
    case dictionary(DictionaryEntry)
    case snippet(Snippet)
    case unsupported(String)
  }

  /// Duration, in whichever unit the exporter meant.
  ///
  /// A key spelled `durationMs` is milliseconds and a key spelled `duration` is
  /// seconds, except when it is not — so a bare `duration` over a day's worth of
  /// seconds is read as milliseconds instead. Getting this wrong only distorts the
  /// words-per-minute figure, which is why it is a heuristic rather than a rejection.
  static func milliseconds(_ map: FieldMap) -> Int {
    if let value = map.double(millisecondKeys) { return max(0, Int(value)) }
    guard let value = map.double(secondKeys), value.isFinite, value > 0 else { return 0 }
    return value > 86_400 ? Int(value) : Int(value * 1_000)
  }

  public static func map(
    _ object: [String: Any], source: String, provider: String, fallbackDate: Date
  ) -> Mapped {
    let map = FieldMap(object)

    // Vocabulary records travel in the same exports and are unmistakable.
    if let spoken = map.string(["spoken", "from", "phrase"]),
      let written = map.string(["written", "to", "replacement"])
    {
      return .dictionary(
        DictionaryEntry(
          spoken: spoken, written: written,
          kind: DictionaryEntry.Kind(rawValue: map.string(["kind", "type"]) ?? "") ?? .replacement,
          category: map.string(["category", "folder"]),
          enabled: map.bool(["enabled", "active"]) ?? true,
          createdAt: map.date(dateKeys) ?? fallbackDate, source: source))
    }
    if let trigger = map.string(["trigger", "shortcut", "abbreviation"]),
      let expansion = map.string(["expansion", "snippet", "replacement", "text"])
    {
      return .snippet(
        Snippet(
          trigger: trigger, expansion: expansion, folder: map.string(["folder", "group"]),
          enabled: map.bool(["enabled", "active"]) ?? true,
          createdAt: map.date(dateKeys) ?? fallbackDate, source: source))
    }

    guard let final = map.string(textKeys)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !final.isEmpty
    else {
      return .unsupported("no transcript text")
    }
    let raw = map.string(rawTextKeys) ?? final
    let created = map.date(dateKeys) ?? fallbackDate
    return .transcript(
      Transcript(
        createdAt: created, rawText: raw, finalText: final,
        provider: map.string(providerKeys) ?? provider, language: map.string(languageKeys),
        appBundleID: map.string(bundleKeys), appName: map.string(appKeys),
        durationMilliseconds: milliseconds(map),
        enhanced: map.bool(["enhanced", "formatted", "aiEnhanced"]) ?? false, source: source,
        sourceID: map.string(identifierKeys)))
  }
}

/// The file parsers the generic adapters and the folder adapter share.
public enum GenericParsers {
  public static let textExtensions: Set<String> = ["txt", "text", "log"]
  public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
  public static let jsonExtensions: Set<String> = ["json"]
  public static let jsonLinesExtensions: Set<String> = ["jsonl", "ndjson"]
  public static let separatedExtensions: Set<String> = ["csv", "tsv"]
  public static let subtitleExtensions: Set<String> = ["srt", "vtt", "webvtt"]

  public static var allExtensions: Set<String> {
    textExtensions.union(markdownExtensions).union(jsonExtensions).union(jsonLinesExtensions)
      .union(separatedExtensions).union(subtitleExtensions)
  }

  /// Reads a file, or turns the reason it could not be read into a record of that.
  /// Nothing here throws: one oversized file in a folder of ten thousand must not
  /// abandon the other nine thousand nine hundred and ninety-nine.
  static func read(_ url: URL, options: MigrationOptions) -> (text: String?, records: MigrationRecords) {
    var records = MigrationRecords()
    records.estimatedBytes = SourceGuard.byteCount(of: url)
    do {
      return (try SourceGuard.text(at: url, limit: options.maxFileBytes), records)
    } catch {
      records.unsupported.append(
        MigrationIssue(file: url.lastPathComponent, reason: "too large or unreadable"))
      return (nil, records)
    }
  }

  /// A plain text file is one dictation. Splitting on blank lines was tempting and
  /// wrong: paragraphs inside a single dictation are common, and an importer that
  /// shatters one transcript into nine is harder to undo than one that keeps it
  /// whole.
  public static func plainText(_ url: URL, options: MigrationOptions, source: String)
    -> MigrationRecords
  {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      records.unsupported.append(MigrationIssue(file: url.lastPathComponent, reason: "empty file"))
      return records
    }
    records.transcripts.append(
      Transcript(
        createdAt: SourceGuard.modificationDate(of: url), rawText: body, finalText: body,
        provider: "import", source: source, sourceID: url.lastPathComponent))
    return records
  }

  /// Markdown split on its top-level headings, because a "transcripts.md" export is
  /// almost always one heading per dictation with the date in the heading.
  public static func markdown(_ url: URL, options: MigrationOptions, source: String)
    -> MigrationRecords
  {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    let fallback = SourceGuard.modificationDate(of: url)

    var sections: [(heading: String?, body: [String])] = []
    var current: (heading: String?, body: [String]) = (nil, [])
    for line in LineScanner.lines(of: text) {
      guard !line.tooLong else {
        records.malformed.append(
          MigrationIssue(file: url.lastPathComponent, reason: "line too long", line: line.number))
        continue
      }
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      let isHeading = trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ")
      if isHeading {
        if current.heading != nil || !current.body.isEmpty { sections.append(current) }
        current = (trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), [])
      } else {
        current.body.append(line.text)
      }
    }
    if current.heading != nil || !current.body.isEmpty { sections.append(current) }

    for section in sections {
      let body = section.body.joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      let created = section.heading.flatMap { FlexibleDate.parse($0) } ?? fallback
      records.transcripts.append(
        Transcript(
          createdAt: created, rawText: body, finalText: body, provider: "import", source: source,
          sourceID: url.lastPathComponent))
    }
    if records.transcripts.isEmpty && records.malformed.isEmpty {
      records.unsupported.append(MigrationIssue(file: url.lastPathComponent, reason: "empty file"))
    }
    return records
  }

  public static func json(_ url: URL, options: MigrationOptions, source: String, provider: String)
    -> MigrationRecords
  {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    guard let value = SafeJSON.object(from: text) else {
      records.malformed.append(
        MigrationIssue(file: url.lastPathComponent, reason: "not valid or too deeply nested JSON"))
      return records
    }
    guard let objects = SafeJSON.records(in: value) else {
      records.unsupported.append(
        MigrationIssue(file: url.lastPathComponent, reason: "no array of records found"))
      return records
    }
    let fallback = SourceGuard.modificationDate(of: url)
    for object in objects.prefix(options.maxRecords) {
      append(
        RecordMapper.map(object, source: source, provider: provider, fallbackDate: fallback),
        to: &records, file: url.lastPathComponent, line: nil)
    }
    return records
  }

  public static func jsonLines(
    _ url: URL, options: MigrationOptions, source: String, provider: String
  ) -> MigrationRecords {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    let fallback = SourceGuard.modificationDate(of: url)
    for line in LineScanner.lines(of: text) {
      if records.count >= options.maxRecords { break }
      if line.tooLong {
        records.malformed.append(
          MigrationIssue(file: url.lastPathComponent, reason: "line too long", line: line.number))
        continue
      }
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      guard let object = SafeJSON.object(from: trimmed) as? [String: Any] else {
        records.malformed.append(
          MigrationIssue(file: url.lastPathComponent, reason: "unreadable record", line: line.number)
        )
        continue
      }
      append(
        RecordMapper.map(object, source: source, provider: provider, fallbackDate: fallback),
        to: &records, file: url.lastPathComponent, line: line.number)
    }
    return records
  }

  public static func separatedValues(
    _ url: URL, options: MigrationOptions, source: String, provider: String
  ) -> MigrationRecords {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    let separator: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
    guard let table = CSVReader.table(text, separator: separator) else {
      records.malformed.append(
        MigrationIssue(file: url.lastPathComponent, reason: "no header row"))
      return records
    }
    let fallback = SourceGuard.modificationDate(of: url)
    for (offset, row) in table.rows.prefix(options.maxRecords).enumerated() {
      // Rebuilding each row as an object means the CSV and JSON paths share one set
      // of field-name rules, rather than drifting apart over time.
      var object: [String: Any] = [:]
      for (index, name) in table.header.enumerated() where index < row.count {
        object[name] = row[index]
      }
      append(
        RecordMapper.map(object, source: source, provider: provider, fallbackDate: fallback),
        to: &records, file: url.lastPathComponent, line: offset + 2)
    }
    return records
  }

  /// A subtitle file is one recording, so its cues become one transcript rather than
  /// one per line. Speaker labels are kept inline because dropping them would lose
  /// the only thing an SRT knows that a text file does not.
  public static func subtitles(_ url: URL, options: MigrationOptions, source: String)
    -> MigrationRecords
  {
    var (text, records) = read(url, options: options)
    guard let text else { return records }
    let parsed = SubtitleReader.cues(text)
    for _ in 0..<parsed.skipped {
      records.malformed.append(
        MigrationIssue(file: url.lastPathComponent, reason: "unreadable cue"))
    }
    guard !parsed.cues.isEmpty else {
      if records.malformed.isEmpty {
        records.unsupported.append(
          MigrationIssue(file: url.lastPathComponent, reason: "no subtitle cues"))
      }
      return records
    }
    let body = parsed.cues.map { cue in
      cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text
    }.joined(separator: "\n")
    let duration = Int((parsed.cues.last?.endSeconds ?? 0) * 1_000)
    records.transcripts.append(
      Transcript(
        createdAt: SourceGuard.modificationDate(of: url), rawText: body, finalText: body,
        provider: "import", durationMilliseconds: max(0, duration), source: source,
        sourceID: url.lastPathComponent))
    return records
  }

  static func append(
    _ mapped: RecordMapper.Mapped, to records: inout MigrationRecords, file: String, line: Int?
  ) {
    switch mapped {
    case .transcript(let transcript): records.transcripts.append(transcript)
    case .dictionary(let entry): records.dictionary.append(entry)
    case .snippet(let snippet): records.snippets.append(snippet)
    case .unsupported(let reason):
      records.unsupported.append(MigrationIssue(file: file, reason: reason, line: line))
    }
  }

  /// Dispatch by extension, for the folder adapter. Returns nil for a file type we
  /// make no claim about, so the caller can count it as unsupported rather than
  /// pretending a `.wav` was empty.
  public static func file(_ url: URL, options: MigrationOptions, source: String)
    -> MigrationRecords?
  {
    switch url.pathExtension.lowercased() {
    case let ext where textExtensions.contains(ext):
      return plainText(url, options: options, source: source)
    case let ext where markdownExtensions.contains(ext):
      return markdown(url, options: options, source: source)
    case let ext where jsonExtensions.contains(ext):
      return json(url, options: options, source: source, provider: "import")
    case let ext where jsonLinesExtensions.contains(ext):
      return jsonLines(url, options: options, source: source, provider: "import")
    case let ext where separatedExtensions.contains(ext):
      return separatedValues(url, options: options, source: source, provider: "import")
    case let ext where subtitleExtensions.contains(ext):
      return subtitles(url, options: options, source: source)
    default:
      return nil
    }
  }
}

// MARK: - Adapters

/// Rant's own archive, so the Migration Center can restore a backup by the same route
/// it imports everything else.
public struct RantArchiveAdapter: FileMigrationAdapter {
  public let sourceName = "Rant archive"
  public let sourceTag = "rant"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    SourceGuard.isDirectory(source) && RantArchive.looksLikeArchive(source)
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    try RantArchive.read(source, options: options)
  }
}

public struct PlainTextAdapter: FileMigrationAdapter {
  public let sourceName = "Plain text"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    !SourceGuard.isDirectory(source)
      && GenericParsers.textExtensions.contains(source.pathExtension.lowercased())
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.plainText(source, options: options, source: sourceTag)
  }
}

public struct MarkdownAdapter: FileMigrationAdapter {
  public let sourceName = "Markdown"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    !SourceGuard.isDirectory(source)
      && GenericParsers.markdownExtensions.contains(source.pathExtension.lowercased())
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.markdown(source, options: options, source: sourceTag)
  }
}

public struct JSONAdapter: FileMigrationAdapter {
  public let sourceName = "JSON"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  /// Structure, not extension: the file has to parse *and* contain an array of
  /// objects. A JSON settings file is not an export and should fall through to
  /// "nothing here we recognise" rather than import as zero records.
  public func detect(_ source: URL) -> Bool {
    guard !SourceGuard.isDirectory(source),
      GenericParsers.jsonExtensions.contains(source.pathExtension.lowercased()),
      let data = try? SourceGuard.data(at: source, limit: 32 * 1024 * 1024),
      let value = SafeJSON.object(from: data)
    else { return false }
    return (SafeJSON.records(in: value)?.isEmpty == false)
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.json(source, options: options, source: sourceTag, provider: "import")
  }
}

public struct JSONLinesAdapter: FileMigrationAdapter {
  public let sourceName = "JSON Lines"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    !SourceGuard.isDirectory(source)
      && GenericParsers.jsonLinesExtensions.contains(source.pathExtension.lowercased())
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.jsonLines(source, options: options, source: sourceTag, provider: "import")
  }
}

public struct CSVAdapter: FileMigrationAdapter {
  public let sourceName = "CSV"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    !SourceGuard.isDirectory(source)
      && GenericParsers.separatedExtensions.contains(source.pathExtension.lowercased())
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.separatedValues(source, options: options, source: sourceTag, provider: "import")
  }
}

public struct SubtitleAdapter: FileMigrationAdapter {
  public let sourceName = "Subtitles"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    !SourceGuard.isDirectory(source)
      && GenericParsers.subtitleExtensions.contains(source.pathExtension.lowercased())
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    GenericParsers.subtitles(source, options: options, source: sourceTag)
  }
}

/// A folder someone dropped their exports into.
///
/// The last adapter tried, and the only one that walks a tree. It reads what it
/// recognises and counts the rest as unsupported, so a folder that also contains
/// audio and screenshots imports the transcripts and tells the user plainly that the
/// `.wav` files were left alone.
public struct TranscriptFolderAdapter: FileMigrationAdapter {
  public let sourceName = "Folder of transcripts"
  public let sourceTag = "import"
  public let sink: MigrationSink?

  public init(sink: MigrationSink?) { self.sink = sink }

  public func detect(_ source: URL) -> Bool {
    guard SourceGuard.isDirectory(source) else { return false }
    return SourceGuard.files(under: source, maxCount: 500).contains {
      GenericParsers.allExtensions.contains($0.pathExtension.lowercased())
    }
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    var records = MigrationRecords()
    for file in SourceGuard.files(under: source) {
      if records.count >= options.maxRecords { break }
      if let parsed = GenericParsers.file(file, options: options, source: sourceTag) {
        records.merge(parsed)
      } else {
        records.unsupported.append(
          MigrationIssue(file: file.lastPathComponent, reason: "unrecognised file type"))
      }
    }
    return records
  }
}
