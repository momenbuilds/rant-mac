import Foundation

/// A conferencing service Rant can recognise a link for.
public enum MeetingPlatform: String, Sendable, Codable, CaseIterable {
  case zoom
  case googleMeet
  case microsoftTeams
  case webex

  public var displayName: String {
    switch self {
    case .zoom: "Zoom"
    case .googleMeet: "Google Meet"
    case .microsoftTeams: "Microsoft Teams"
    case .webex: "Webex"
    }
  }
}

/// A join link found in an event.
public struct MeetingJoinLink: Equatable, Sendable, Codable {
  public var platform: MeetingPlatform
  public var url: String

  public init(platform: MeetingPlatform, url: String) {
    self.platform = platform
    self.url = url
  }
}

/// One calendar entry, reduced to the fields a notetaker needs.
///
/// A value type rather than an `EKEvent`, so everything downstream — matching,
/// vocabulary, tests — works without EventKit and without a calendar database. It
/// also bounds what the rest of the app can ever see of somebody's calendar.
public struct CalendarEvent: Equatable, Sendable {
  public var id: String
  public var title: String
  public var startDate: Date
  public var endDate: Date
  public var location: String?
  public var notes: String?
  public var attendees: [String]
  public var organiser: String?
  public var isAllDay: Bool

  public init(
    id: String,
    title: String,
    startDate: Date,
    endDate: Date,
    location: String? = nil,
    notes: String? = nil,
    attendees: [String] = [],
    organiser: String? = nil,
    isAllDay: Bool = false
  ) {
    self.id = id
    self.title = title
    self.startDate = startDate
    self.endDate = endDate
    self.location = location
    self.notes = notes
    self.attendees = attendees
    self.organiser = organiser
    self.isAllDay = isAllDay
  }

  /// The first recognised join link in the location, the URL field or the notes.
  /// Location first, because that is where every calendar client puts it when it
  /// knows what it is, and notes are where it ends up when somebody pasted it.
  public var joinLink: MeetingJoinLink? {
    MeetingLinkExtractor.firstLink(in: [location, notes])
  }

  public var durationSeconds: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
}

/// Reads a calendar. Read-only by construction: there is no write method to call by
/// accident, and no implementation of this protocol sends anything anywhere.
public protocol CalendarProviding: Sendable {
  /// Whether access has been granted. Never assumed — a bridge that has not asked
  /// reports false and returns nothing.
  var hasAccess: Bool { get async }
  /// Asks the user. Returns whether it was granted.
  func requestAccess() async -> Bool
  func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

extension CalendarProviding {
  /// Events starting between now and `interval` from now.
  public func upcomingEvents(
    within interval: TimeInterval = 3_600, from now: Date = Date()
  ) async -> [CalendarEvent] {
    // A window that begins slightly in the past, because the meeting you want to
    // record is often the one that started two minutes ago.
    await events(from: now.addingTimeInterval(-900), to: now.addingTimeInterval(interval))
      .filter { !$0.isAllDay }
      .sorted { $0.startDate < $1.startDate }
  }
}

// MARK: - Link extraction

/// Finds conferencing links in free text.
///
/// A character scan, not a pattern. Calendar notes are long, arbitrary, and often
/// pasted from HTML mail; that is precisely the input that turned a lazy regex into a
/// hang in this codebase once already, and there is nothing a pattern would buy here
/// that a scan does not.
public enum MeetingLinkExtractor {

  /// Hosts that identify a platform. Matched by suffix so `company.zoom.us` and
  /// `zoom.us` both work, without a pattern and without matching `notzoom.us`.
  static let hostSuffixes: [(String, MeetingPlatform)] = [
    ("zoom.us", .zoom),
    ("zoomgov.com", .zoom),
    ("meet.google.com", .googleMeet),
    ("teams.microsoft.com", .microsoftTeams),
    ("teams.live.com", .microsoftTeams),
    ("webex.com", .webex),
  ]

  public static func platform(forHost host: String) -> MeetingPlatform? {
    let lowered = host.lowercased()
    for (suffix, platform) in hostSuffixes {
      if lowered == suffix || lowered.hasSuffix("." + suffix) { return platform }
    }
    return nil
  }

  /// The host part of an absolute URL, without scheme, credentials or port.
  public static func host(of url: String) -> String? {
    guard let schemeEnd = url.range(of: "://") else { return nil }
    var authority = url[schemeEnd.upperBound...]
    if let terminator = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
      authority = authority[..<terminator]
    }
    if let at = authority.lastIndex(of: "@") {
      authority = authority[authority.index(after: at)...]
    }
    if let colon = authority.firstIndex(of: ":") {
      authority = authority[..<colon]
    }
    return authority.isEmpty ? nil : String(authority)
  }

  /// Every recognised join link in `text`, in the order they appear, deduplicated.
  public static func links(in text: String?) -> [MeetingJoinLink] {
    guard let text, !text.isEmpty else { return [] }
    var found: [MeetingJoinLink] = []
    var seen = Set<String>()
    for token in tokens(in: text) {
      let candidate = normalise(token)
      guard let candidate,
        let host = host(of: candidate),
        let platform = platform(forHost: host),
        !seen.contains(candidate)
      else { continue }
      seen.insert(candidate)
      found.append(MeetingJoinLink(platform: platform, url: candidate))
    }
    return found
  }

  /// The first link across several fields, tried in order.
  public static func firstLink(in candidates: [String?]) -> MeetingJoinLink? {
    for candidate in candidates {
      if let link = links(in: candidate).first { return link }
    }
    return nil
  }

  /// Splits on whitespace and the brackets mail clients wrap URLs in. Linear in the
  /// length of the text.
  static func tokens(in text: String) -> [String] {
    text.split(whereSeparator: { character in
      character.isWhitespace || character == "<" || character == ">" || character == "\""
        || character == "(" || character == ")" || character == "[" || character == "]"
        || character == ","
    }).map(String.init)
  }

  /// Turns a token into an absolute URL if it looks like one, trimming the sentence
  /// punctuation that ends up stuck to a pasted link.
  static func normalise(_ token: String) -> String? {
    var text = Substring(token)
    while let last = text.last, ".;:!?'".contains(last) { text = text.dropLast() }
    guard !text.isEmpty else { return nil }
    let lowered = text.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return String(text) }
    // A bare `zoom.us/j/123` is still a join link, and people do paste them.
    guard let slash = lowered.firstIndex(of: "/") else { return nil }
    let possibleHost = String(lowered[..<slash])
    guard platform(forHost: possibleHost) != nil else { return nil }
    return "https://" + text
  }
}

// MARK: - Matching and vocabulary

/// Joining a recording to a calendar entry, and mining that entry for words the
/// transcriber should expect.
public enum CalendarMatcher {

  /// The event a meeting that started at `start` most likely belongs to.
  ///
  /// An event whose span contains the start wins; otherwise the nearest start within
  /// `tolerance`. Ties go to the shorter event, because a stand-up nested inside a
  /// day-long "focus block" is the one you are actually in. All-day entries never
  /// match: they are not meetings and matching one would put the wrong title on
  /// every recording made that day.
  public static func event(
    matching start: Date, in events: [CalendarEvent], tolerance: TimeInterval = 600
  ) -> CalendarEvent? {
    var best: (contains: Bool, distance: TimeInterval, duration: TimeInterval, event: CalendarEvent)?
    for event in events where !event.isAllDay {
      let contains = start >= event.startDate && start <= event.endDate
      let distance = abs(start.timeIntervalSince(event.startDate))
      guard contains || distance <= tolerance else { continue }
      let candidate = (contains, distance, event.durationSeconds, event)
      guard let current = best else {
        best = candidate
        continue
      }
      if isBetter(candidate, than: current) { best = candidate }
    }
    return best?.event
  }

  private static func isBetter(
    _ lhs: (contains: Bool, distance: TimeInterval, duration: TimeInterval, event: CalendarEvent),
    than rhs: (contains: Bool, distance: TimeInterval, duration: TimeInterval, event: CalendarEvent)
  ) -> Bool {
    if lhs.contains != rhs.contains { return lhs.contains }
    if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
    if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
    return lhs.event.id < rhs.event.id
  }

  static let stopWords: Set<String> = [
    "the", "and", "for", "with", "call", "sync", "meeting", "weekly", "daily",
    "monthly", "catch", "chat", "review", "standup", "stand", "up", "check", "in",
    "invite", "zoom", "meet", "teams", "webex", "http", "https", "www",
  ]

  /// Names and distinctive words from an event, to prime the transcriber.
  ///
  /// Attendee names first: a transcriber that has been told "Siobhán" is in the room
  /// spells it correctly, and no amount of cleanup afterwards recovers it otherwise.
  /// This is the only use the calendar is put to, it happens entirely on the machine,
  /// and none of it is ever sent anywhere by this type.
  public static func vocabulary(for event: CalendarEvent, limit: Int = 40) -> [String] {
    var words: [String] = []
    var seen = Set<String>()

    func add(_ candidate: String) {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count > 2 else { return }
      let key = trimmed.lowercased()
      guard !stopWords.contains(key), !seen.contains(key), words.count < limit else { return }
      seen.insert(key)
      words.append(trimmed)
    }

    for attendee in event.attendees {
      for part in attendee.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) {
        add(String(part))
      }
    }
    if let organiser = event.organiser {
      for part in organiser.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }) {
        add(String(part))
      }
    }
    for part in event.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
      add(String(part))
    }
    return words
  }

  /// A title for a recording that started at `start`, from the calendar when there is
  /// a confident match and from the clock when there is not.
  public static func suggestedTitle(
    for start: Date, events: [CalendarEvent], tolerance: TimeInterval = 600
  ) -> String? {
    event(matching: start, in: events, tolerance: tolerance)?.title
  }
}

// MARK: - Fixture

/// A calendar made of literals. Every calendar test uses this, so no test needs the
/// user's real calendar or a permission prompt.
public final class FixtureCalendar: CalendarProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [CalendarEvent]
  private var granted: Bool
  public private(set) var requestCount = 0

  public init(events: [CalendarEvent] = [], granted: Bool = true) {
    self.stored = events
    self.granted = granted
  }

  public var hasAccess: Bool { get async { lock.withLock { granted } } }

  public func requestAccess() async -> Bool {
    lock.withLock {
      requestCount += 1
      return granted
    }
  }

  public func events(from start: Date, to end: Date) async -> [CalendarEvent] {
    lock.withLock {
      guard granted else { return [] }
      return stored.filter { $0.startDate < end && $0.endDate > start.addingTimeInterval(-1) }
    }
  }
}

// MARK: - EventKit

#if canImport(EventKit)
  @preconcurrency import EventKit

  /// The real calendar, read-only.
  ///
  /// Kept deliberately thin: it asks for permission, reads events in a window, and
  /// converts them to `CalendarEvent`. Every decision made about a calendar entry —
  /// which event a recording belongs to, what a join link is, which words to prime
  /// the transcriber with — lives in the pure types above, where it is tested.
  ///
  /// Nothing here writes to the calendar, and nothing here has a network path. The
  /// calendar is read on the machine, used on the machine, and never leaves it.
  public actor EventKitCalendarBridge: CalendarProviding {
    private let store = EKEventStore()
    private var granted = false
    private let log = RantLog("Notetaker")

    public init() {}

    public var hasAccess: Bool { granted }

    /// Asks explicitly rather than letting the first read trigger the system prompt,
    /// so the app can explain why it wants the calendar before the sheet appears.
    public func requestAccess() async -> Bool {
      do {
        granted = try await store.requestFullAccessToEvents()
      } catch {
        granted = false
        log.warning("calendar access was refused")
      }
      return granted
    }

    public func events(from start: Date, to end: Date) async -> [CalendarEvent] {
      guard granted, start < end else { return [] }
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
      return store.events(matching: predicate)
        .map(CalendarEvent.init(_:))
        .sorted { $0.startDate < $1.startDate }
    }
  }

  extension CalendarEvent {
    init(_ event: EKEvent) {
      self.init(
        id: event.eventIdentifier ?? event.calendarItemIdentifier,
        title: event.title ?? "",
        startDate: event.startDate ?? Date(),
        endDate: event.endDate ?? event.startDate ?? Date(),
        location: [event.location, event.url?.absoluteString]
          .compactMap { $0 }
          .joined(separator: " "),
        notes: event.notes,
        attendees: event.attendees?.compactMap(\.name) ?? [],
        organiser: event.organizer?.name,
        isAllDay: event.isAllDay)
    }
  }
#endif
