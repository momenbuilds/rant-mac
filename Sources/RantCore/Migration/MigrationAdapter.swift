import Foundation

/// Reading someone else's data out of someone else's app.
///
/// Every adapter in this folder runs against files Rant did not write, in a folder
/// the user picked, in a format nobody documented. Three rules follow from that, and
/// they are enforced here rather than left to each adapter's good intentions:
///
/// - The source is opened read-only. A migration that damages the app you are
///   leaving is not a migration, it is a hostage situation.
/// - Parsing is total. Any file can be truncated, adversarial, or not what its
///   extension claims, so a parser reports a malformed record and carries on rather
///   than throwing away the other ten thousand.
/// - What could not be understood is counted, not guessed at. A record Rant invents
///   is worse than a record Rant admits it skipped.
public protocol MigrationAdapter: Sendable {
  var sourceName: String { get }
  func canRead(_ source: URL) async -> Bool
  func preview(_ source: URL) async throws -> MigrationPreview
  func importData(_ source: URL, options: MigrationOptions) async throws -> MigrationResult
}

// MARK: - Options

/// What the user asked the import to do.
public struct MigrationOptions: Sendable, Equatable {
  /// Parse and report, write nothing. A dry run touches no table at all — not even
  /// the audit tables — because a preview that leaves rows behind is a preview the
  /// user cannot trust, and `migration_runs` is the first place they would look to
  /// check.
  public var dryRun: Bool
  public var importTranscripts: Bool
  public var importMeetings: Bool
  public var importNotes: Bool
  public var importVocabulary: Bool
  /// Ignore anything older than this, for the common "just bring the last year".
  public var since: Date?
  /// Ceilings that keep a hostile, or simply enormous, file from exhausting memory.
  public var maxFileBytes: Int
  public var maxRecords: Int
  /// How many per-record rows an import may write to `migration_items`. A full audit
  /// of a million-record import would be larger than the import; the run row still
  /// carries the true totals, and the item log says where it was cut.
  public var maxAuditItems: Int

  public init(
    dryRun: Bool = false,
    importTranscripts: Bool = true,
    importMeetings: Bool = true,
    importNotes: Bool = true,
    importVocabulary: Bool = true,
    since: Date? = nil,
    maxFileBytes: Int = 128 * 1024 * 1024,
    maxRecords: Int = 500_000,
    maxAuditItems: Int = 2_000
  ) {
    self.dryRun = dryRun
    self.importTranscripts = importTranscripts
    self.importMeetings = importMeetings
    self.importNotes = importNotes
    self.importVocabulary = importVocabulary
    self.since = since
    self.maxFileBytes = maxFileBytes
    self.maxRecords = maxRecords
    self.maxAuditItems = maxAuditItems
  }

  public static let preview = MigrationOptions(dryRun: true)
}

// MARK: - Reporting

/// A record that could not be imported, described without quoting it.
///
/// The reason is a fixed phrase and the reference is a file name and a line number.
/// The user's words never reach a log or an audit row, because "we could not parse
/// this" is not a good enough reason to copy a private sentence somewhere new.
public struct MigrationIssue: Sendable, Equatable, Codable {
  public var file: String
  public var reason: String
  public var line: Int?

  public init(file: String, reason: String, line: Int? = nil) {
    self.file = file
    self.reason = reason
    self.line = line
  }

  public var summary: String {
    line.map { "\(file):\($0) — \(reason)" } ?? "\(file) — \(reason)"
  }
}

/// What an import would bring in, shown before anything is written.
public struct MigrationPreview: Sendable, Equatable {
  public var sourceName: String
  public var transcripts: Int
  public var meetings: Int
  public var notes: Int
  public var dictionaryEntries: Int
  public var snippets: Int
  public var earliest: Date?
  public var latest: Date?
  /// Bytes of source actually read, so the user can tell a stray file from a decade
  /// of history before committing to either.
  public var estimatedBytes: Int
  public var unsupported: Int
  public var malformed: Int

  public init(
    sourceName: String, transcripts: Int = 0, meetings: Int = 0, notes: Int = 0,
    dictionaryEntries: Int = 0, snippets: Int = 0, earliest: Date? = nil, latest: Date? = nil,
    estimatedBytes: Int = 0, unsupported: Int = 0, malformed: Int = 0
  ) {
    self.sourceName = sourceName
    self.transcripts = transcripts
    self.meetings = meetings
    self.notes = notes
    self.dictionaryEntries = dictionaryEntries
    self.snippets = snippets
    self.earliest = earliest
    self.latest = latest
    self.estimatedBytes = estimatedBytes
    self.unsupported = unsupported
    self.malformed = malformed
  }

  public var total: Int { transcripts + meetings + notes + dictionaryEntries + snippets }

  public var dateRange: ClosedRange<Date>? {
    guard let earliest, let latest, earliest <= latest else { return nil }
    return earliest...latest
  }
}

/// What an import actually did.
public struct MigrationResult: Sendable, Equatable {
  public var sourceName: String
  public var runID: Int64?
  public var imported: Int
  public var duplicatesSkipped: Int
  public var malformedSkipped: Int
  public var unsupported: Int
  public var errors: [MigrationIssue]
  public var dryRun: Bool

  public init(
    sourceName: String, runID: Int64? = nil, imported: Int = 0, duplicatesSkipped: Int = 0,
    malformedSkipped: Int = 0, unsupported: Int = 0, errors: [MigrationIssue] = [],
    dryRun: Bool = false
  ) {
    self.sourceName = sourceName
    self.runID = runID
    self.imported = imported
    self.duplicatesSkipped = duplicatesSkipped
    self.malformedSkipped = malformedSkipped
    self.unsupported = unsupported
    self.errors = errors
    self.dryRun = dryRun
  }
}

public enum MigrationError: Error, Equatable, LocalizedError {
  case sourceMissing(String)
  case forbiddenLocation(String)
  case sourceTooBroad(String)
  case unreadable(String)
  case noAdapter(String)
  case noDestination

  public var errorDescription: String? {
    switch self {
    case .sourceMissing(let path): "There is nothing at \(path)."
    case .forbiddenLocation(let path):
      "Rant will not read \(path). That folder holds credentials or another app's private store."
    case .sourceTooBroad(let path):
      "Choose a specific folder rather than \(path) — Rant only reads where you point it."
    case .unreadable(let path): "Could not read \(path)."
    case .noAdapter(let path):
      "Nothing in \(path) looked like a transcript export Rant recognises."
    case .noDestination: "This adapter has no database to import into."
    }
  }
}

// MARK: - Parsed records

/// The neutral shape every adapter produces, so that exactly one piece of code
/// decides what reaches the database.
public struct MigrationRecords: Sendable {
  public var transcripts: [Transcript] = []
  public var meetings: [ArchiveMeeting] = []
  public var notes: [ArchiveNote] = []
  public var dictionary: [DictionaryEntry] = []
  public var snippets: [Snippet] = []
  public var malformed: [MigrationIssue] = []
  public var unsupported: [MigrationIssue] = []
  public var estimatedBytes: Int = 0

  public init() {}

  public var count: Int {
    transcripts.count + meetings.count + notes.count + dictionary.count + snippets.count
  }

  public mutating func merge(_ other: MigrationRecords) {
    transcripts += other.transcripts
    meetings += other.meetings
    notes += other.notes
    dictionary += other.dictionary
    snippets += other.snippets
    malformed += other.malformed
    unsupported += other.unsupported
    estimatedBytes += other.estimatedBytes
  }

  /// Applies the user's filters once, centrally, rather than in nine adapters.
  public func filtered(by options: MigrationOptions) -> MigrationRecords {
    var copy = self
    if !options.importTranscripts { copy.transcripts = [] }
    if !options.importMeetings { copy.meetings = [] }
    if !options.importNotes { copy.notes = [] }
    if !options.importVocabulary {
      copy.dictionary = []
      copy.snippets = []
    }
    if let since = options.since {
      copy.transcripts = copy.transcripts.filter { $0.createdAt >= since }
      copy.meetings = copy.meetings.filter { $0.startedAt >= since }
      copy.notes = copy.notes.filter { $0.createdAt >= since }
    }
    return copy
  }

  public var earliest: Date? {
    (transcripts.map(\.createdAt) + meetings.map(\.startedAt) + notes.map(\.createdAt)).min()
  }

  public var latest: Date? {
    (transcripts.map(\.createdAt) + meetings.map(\.startedAt) + notes.map(\.createdAt)).max()
  }

  public func preview(sourceName: String) -> MigrationPreview {
    MigrationPreview(
      sourceName: sourceName, transcripts: transcripts.count, meetings: meetings.count,
      notes: notes.count, dictionaryEntries: dictionary.count, snippets: snippets.count,
      earliest: earliest, latest: latest, estimatedBytes: estimatedBytes,
      unsupported: unsupported.count, malformed: malformed.count)
  }
}

// MARK: - The shape every file adapter takes

/// An adapter that reads files from a folder the user chose.
///
/// The protocol above is the public contract; this refinement exists so the
/// read-only guard, the preview and the audit trail are written once. An adapter
/// only has to say what it recognises and how to parse it.
public protocol FileMigrationAdapter: MigrationAdapter {
  /// Where imported records are written. Nil means parse-only, which is what the
  /// preview path and the parser tests use.
  var sink: MigrationSink? { get }
  /// The tag stored in each row's `source` column. Stable across releases, because
  /// changing it would make every previously imported row look new and duplicate the
  /// user's history on their next import.
  var sourceTag: String { get }
  /// Structure, not extension. A `.json` file is not a Wispr export because of its
  /// name, and a Superwhisper folder is still one after the user renames it.
  func detect(_ source: URL) -> Bool
  func parse(_ source: URL, options: MigrationOptions) throws -> MigrationRecords
}

extension FileMigrationAdapter {
  public func canRead(_ source: URL) async -> Bool {
    guard let root = try? SourceGuard.validate(source) else { return false }
    return detect(root)
  }

  public func preview(_ source: URL) async throws -> MigrationPreview {
    let root = try SourceGuard.validate(source)
    return try parse(root, options: .preview).preview(sourceName: sourceName)
  }

  public func importData(_ source: URL, options: MigrationOptions) async throws -> MigrationResult {
    let root = try SourceGuard.validate(source)
    let records = try parse(root, options: options).filtered(by: options)
    guard let sink else {
      guard options.dryRun else { throw MigrationError.noDestination }
      return MigrationResult(
        sourceName: sourceName, malformedSkipped: records.malformed.count,
        unsupported: records.unsupported.count, errors: records.malformed + records.unsupported,
        dryRun: true)
    }
    return try sink.commit(records, sourceName: sourceName, sourcePath: root.path, options: options)
  }
}

// MARK: - Reading the source safely

/// The read-only boundary around whatever folder the user pointed at.
///
/// Nothing else in this folder touches `FileManager` for the source, so there is one
/// place to audit for "does this ever write, follow a symlink out, or wander into a
/// directory nobody chose".
public enum SourceGuard {

  /// Folders that hold credentials, cookies or another app's private store. None of
  /// them contains a transcript export, and all of them are things a migration tool
  /// has no business opening even by accident.
  static let forbiddenFragments = [
    "/library/keychains", "/library/cookies", "/library/httpstorages", "/.ssh", "/.gnupg",
    "/library/application support/com.apple.tcc", "/library/safari", "/library/mail",
    "/library/messages", "/library/passwords", "/.aws", "/.config/gcloud",
  ]

  /// Resolves the chosen source and refuses the cases that are never a deliberate
  /// choice. The resolved URL becomes the root every later read is checked against,
  /// so a symlinked folder the user picked on purpose still works while a symlink
  /// *inside* it cannot lead anywhere else.
  @discardableResult
  public static func validate(_ source: URL) throws -> URL {
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
      throw MigrationError.sourceMissing(source.path)
    }
    let lowered = resolved.path.lowercased()
    for fragment in forbiddenFragments where lowered.contains(fragment) {
      throw MigrationError.forbiddenLocation(source.path)
    }
    if isDirectory.boolValue {
      let home = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath().standardizedFileURL.path
      // "Import my whole home folder" is never what anyone meant, and honouring it
      // would mean walking every private file on the machine.
      if resolved.path == "/" || resolved.path == home || resolved.path == "/Users" {
        throw MigrationError.sourceTooBroad(source.path)
      }
    }
    return resolved
  }

  public static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  static func isSymbolicLink(_ url: URL) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
  }

  /// Regular files under `root`, breadth-first, never following a symlink and never
  /// leaving the tree the user chose.
  ///
  /// Recursion is explicit rather than `FileManager.enumerator` because the
  /// enumerator descends happily through a symlinked directory, which is exactly how
  /// a folder import turns into "read the user's entire home directory".
  public static func files(under root: URL, maxCount: Int = 20_000, maxDepth: Int = 12) -> [URL] {
    guard isDirectory(root) else { return isSymbolicLink(root) ? [] : [root] }
    var found: [URL] = []
    var queue: [(url: URL, depth: Int)] = [(root, 0)]
    let rootPath = root.standardizedFileURL.path

    while !queue.isEmpty, found.count < maxCount {
      let (directory, depth) = queue.removeFirst()
      guard depth <= maxDepth else { continue }
      let children =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      for child in children.sorted(by: { $0.path < $1.path }) {
        guard !isSymbolicLink(child) else { continue }
        // Belt and braces: even without a symlink, refuse anything whose resolved
        // path has escaped the chosen root.
        let resolved = child.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { continue }
        if isDirectory(child) {
          queue.append((child, depth + 1))
        } else {
          found.append(child)
          if found.count >= maxCount { break }
        }
      }
    }
    return found
  }

  public static func byteCount(of url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }

  public static func modificationDate(of url: URL) -> Date {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
  }

  /// Reads at most `limit` bytes. Anything larger is refused rather than truncated,
  /// because half a JSON file parses into confidently wrong records.
  public static func data(at url: URL, limit: Int) throws -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw MigrationError.unreadable(url.lastPathComponent)
    }
    defer { try? handle.close() }
    // `read(upToCount:)` returns nil at end of file, which is what an empty file is
    // from byte zero. An empty export is a legitimate export — a new user has one —
    // so it must read as no bytes rather than as a failure.
    guard let data = try? handle.read(upToCount: limit + 1) ?? Data() else {
      throw MigrationError.unreadable(url.lastPathComponent)
    }
    guard data.count <= limit else { throw MigrationError.unreadable(url.lastPathComponent) }
    return data
  }

  /// Text from bytes that may not be text.
  ///
  /// `String(decoding:as:)` substitutes replacement characters for invalid UTF-8
  /// rather than returning nil, which is what we want: a transcript with one broken
  /// byte is still a transcript, and an adapter that returns nothing because of it
  /// loses the user's history to a rounding error.
  public static func text(at url: URL, limit: Int) throws -> String {
    var text = String(decoding: try data(at: url, limit: limit), as: UTF8.self)
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text
  }
}

// MARK: - Total parsers for untrusted input

/// Line splitting with a ceiling.
///
/// One 400 MB line is a plausible thing to find in a corrupted export, and handing it
/// to a JSON parser is how an import turns into a hang. Over-long lines come back
/// flagged, so the caller counts them as malformed and moves on.
public enum LineScanner {
  public static let defaultMaxLineLength = 4 * 1024 * 1024

  public struct Line: Sendable {
    public let number: Int
    public let text: String
    public let tooLong: Bool
  }

  public static func lines(
    of text: String, maxLineLength: Int = defaultMaxLineLength, maxLines: Int = 2_000_000
  ) -> [Line] {
    var result: [Line] = []
    var number = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      number += 1
      if number > maxLines { break }
      if raw.count > maxLineLength {
        result.append(Line(number: number, text: "", tooLong: true))
      } else {
        var line = String(raw)
        if line.hasSuffix("\r") { line.removeLast() }
        result.append(Line(number: number, text: line, tooLong: false))
      }
    }
    return result
  }
}

/// JSON reading that refuses the shapes designed to hurt the parser.
public enum SafeJSON {
  /// `JSONSerialization` parses nested containers recursively, so a file that is
  /// nothing but a hundred thousand open brackets overflows the stack before any of
  /// our code runs. Depth is therefore counted with a flat byte scan first — linear,
  /// allocation-free, and impossible to make quadratic.
  public static func depthIsSafe(_ data: Data, maxDepth: Int = 64) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in data {
      if inString {
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          inString = false
        }
        continue
      }
      switch byte {
      case 0x22: inString = true
      case 0x7B, 0x5B:
        depth += 1
        if depth > maxDepth { return false }
      case 0x7D, 0x5D: depth -= 1
      default: break
      }
    }
    return true
  }

  public static func object(from data: Data, maxDepth: Int = 64) -> Any? {
    guard !data.isEmpty, depthIsSafe(data, maxDepth: maxDepth) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  public static func object(from text: String, maxDepth: Int = 64) -> Any? {
    object(from: Data(text.utf8), maxDepth: maxDepth)
  }

  /// The array of records inside a top-level value, whether the file is an array or
  /// an object with the records under one of the names exporters habitually use.
  public static func records(in value: Any?) -> [[String: Any]]? {
    if let array = value as? [Any] {
      let objects = array.compactMap { $0 as? [String: Any] }
      return objects.isEmpty && !array.isEmpty ? nil : objects
    }
    guard let object = value as? [String: Any] else { return nil }
    let keys = [
      "transcripts", "transcriptions", "records", "items", "entries", "history", "data",
      "results", "recordings", "dictations", "speeches", "notes", "sessions",
    ]
    let normalised = FieldMap(object)
    for key in keys {
      if let array = normalised.value(key) as? [Any] {
        return array.compactMap { $0 as? [String: Any] }
      }
    }
    return nil
  }
}

/// Case- and punctuation-insensitive lookup over one JSON object.
///
/// Exports spell the same field `created_at`, `createdAt`, `CreatedAt` and
/// `Created At` depending on who wrote the exporter and when. Normalising once per
/// object costs one pass and removes a whole class of "the adapter silently found
/// nothing" bug.
public struct FieldMap {
  private let storage: [String: Any]

  public init(_ object: [String: Any]) {
    var storage: [String: Any] = [:]
    storage.reserveCapacity(object.count)
    for (key, value) in object {
      storage[FieldMap.normalise(key)] = value
    }
    self.storage = storage
  }

  public static func normalise(_ key: String) -> String {
    String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
  }

  public func value(_ key: String) -> Any? { storage[FieldMap.normalise(key)] }

  public func has(_ key: String) -> Bool { storage[FieldMap.normalise(key)] != nil }

  public func hasAll(_ keys: [String]) -> Bool { keys.allSatisfy { has($0) } }

  public func hasAny(_ keys: [String]) -> Bool { keys.contains { has($0) } }

  public func string(_ keys: [String]) -> String? {
    for key in keys {
      guard let value = value(key) else { continue }
      if let text = value as? String, !text.isEmpty { return text }
      if let number = value as? NSNumber { return number.stringValue }
    }
    return nil
  }

  public func int(_ keys: [String]) -> Int? {
    for key in keys {
      guard let value = value(key) else { continue }
      if let number = value as? NSNumber { return number.intValue }
      if let text = value as? String, let parsed = Int(text) { return parsed }
    }
    return nil
  }

  public func double(_ keys: [String]) -> Double? {
    for key in keys {
      guard let value = value(key) else { continue }
      if let number = value as? NSNumber { return number.doubleValue }
      if let text = value as? String, let parsed = Double(text) { return parsed }
    }
    return nil
  }

  public func bool(_ keys: [String]) -> Bool? {
    for key in keys {
      guard let value = value(key) else { continue }
      if let number = value as? NSNumber { return number.boolValue }
      if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
    }
    return nil
  }

  public func array(_ keys: [String]) -> [Any]? {
    for key in keys {
      if let array = value(key) as? [Any] { return array }
    }
    return nil
  }

  public func strings(_ keys: [String]) -> [String] {
    guard let array = array(keys) else { return [] }
    return array.compactMap { $0 as? String }
  }

  public func date(_ keys: [String]) -> Date? {
    for key in keys {
      guard let value = value(key) else { continue }
      if let date = FlexibleDate.parse(value) { return date }
    }
    return nil
  }
}

/// Dates, in whatever the exporter felt like emitting.
///
/// No regular expressions anywhere below. A format guess made with a backtracking
/// pattern is a hang waiting for the right input — this codebase has already lost an
/// afternoon to one — and every shape here is decidable with a linear scan or a
/// fixed format string.
public enum FlexibleDate {
  private static let lock = NSLock()

  nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let fallbacks: [DateFormatter] = {
    [
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
      "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd", "MMM d, yyyy 'at' h:mm a", "MMM d, yyyy h:mm a",
      "MMM d, yyyy",
    ].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter
    }
  }()

  /// Seconds, milliseconds or microseconds since 1970, told apart by magnitude. The
  /// thresholds sit far from any plausible real timestamp: 10^11 seconds is the year
  /// 5138, and nobody is exporting those.
  public static func fromEpoch(_ value: Double) -> Date? {
    guard value.isFinite, value > 0 else { return nil }
    if value < 100_000_000_000 { return Date(timeIntervalSince1970: value) }
    if value < 100_000_000_000_000 { return Date(timeIntervalSince1970: value / 1_000) }
    if value < 100_000_000_000_000_000 { return Date(timeIntervalSince1970: value / 1_000_000) }
    return nil
  }

  public static func parse(_ value: Any?) -> Date? {
    switch value {
    case let date as Date: return date
    case let number as NSNumber: return fromEpoch(number.doubleValue)
    case let text as String: return parse(text)
    default: return nil
    }
  }

  public static func parse(_ raw: String) -> Date? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count < 64 else { return nil }

    // A bare number is an epoch, not a date string; check it before the formatters
    // so "1700000000" is not read as a year.
    if text.allSatisfy({ $0.isNumber || $0 == "." }), let number = Double(text) {
      return fromEpoch(number)
    }

    return lock.withLock { () -> Date? in
      if let date = isoFractional.date(from: text) { return date }
      if let date = iso.date(from: text) { return date }
      for formatter in fallbacks {
        if let date = formatter.date(from: text) { return date }
      }
      return nil
    }
  }

  /// `01:02:03,456`, `01:02:03.456` or `02:03.456` — the subtitle timecodes, as
  /// seconds. Split apart rather than matched.
  public static func timecodeSeconds(_ raw: String) -> Double? {
    let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    var seconds = 0.0
    for part in parts {
      guard let value = Double(part), value.isFinite else { return nil }
      seconds = seconds * 60 + value
    }
    return seconds
  }
}

/// A CSV reader that handles quoting, embedded newlines and CRLF, and nothing else.
///
/// Written by hand rather than pulled in, because the whole surface is one state
/// machine and a dependency here would be a dependency in the one place that reads
/// files the user did not write.
public enum CSVReader {
  public static func rows(
    _ text: String, separator: Character = ",", maxRows: Int = 500_000,
    maxFieldLength: Int = 1_000_000
  ) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var iterator = text.makeIterator()
    var pending: Character?

    func endField() {
      row.append(field)
      field = ""
    }
    func endRow() {
      endField()
      // A trailing newline should not produce a phantom empty row.
      if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
      row = []
    }

    while rows.count < maxRows {
      let character: Character
      if let pendingCharacter = pending {
        character = pendingCharacter
        pending = nil
      } else if let next = iterator.next() {
        character = next
      } else {
        break
      }

      if inQuotes {
        if character == "\"" {
          if let next = iterator.next() {
            if next == "\"" {
              field.append("\"")
            } else {
              inQuotes = false
              pending = next
            }
          } else {
            inQuotes = false
          }
        } else if field.count < maxFieldLength {
          field.append(character)
        }
        continue
      }

      switch character {
      case "\"" where field.isEmpty: inQuotes = true
      case separator: endField()
      case "\n": endRow()
      case "\r": break
      default: if field.count < maxFieldLength { field.append(character) }
      }
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    return rows
  }

  /// Header row plus body, with the header normalised for lookup.
  public static func table(_ text: String, separator: Character = ",") -> (
    header: [String], rows: [[String]]
  )? {
    let rows = rows(text, separator: separator)
    guard let header = rows.first, header.count > 1 else { return nil }
    return (header.map { FieldMap.normalise($0) }, Array(rows.dropFirst()))
  }

  public static func value(_ row: [String], _ header: [String], _ names: [String]) -> String? {
    for name in names {
      let wanted = FieldMap.normalise(name)
      guard let index = header.firstIndex(of: wanted), index < row.count else { continue }
      let value = row[index]
      if !value.isEmpty { return value }
    }
    return nil
  }
}

/// Subtitle cues, from SRT or WebVTT.
public enum SubtitleReader {
  public struct Cue: Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var speaker: String?
  }

  /// One linear pass over the lines. A block without a `-->` line is skipped rather
  /// than guessed at, which is what makes a half-downloaded subtitle file import as
  /// "most of it" instead of as nonsense.
  public static func cues(_ text: String, maxCues: Int = 100_000) -> (cues: [Cue], skipped: Int) {
    var cues: [Cue] = []
    var skipped = 0
    var block: [String] = []

    func flush() {
      defer { block = [] }
      guard !block.isEmpty else { return }
      guard let arrowIndex = block.firstIndex(where: { $0.contains("-->") }) else {
        // A file header (WEBVTT) or a note block is not a broken cue.
        let first = block[0].uppercased()
        if !first.hasPrefix("WEBVTT"), !first.hasPrefix("NOTE"), !first.hasPrefix("STYLE"),
          !first.hasPrefix("REGION")
        {
          skipped += 1
        }
        return
      }
      let timings = block[arrowIndex].components(separatedBy: "-->")
      guard timings.count == 2,
        let start = FlexibleDate.timecodeSeconds(timings[0]),
        let end = FlexibleDate.timecodeSeconds(
          timings[1].split(separator: " ").first.map(String.init) ?? timings[1])
      else {
        skipped += 1
        return
      }
      var body = block[(arrowIndex + 1)...].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return }

      // "Alice: hello" is the convention every meeting exporter uses for a speaker.
      var speaker: String?
      if let colon = body.firstIndex(of: ":") {
        let candidate = String(body[body.startIndex..<colon])
        let looksLikeAName =
          !candidate.isEmpty && candidate.count <= 40
          && candidate.allSatisfy { $0.isLetter || $0 == " " || $0 == "." || $0 == "-" }
        if looksLikeAName {
          speaker = candidate.trimmingCharacters(in: .whitespaces)
          body = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
      }
      cues.append(Cue(startSeconds: start, endSeconds: end, text: body, speaker: speaker))
    }

    for line in LineScanner.lines(of: text) {
      guard !line.tooLong else {
        skipped += 1
        block = []
        continue
      }
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        flush()
        if cues.count >= maxCues { break }
        continue
      }
      // A lone number is the SRT sequence counter and carries nothing.
      if block.isEmpty, trimmed.allSatisfy(\.isNumber) { continue }
      block.append(trimmed)
    }
    flush()
    return (cues, skipped)
  }
}
