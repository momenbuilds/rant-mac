import Foundation

/// Adapters for the apps people are leaving.
///
/// None of these formats is documented, and none of them is verifiable from here:
/// they were built from real exports and from what those apps' own storage looks
/// like, and they will be wrong for some version we have never seen. Three
/// consequences run through every adapter below.
///
/// - **Detection is structural.** A file is a Wispr export because it carries Wispr's
///   field names, not because it is called `wispr.json`. A renamed export still
///   imports; a settings file with the wrong name does not.
/// - **Shapes are additive.** Each adapter lists the shapes it recognises and gains
///   new ones rather than replacing old ones, because an export somebody made two
///   years ago must keep importing after we learn what the current one looks like.
/// - **Nothing is guessed.** A record whose text field we do not recognise is counted
///   as unsupported and shown to the user. Filling their history with a plausible
///   reconstruction would be worse than telling them we could not read forty rows.
public enum CompetitorSupport {
  static let dataExtensions: Set<String> = ["json", "jsonl", "ndjson", "csv", "tsv"]

  /// Files worth sniffing, whether the user chose one file or the folder holding it.
  static func candidateFiles(
    _ source: URL, extensions: Set<String> = dataExtensions, maxCount: Int = 5_000
  ) -> [URL] {
    if SourceGuard.isDirectory(source) {
      return SourceGuard.files(under: source, maxCount: maxCount).filter {
        extensions.contains($0.pathExtension.lowercased())
      }
    }
    return extensions.contains(source.pathExtension.lowercased()) ? [source] : []
  }

  /// A cheap look at the first few records of a file, for detection only. Capped
  /// hard: deciding whether a file is a Wispr export must not cost as much as
  /// importing it.
  static func sample(_ url: URL, limit: Int = 20) -> [[String: Any]] {
    let extension_ = url.pathExtension.lowercased()
    let byteLimit = 8 * 1024 * 1024
    guard let text = try? SourceGuard.text(at: url, limit: byteLimit) else { return [] }

    if extension_ == "json" {
      return Array((SafeJSON.records(in: SafeJSON.object(from: text)) ?? []).prefix(limit))
    }
    if extension_ == "jsonl" || extension_ == "ndjson" {
      var objects: [[String: Any]] = []
      for line in LineScanner.lines(of: text) where !line.tooLong {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if let object = SafeJSON.object(from: trimmed) as? [String: Any] { objects.append(object) }
        if objects.count >= limit { break }
      }
      return objects
    }
    let separator: Character = extension_ == "tsv" ? "\t" : ","
    guard let table = CSVReader.table(text, separator: separator) else { return [] }
    return table.rows.prefix(limit).map { row in
      var object: [String: Any] = [:]
      for (index, name) in table.header.enumerated() where index < row.count {
        object[name] = row[index]
      }
      return object
    }
  }

  /// True when any sampled record carries one of the source's signature fields.
  static func matchesSignature(_ source: URL, _ isSignature: ([String: Any]) -> Bool) -> Bool {
    for file in candidateFiles(source, maxCount: 200) {
      if sample(file).contains(where: isSignature) { return true }
    }
    return false
  }

  /// Parses every candidate file with the generic mappers under the source's own tag,
  /// keeping only the files that actually match — a folder holding one Wispr export
  /// and one unrelated CSV should not tag the CSV as Wispr history.
  static func parseTagged(
    _ source: URL, options: MigrationOptions, tag: String, provider: String,
    isSignature: ([String: Any]) -> Bool
  ) -> MigrationRecords {
    var records = MigrationRecords()
    for file in candidateFiles(source) {
      guard sample(file).contains(where: isSignature) else { continue }
      switch file.pathExtension.lowercased() {
      case "json":
        records.merge(GenericParsers.json(file, options: options, source: tag, provider: provider))
      case "jsonl", "ndjson":
        records.merge(
          GenericParsers.jsonLines(file, options: options, source: tag, provider: provider))
      default:
        records.merge(
          GenericParsers.separatedValues(file, options: options, source: tag, provider: provider))
      }
      if records.count >= options.maxRecords { break }
    }
    return records
  }

  /// Offsets inside a recording, which exporters give in seconds or milliseconds
  /// without saying which. An hour is the dividing line: no meeting segment starts
  /// 3,600 seconds in *and* means milliseconds.
  static func offsetMilliseconds(_ value: Double?) -> Int? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value > 3_600 ? Int(value) : Int(value * 1_000)
  }
}

// MARK: - Wispr Flow

/// Wispr Flow's dictation history.
///
/// The shape that matters is the pair of texts: Wispr keeps what the recogniser heard
/// (`asrText`) alongside what it formatted for you (`formattedText`), which maps
/// exactly onto Rant's raw and final text. Preserving both is the point — an import
/// that keeps only the polished version throws away the input the user could later
/// re-clean.
public struct WisprFlowAdapter: FileMigrationAdapter {
  public let sourceName = "Wispr Flow"
  public let sourceTag = "wispr_flow"
  public let sink: MigrationSink?

  /// Recognised shapes, oldest kept forever.
  public static let recognisedShapes = ["wispr-flow-v1", "wispr-flow-csv-v1"]

  public init(sink: MigrationSink?) { self.sink = sink }

  static func isWisprRecord(_ object: [String: Any]) -> Bool {
    let map = FieldMap(object)
    if map.hasAny(["formattedText", "asrText", "flowId"]) { return true }
    // The CSV export drops the distinctive names but keeps this trio.
    return map.hasAll(["text", "app"]) && map.hasAny(["numWords", "wordCount", "timestamp"])
  }

  public func detect(_ source: URL) -> Bool {
    CompetitorSupport.matchesSignature(source, Self.isWisprRecord)
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    CompetitorSupport.parseTagged(
      source, options: options, tag: sourceTag, provider: "wispr",
      isSignature: Self.isWisprRecord)
  }
}

// MARK: - VoiceInk

/// VoiceInk's transcription history.
///
/// VoiceInk stores an original transcription and, optionally, an AI-enhanced version.
/// The enhanced text is what was inserted, so it becomes the final text and the
/// original becomes the raw text; when there is no enhancement the two are the same,
/// which is exactly how Rant records an un-enhanced dictation.
public struct VoiceInkAdapter: FileMigrationAdapter {
  public let sourceName = "VoiceInk"
  public let sourceTag = "voiceink"
  public let sink: MigrationSink?

  public static let recognisedShapes = ["voiceink-v1"]

  public init(sink: MigrationSink?) { self.sink = sink }

  static func isVoiceInkRecord(_ object: [String: Any]) -> Bool {
    let map = FieldMap(object)
    if map.hasAny(["enhancedText", "transcriptionModelName", "aiEnhancementModelName"]) {
      return true
    }
    return map.hasAll(["text", "duration", "timestamp"]) && map.hasAny(["audioURL", "audioPath"])
  }

  public func detect(_ source: URL) -> Bool {
    CompetitorSupport.matchesSignature(source, Self.isVoiceInkRecord)
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    CompetitorSupport.parseTagged(
      source, options: options, tag: sourceTag, provider: "voiceink",
      isSignature: Self.isVoiceInkRecord)
  }
}

// MARK: - Superwhisper

/// Superwhisper's recordings folder.
///
/// Not a single export file but a directory per recording, each holding a `meta.json`
/// beside the audio. The audio is deliberately left where it is: copying gigabytes of
/// someone's voice into a second location without being asked is not a migration
/// feature, and the transcript is what Rant can actually use.
public struct SuperwhisperAdapter: FileMigrationAdapter {
  public let sourceName = "Superwhisper"
  public let sourceTag = "superwhisper"
  public let sink: MigrationSink?

  public static let recognisedShapes = ["superwhisper-meta-v1"]

  public init(sink: MigrationSink?) { self.sink = sink }

  static func metaFiles(_ source: URL, maxCount: Int = 20_000) -> [URL] {
    if SourceGuard.isDirectory(source) {
      return SourceGuard.files(under: source, maxCount: maxCount).filter {
        $0.lastPathComponent.lowercased() == "meta.json"
      }
    }
    return source.lastPathComponent.lowercased() == "meta.json" ? [source] : []
  }

  static func isSuperwhisperMeta(_ object: [String: Any]) -> Bool {
    let map = FieldMap(object)
    guard map.hasAny(["result", "rawResult"]) else { return false }
    return map.hasAny(["datetime", "modelName", "languageCode", "processedAt", "duration"])
  }

  public func detect(_ source: URL) -> Bool {
    for file in Self.metaFiles(source, maxCount: 200) {
      guard let data = try? SourceGuard.data(at: file, limit: 4 * 1024 * 1024),
        let object = SafeJSON.object(from: data) as? [String: Any]
      else { continue }
      if Self.isSuperwhisperMeta(object) { return true }
    }
    return false
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    var records = MigrationRecords()
    for file in Self.metaFiles(source) {
      if records.count >= options.maxRecords { break }
      records.estimatedBytes += SourceGuard.byteCount(of: file)
      let reference = file.deletingLastPathComponent().lastPathComponent + "/meta.json"
      guard let data = try? SourceGuard.data(at: file, limit: options.maxFileBytes),
        SafeJSON.depthIsSafe(data)
      else {
        records.unsupported.append(
          MigrationIssue(file: reference, reason: "too large or unreadable"))
        continue
      }
      guard let object = SafeJSON.object(from: data) as? [String: Any] else {
        records.malformed.append(MigrationIssue(file: reference, reason: "unreadable record"))
        continue
      }
      guard Self.isSuperwhisperMeta(object) else {
        records.unsupported.append(
          MigrationIssue(file: reference, reason: "not a Superwhisper recording"))
        continue
      }
      // The folder name is the epoch of the recording, and is the only timestamp
      // present in some versions.
      let folderDate = FlexibleDate.parse(file.deletingLastPathComponent().lastPathComponent)
      let fallback = folderDate ?? SourceGuard.modificationDate(of: file)
      GenericParsers.append(
        RecordMapper.map(
          object, source: sourceTag, provider: "superwhisper", fallbackDate: fallback),
        to: &records, file: reference, line: nil)
    }
    return records
  }
}

// MARK: - Otter

/// Otter conversations.
///
/// Otter's unit is a conversation with speaker-attributed segments, which is a
/// meeting rather than a dictation, so that is what it imports as. A conversation
/// with no segments we can read is recorded as unsupported instead of being flattened
/// into a single block of text with the speakers dropped.
public struct OtterAdapter: FileMigrationAdapter {
  public let sourceName = "Otter"
  public let sourceTag = "otter"
  public let sink: MigrationSink?

  public static let recognisedShapes = ["otter-speeches-v1"]

  public init(sink: MigrationSink?) { self.sink = sink }

  static func isOtterSpeech(_ object: [String: Any]) -> Bool {
    let map = FieldMap(object)
    if map.hasAny(["speechId", "otid"]) { return true }
    guard let segments = map.array(["transcripts", "segments", "monologues"]) else { return false }
    return segments.compactMap { $0 as? [String: Any] }.contains {
      FieldMap($0).hasAny(["transcript", "text"])
    }
  }

  public func detect(_ source: URL) -> Bool {
    CompetitorSupport.matchesSignature(source, Self.isOtterSpeech)
  }

  public func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords {
    var records = MigrationRecords()
    for file in CompetitorSupport.candidateFiles(source, extensions: ["json", "jsonl", "ndjson"]) {
      if records.count >= options.maxRecords { break }
      records.estimatedBytes += SourceGuard.byteCount(of: file)
      guard let text = try? SourceGuard.text(at: file, limit: options.maxFileBytes) else {
        records.unsupported.append(
          MigrationIssue(file: file.lastPathComponent, reason: "too large or unreadable"))
        continue
      }
      let objects: [[String: Any]]
      if file.pathExtension.lowercased() == "json" {
        guard let value = SafeJSON.object(from: text) else {
          records.malformed.append(
            MigrationIssue(file: file.lastPathComponent, reason: "unreadable record"))
          continue
        }
        objects = SafeJSON.records(in: value) ?? ((value as? [String: Any]).map { [$0] } ?? [])
      } else {
        objects = LineScanner.lines(of: text).compactMap { line in
          guard !line.tooLong else { return nil }
          let trimmed = line.text.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty else { return nil }
          return SafeJSON.object(from: trimmed) as? [String: Any]
        }
      }
      for object in objects.prefix(options.maxRecords) {
        guard Self.isOtterSpeech(object) else {
          records.unsupported.append(
            MigrationIssue(file: file.lastPathComponent, reason: "not an Otter conversation"))
          continue
        }
        if let meeting = Self.meeting(from: object, fallback: SourceGuard.modificationDate(of: file))
        {
          records.meetings.append(meeting)
        } else {
          records.unsupported.append(
            MigrationIssue(file: file.lastPathComponent, reason: "conversation has no segments"))
        }
      }
    }
    return records
  }

  static func meeting(from object: [String: Any], fallback: Date) -> ArchiveMeeting? {
    let map = FieldMap(object)
    let started = map.date(["startTime", "createdAt", "startedAt", "date"]) ?? fallback
    let raw = map.array(["transcripts", "segments", "monologues"]) ?? []
    var segments: [ArchiveMeetingSegment] = []
    for entry in raw.compactMap({ $0 as? [String: Any] }) {
      let segment = FieldMap(entry)
      guard let text = segment.string(["transcript", "text"])?
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
      else { continue }
      segments.append(
        ArchiveMeetingSegment(
          startedMilliseconds: CompetitorSupport.offsetMilliseconds(
            segment.double(["startOffset", "start", "startTime", "offset"])) ?? 0,
          endedMilliseconds: CompetitorSupport.offsetMilliseconds(
            segment.double(["endOffset", "end", "endTime"])),
          speaker: segment.string(["speakerName", "speaker", "speakerId"]),
          // Everything in an Otter conversation arrived through the meeting audio,
          // so none of it can be claimed as the user's own microphone channel.
          channel: "them", text: text))
    }
    guard !segments.isEmpty else { return nil }
    let ended = map.date(["endTime", "endedAt"])
      ?? segments.compactMap(\.endedMilliseconds).max().map {
        started.addingTimeInterval(Double($0) / 1_000)
      }
    return ArchiveMeeting(
      startedAt: started, endedAt: ended, title: map.string(["title", "name", "subject"]),
      appName: "Otter", summary: map.string(["summary", "abstractSummary"]),
      actionItems: map.strings(["actionItems", "action_items"]),
      decisions: map.strings(["decisions"]), source: "otter", segments: segments)
  }
}
