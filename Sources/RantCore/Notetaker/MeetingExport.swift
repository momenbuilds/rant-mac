import Foundation

/// The shapes a meeting can leave Rant in.
///
/// Five formats rather than one, because the point of a local-first notetaker is
/// that the data is yours: Markdown for a notes app, plain text for an email, JSON
/// for anything you want to script, and SRT or VTT for dropping the transcript onto
/// a recording of the call in a video editor.
public enum MeetingExportFormat: String, CaseIterable, Sendable, Codable {
  case markdown
  case text
  case json
  case srt
  case vtt

  public var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .text: "txt"
    case .json: "json"
    case .srt: "srt"
    case .vtt: "vtt"
    }
  }

  public var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .text: "Plain text"
    case .json: "JSON"
    case .srt: "SubRip (SRT)"
    case .vtt: "WebVTT"
    }
  }
}

public struct MeetingExportOptions: Equatable, Sendable {
  public var labels: MeetingSpeakerLabels
  public var includeSummary: Bool
  public var includeTimestamps: Bool
  /// Length given to a segment whose provider reported no end time.
  public var assumedSegmentMilliseconds: Int
  /// Shortest a subtitle cue may be. A cue that starts and ends on the same
  /// millisecond is legal in both formats and invisible in every player, which looks
  /// exactly like a dropped line of transcript.
  public var minimumCueMilliseconds: Int

  public init(
    labels: MeetingSpeakerLabels = .default,
    includeSummary: Bool = true,
    includeTimestamps: Bool = true,
    assumedSegmentMilliseconds: Int = 2_000,
    minimumCueMilliseconds: Int = 1_000
  ) {
    self.labels = labels
    self.includeSummary = includeSummary
    self.includeTimestamps = includeTimestamps
    self.assumedSegmentMilliseconds = assumedSegmentMilliseconds
    self.minimumCueMilliseconds = minimumCueMilliseconds
  }

  public static let `default` = MeetingExportOptions()
}

/// Renders a meeting into each supported format.
///
/// Pure functions over values: no file system, no store, no clock. Export is the
/// feature most likely to be run on a meeting from six months ago, and a renderer
/// that reads the current date or the current settings is a renderer that produces a
/// different file every time you run it.
public enum MeetingExport {

  // MARK: - Timestamps

  /// `HH:MM:SS` plus a separator and three digits of milliseconds.
  ///
  /// The separator is the entire difference between the two subtitle formats — SRT
  /// wants a comma, WebVTT wants a full stop — and a player given the wrong one
  /// rejects the file outright rather than degrading, so it is a parameter and both
  /// callers are tested.
  public static func timecode(milliseconds: Int, millisecondSeparator: String) -> String {
    let total = max(0, milliseconds)
    let hours = total / 3_600_000
    let minutes = (total % 3_600_000) / 60_000
    let seconds = (total % 60_000) / 1_000
    let remainder = total % 1_000
    let clock = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    return clock + millisecondSeparator + String(format: "%03d", remainder)
  }

  public static func srtTimestamp(_ milliseconds: Int) -> String {
    timecode(milliseconds: milliseconds, millisecondSeparator: ",")
  }

  public static func vttTimestamp(_ milliseconds: Int) -> String {
    timecode(milliseconds: milliseconds, millisecondSeparator: ".")
  }

  /// `HH:MM:SS`, or `MM:SS` under an hour. Used in the readable formats, where three
  /// digits of milliseconds are noise.
  public static func clock(milliseconds: Int) -> String {
    let total = max(0, milliseconds)
    let hours = total / 3_600_000
    let minutes = (total % 3_600_000) / 60_000
    let seconds = (total % 60_000) / 1_000
    if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  /// Resolves the end of a cue.
  ///
  /// Providers report an end time inconsistently and sometimes report one equal to
  /// the start. Both cases have to become a visible cue, and neither may run over the
  /// next speaker: an overlapping pair makes some players show only the first, which
  /// silently loses a line of somebody's meeting.
  public static func cueEnd(
    for segment: MeetingSegment,
    next: MeetingSegment?,
    options: MeetingExportOptions = .default
  ) -> Int {
    let start = max(0, segment.startedMilliseconds)
    let ceiling = next.map { max(start, $0.startedMilliseconds) }

    var end = segment.endedMilliseconds ?? (start + options.assumedSegmentMilliseconds)
    if end <= start { end = start + options.minimumCueMilliseconds }
    if let ceiling, ceiling > start { end = min(end, ceiling) }
    // A next segment starting on the same millisecond leaves no room at all, and a
    // zero-length cue is worse than a brief overlap.
    return max(end, start + 1)
  }

  // MARK: - Subtitles

  public static func srt(
    _ segments: [MeetingSegment], options: MeetingExportOptions = .default
  ) -> String {
    var blocks: [String] = []
    for (index, segment) in segments.enumerated() {
      let next = index + 1 < segments.count ? segments[index + 1] : nil
      let start = max(0, segment.startedMilliseconds)
      let end = cueEnd(for: segment, next: next, options: options)
      blocks.append(
        """
        \(index + 1)
        \(srtTimestamp(start)) --> \(srtTimestamp(end))
        \(segment.displayName(options.labels)): \(segment.text)
        """)
    }
    // SRT blocks are separated by a blank line, and the file ends with one.
    return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
  }

  public static func vtt(
    _ segments: [MeetingSegment], options: MeetingExportOptions = .default
  ) -> String {
    var lines = ["WEBVTT", ""]
    for (index, segment) in segments.enumerated() {
      let next = index + 1 < segments.count ? segments[index + 1] : nil
      let start = max(0, segment.startedMilliseconds)
      let end = cueEnd(for: segment, next: next, options: options)
      lines.append("\(vttTimestamp(start)) --> \(vttTimestamp(end))")
      lines.append("\(segment.displayName(options.labels)): \(segment.text)")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Readable

  public static func markdown(
    meeting: Meeting,
    segments: [MeetingSegment],
    summary: MeetingSummary? = nil,
    options: MeetingExportOptions = .default
  ) -> String {
    var lines: [String] = []
    lines.append("# \(meeting.title ?? "Meeting")")
    lines.append("")
    lines.append("*\(header(for: meeting))*")

    if options.includeSummary, let summary {
      if !summary.overview.isEmpty {
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append(summary.overview)
      }
      appendList(summary.actionItems, heading: "Action items", to: &lines)
      appendList(summary.decisions, heading: "Decisions", to: &lines)
      appendList(summary.questions, heading: "Open questions", to: &lines)
      if !summary.keyMoments.isEmpty {
        lines.append("")
        lines.append("## Key moments")
        lines.append("")
        for moment in summary.keyMoments {
          lines.append(
            "- `\(clock(milliseconds: moment.startedMilliseconds))` "
              + "**\(options.labels.label(for: moment.channel))** — \(moment.text)")
        }
      }
      if summary.isFallback {
        lines.append("")
        lines.append(
          "> These notes were extracted from the transcript without a language model, "
            + "so they quote what was said rather than summarising it.")
      }
    }

    lines.append("")
    lines.append("## Transcript")
    lines.append("")
    for segment in segments {
      let name = segment.displayName(options.labels)
      if options.includeTimestamps {
        lines.append(
          "`\(clock(milliseconds: segment.startedMilliseconds))` **\(name):** \(segment.text)")
      } else {
        lines.append("**\(name):** \(segment.text)")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  public static func plainText(
    meeting: Meeting,
    segments: [MeetingSegment],
    summary: MeetingSummary? = nil,
    options: MeetingExportOptions = .default
  ) -> String {
    var lines: [String] = []
    lines.append(meeting.title ?? "Meeting")
    lines.append(header(for: meeting))

    if options.includeSummary, let summary {
      if !summary.overview.isEmpty {
        lines.append("")
        lines.append("SUMMARY")
        lines.append(summary.overview)
      }
      appendPlainList(summary.actionItems, heading: "ACTION ITEMS", to: &lines)
      appendPlainList(summary.decisions, heading: "DECISIONS", to: &lines)
      appendPlainList(summary.questions, heading: "OPEN QUESTIONS", to: &lines)
    }

    lines.append("")
    lines.append("TRANSCRIPT")
    for segment in segments {
      let name = segment.displayName(options.labels)
      if options.includeTimestamps {
        lines.append("[\(clock(milliseconds: segment.startedMilliseconds))] \(name): \(segment.text)")
      } else {
        lines.append("\(name): \(segment.text)")
      }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  // MARK: - JSON

  /// The JSON shape, declared rather than assembled by hand so it stays stable and
  /// so anybody scripting against an export has something to read.
  public struct Document: Codable, Equatable, Sendable {
    public struct MeetingPayload: Codable, Equatable, Sendable {
      public var id: Int64?
      public var title: String?
      public var startedAt: Date
      public var endedAt: Date?
      public var appName: String?
      public var calendarEventID: String?
      public var durationMilliseconds: Int
      public var contentHash: String
      public var source: String
    }

    public var formatVersion: Int
    public var meeting: MeetingPayload
    public var summary: MeetingSummary?
    public var segments: [MeetingSegment]
  }

  public static func json(
    meeting: Meeting,
    segments: [MeetingSegment],
    summary: MeetingSummary? = nil
  ) throws -> String {
    let document = Document(
      formatVersion: 1,
      meeting: Document.MeetingPayload(
        id: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
        endedAt: meeting.endedAt, appName: meeting.appName,
        calendarEventID: meeting.calendarEventID,
        durationMilliseconds: meeting.durationMilliseconds,
        contentHash: meeting.contentHash, source: meeting.source),
      summary: summary,
      segments: segments)

    let encoder = JSONEncoder()
    // Sorted and pretty on purpose: an export people diff, read and check into a
    // notes repository is worth more than one that saves a few bytes.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(document), as: UTF8.self)
  }

  // MARK: - Entry point

  public static func render(
    _ format: MeetingExportFormat,
    meeting: Meeting,
    segments: [MeetingSegment],
    summary: MeetingSummary? = nil,
    options: MeetingExportOptions = .default
  ) throws -> String {
    switch format {
    case .markdown:
      markdown(meeting: meeting, segments: segments, summary: summary, options: options)
    case .text:
      plainText(meeting: meeting, segments: segments, summary: summary, options: options)
    case .json:
      try json(meeting: meeting, segments: segments, summary: summary)
    case .srt:
      srt(segments, options: options)
    case .vtt:
      vtt(segments, options: options)
    }
  }

  /// A file name that sorts by date and contains nothing a file system objects to.
  public static func fileName(for meeting: Meeting, format: MeetingExportFormat) -> String {
    let stamp = Self.fileDateFormatter.string(from: meeting.startedAt)
    let title = (meeting.title ?? "meeting")
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .prefix(6)
      .joined(separator: "-")
      .lowercased()
    let name = title.isEmpty ? "meeting" : title
    return "\(stamp)-\(name).\(format.fileExtension)"
  }

  // MARK: - Helpers

  private static func appendList(_ items: [String], heading: String, to lines: inout [String]) {
    guard !items.isEmpty else { return }
    lines.append("")
    lines.append("## \(heading)")
    lines.append("")
    for item in items { lines.append("- \(item)") }
  }

  private static func appendPlainList(
    _ items: [String], heading: String, to lines: inout [String]
  ) {
    guard !items.isEmpty else { return }
    lines.append("")
    lines.append(heading)
    for item in items { lines.append("- \(item)") }
  }

  static func header(for meeting: Meeting) -> String {
    var parts = [dateFormatter.string(from: meeting.startedAt)]
    if meeting.durationMilliseconds > 0 {
      parts.append(clock(milliseconds: meeting.durationMilliseconds))
    }
    if let appName = meeting.appName, !appName.isEmpty { parts.append(appName) }
    return parts.joined(separator: " · ")
  }

  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  static let fileDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}
