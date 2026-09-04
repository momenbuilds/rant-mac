#if canImport(EventKit)
import EventKit
import Foundation

/// `CalendarProviding` backed by the local macOS Calendar.
///
/// `CalendarProviding` had only a fixture conformer, so the calendar features the
/// notetaker is built around — naming a meeting, finding its join link — had nothing
/// real behind them.
///
/// Read-only, and only ever a window of events around now. Rant asks EventKit for
/// events in a date range rather than enumerating calendars, so what leaves the store
/// is bounded by the question rather than by what we remember to filter afterwards.
/// Nothing here is uploaded: the join link and title are used locally, and the master
/// prompt (§24) is explicit that the calendar database never leaves the machine.
public final class EventKitCalendar: CalendarProviding, @unchecked Sendable {
  private let store = EKEventStore()
  private let log = RantLog("Calendar")

  public init() {}

  public var hasAccess: Bool {
    get async { Self.isAuthorised(EKEventStore.authorizationStatus(for: .event)) }
  }

  /// Never assumed: a bridge that has not asked reports false and returns nothing.
  private static func isAuthorised(_ status: EKAuthorizationStatus) -> Bool {
    switch status {
    case .fullAccess, .authorized: true
    // `.writeOnly` is genuinely useless here — Rant only ever reads.
    case .notDetermined, .denied, .restricted, .writeOnly: false
    @unknown default: false
    }
  }

  public func requestAccess() async -> Bool {
    if await hasAccess { return true }
    do {
      // The read-only grant, which is all Rant can use and all it should ask for.
      return try await store.requestFullAccessToEvents()
    } catch {
      log.warning("calendar access was refused: \(error.localizedDescription)")
      return false
    }
  }

  public func events(from start: Date, to end: Date) async -> [CalendarEvent] {
    guard await hasAccess, start < end else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate).map(Self.convert)
  }

  /// EventKit's model, reduced to the handful of fields Rant has a use for.
  ///
  /// Deliberately narrow. Rant needs a title, a time and somewhere to look for a join
  /// link; it has no reason to carry the rest of somebody's calendar entry around in
  /// memory, so it does not copy it.
  private static func convert(_ event: EKEvent) -> CalendarEvent {
    CalendarEvent(
      id: event.eventIdentifier ?? UUID().uuidString,
      title: event.title ?? "Untitled event",
      startDate: event.startDate ?? Date(),
      endDate: event.endDate ?? event.startDate ?? Date(),
      location: event.location,
      notes: event.notes,
      attendees: event.attendees?.compactMap { $0.name } ?? [],
      organiser: event.organizer?.name,
      isAllDay: event.isAllDay)
  }
}
#endif
