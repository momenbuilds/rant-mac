import Foundation

/// One stretch of speech from one channel.
///
/// Times are milliseconds from the start of the meeting rather than wall-clock, so a
/// transcript stays readable after a pause, after an export, and after being read
/// back from SQLite on a machine in another time zone.
public struct MeetingSegment: Equatable, Sendable, Codable {
  public var id: Int64?
  public var meetingID: Int64?
  public var startedMilliseconds: Int
  /// Nil when the provider gave no end time. Export has to cope; see `MeetingExport`.
  public var endedMilliseconds: Int?
  /// A name, when something upstream knew one. Diarisation is provider-dependent and
  /// often absent, which is exactly why `channel` exists alongside it.
  public var speaker: String?
  public var channel: MeetingChannel
  public var text: String

  public init(
    id: Int64? = nil,
    meetingID: Int64? = nil,
    startedMilliseconds: Int,
    endedMilliseconds: Int? = nil,
    speaker: String? = nil,
    channel: MeetingChannel,
    text: String
  ) {
    self.id = id
    self.meetingID = meetingID
    self.startedMilliseconds = startedMilliseconds
    self.endedMilliseconds = endedMilliseconds
    self.speaker = speaker
    self.channel = channel
    self.text = text
  }

  /// What to print in front of the text: the diarised name when there is one, the
  /// channel label otherwise.
  public func displayName(_ labels: MeetingSpeakerLabels) -> String {
    if let speaker, !speaker.trimmingCharacters(in: .whitespaces).isEmpty { return speaker }
    return labels.label(for: channel)
  }

  public var durationMilliseconds: Int? {
    endedMilliseconds.map { max(0, $0 - startedMilliseconds) }
  }
}

/// Where a meeting is in its life.
///
/// `finalising` is a state rather than a flag because summarising a long meeting
/// takes seconds, and during those seconds the recording has stopped but the
/// transcript is not yet safe to close the window on. Conflating the two is how you
/// lose an hour of somebody's notes.
public enum MeetingSessionState: Equatable, Sendable {
  case idle
  case recording
  case paused
  case finalising
  case done
  case failed(String)

  public var isCapturing: Bool { self == .recording }

  public var isFinished: Bool {
    switch self {
    case .done, .failed: true
    case .idle, .recording, .paused, .finalising: false
    }
  }
}

/// Everything the outside world can tell a meeting.
public enum MeetingSessionEvent: Equatable, Sendable {
  case start(at: Date)
  /// A settled piece of transcript.
  case heard(MeetingSegment)
  /// Interim text for the live view. Replaced on every update and never stored.
  case partial(channel: MeetingChannel, text: String)
  case pause(at: Date)
  case resume(at: Date)
  case stop(at: Date)
  /// Persistence and summarising finished.
  case finalised
  case failed(String)
  /// Back to idle, discarding the transcript. Used by "start another meeting".
  case reset
}

/// What the caller should do about it.
public enum MeetingSessionAction: Equatable, Sendable {
  case beginCapture
  case pauseCapture
  case resumeCapture
  case endCapture
  /// Write the meeting and its segments to the store.
  case persist
  /// Run the summariser over the finished transcript.
  case summarise
  /// Throw the audio away without writing anything.
  case discard
}

/// The notetaker's decision layer.
///
/// A value type with no timer, no clock and no collaborators, for the same reason
/// `DictationGate` is one: the orderings that go wrong in a real meeting — a
/// transcript arriving after the user hit pause, a stop while a partial is in
/// flight, a failure during finalisation — are miserable to reproduce against live
/// audio and trivial to drive here. The effectful half lives in whatever owns a
/// `MeetingCaptureProvider`.
public struct MeetingSession: Equatable, Sendable {
  public private(set) var state: MeetingSessionState
  public private(set) var startedAt: Date?
  public private(set) var endedAt: Date?
  /// Settled transcript, in arrival order.
  public private(set) var segments: [MeetingSegment]
  /// Interim text per channel, for the live view only.
  public private(set) var partials: [MeetingChannel: String]
  /// Total time spent paused, so offsets do not drift across a long break.
  public private(set) var pausedSeconds: TimeInterval
  /// Transcript that arrived while paused and was deliberately dropped. Surfaced so
  /// the UI can be honest rather than leaving the user wondering where it went.
  public private(set) var droppedWhilePaused: Int

  public var title: String?
  public var calendarEventID: String?
  public var labels: MeetingSpeakerLabels
  /// Consecutive segments from the same channel closer together than this are joined
  /// when the transcript is rendered.
  public var coalesceGapMilliseconds: Int

  private var pausedAt: Date?

  public init(
    title: String? = nil,
    calendarEventID: String? = nil,
    labels: MeetingSpeakerLabels = .default,
    coalesceGapMilliseconds: Int = 1_500,
    state: MeetingSessionState = .idle
  ) {
    self.title = title
    self.calendarEventID = calendarEventID
    self.labels = labels
    self.coalesceGapMilliseconds = coalesceGapMilliseconds
    self.state = state
    self.startedAt = nil
    self.endedAt = nil
    self.segments = []
    self.partials = [:]
    self.pausedSeconds = 0
    self.droppedWhilePaused = 0
  }

  // MARK: - Transitions

  @discardableResult
  public mutating func handle(_ event: MeetingSessionEvent) -> [MeetingSessionAction] {
    switch event {
    case .start(let now):
      guard state == .idle else { return [] }
      startedAt = now
      endedAt = nil
      state = .recording
      return [.beginCapture]

    case .heard(let segment):
      // Anything transcribed while paused is dropped rather than stored. The pause
      // button has to mean what it says, even though audio already in flight will
      // land a moment after it is pressed.
      guard state == .recording else {
        if state == .paused { droppedWhilePaused += 1 }
        return []
      }
      guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return []
      }
      segments.append(segment)
      partials[segment.channel] = nil
      return []

    case .partial(let channel, let text):
      guard state == .recording else { return [] }
      partials[channel] = text
      return []

    case .pause(let now):
      guard state == .recording else { return [] }
      pausedAt = now
      partials = [:]
      state = .paused
      return [.pauseCapture]

    case .resume(let now):
      guard state == .paused else { return [] }
      if let pausedAt { pausedSeconds += max(0, now.timeIntervalSince(pausedAt)) }
      pausedAt = nil
      state = .recording
      return [.resumeCapture]

    case .stop(let now):
      switch state {
      case .recording, .paused:
        if state == .paused, let pausedAt {
          pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
        }
        self.pausedAt = nil
        endedAt = now
        partials = [:]
        state = .finalising
        // An empty meeting is not worth a row in the history, and writing one means
        // the user has to tidy up after every accidental start.
        guard !segments.isEmpty else {
          state = .done
          return [.endCapture, .discard]
        }
        return [.endCapture, .persist, .summarise]
      case .idle, .finalising, .done, .failed:
        return []
      }

    case .finalised:
      guard state == .finalising else { return [] }
      state = .done
      return []

    case .failed(let message):
      switch state {
      case .idle, .done, .failed:
        state = .failed(message)
        return []
      case .recording, .paused:
        state = .failed(message)
        // Capture still has to be torn down, and a failed meeting keeps whatever it
        // managed to transcribe: a provider that died at minute fifty must not cost
        // the first forty-nine.
        return segments.isEmpty ? [.endCapture, .discard] : [.endCapture, .persist]
      case .finalising:
        state = .failed(message)
        return []
      }

    case .reset:
      let keptLabels = labels
      let keptGap = coalesceGapMilliseconds
      self = MeetingSession(labels: keptLabels, coalesceGapMilliseconds: keptGap)
      return []
    }
  }

  // MARK: - Derived

  /// Milliseconds from the start of the meeting to `now`, discounting pauses. The
  /// number a transcription callback should stamp its segment with.
  public func offsetMilliseconds(at now: Date) -> Int {
    guard let startedAt else { return 0 }
    let elapsed = now.timeIntervalSince(startedAt) - pausedSeconds
    return max(0, Int(elapsed * 1000))
  }

  public var durationMilliseconds: Int {
    guard let startedAt else { return 0 }
    let end = endedAt ?? startedAt
    return max(0, Int((end.timeIntervalSince(startedAt) - pausedSeconds) * 1000))
  }

  public var wordCount: Int {
    segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
  }

  /// True when both sides were heard. A meeting with only one channel is a legitimate
  /// recording but a poor transcript, and the UI should say so.
  public var hasBothChannels: Bool {
    var seen = Set<MeetingChannel>()
    for segment in segments { seen.insert(segment.channel) }
    return seen.count == 2
  }

  /// Settled transcript with the interim text appended, ready for the live view.
  public func liveTranscript() -> String {
    var lines = Self.render(Self.coalesce(segments, gapMilliseconds: coalesceGapMilliseconds),
                            labels: labels)
    for channel in MeetingChannel.allCases {
      guard let text = partials[channel],
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      lines.append("\(labels.label(for: channel)): \(text)…")
    }
    return lines.joined(separator: "\n")
  }

  /// The settled transcript alone.
  public func transcript() -> String {
    Self.render(Self.coalesce(segments, gapMilliseconds: coalesceGapMilliseconds), labels: labels)
      .joined(separator: "\n")
  }

  /// Segments as they should be stored: coalesced, so a provider that emits a segment
  /// per breath does not fill the database with two-word rows that then make search
  /// snippets useless.
  public func storableSegments() -> [MeetingSegment] {
    Self.coalesce(segments, gapMilliseconds: coalesceGapMilliseconds)
  }

  // MARK: - Pure helpers

  /// Joins consecutive segments from the same channel that are close in time.
  ///
  /// Streaming providers emit a segment whenever they settle a phrase, which can be
  /// every second or two. Left alone that produces a transcript of fragments, an FTS
  /// index full of half-sentences, and subtitles that flash. Joining across a small
  /// gap fixes all three; joining across a large one would put a reply in the middle
  /// of somebody else's sentence, so the gap is a parameter and not a guess.
  public static func coalesce(
    _ segments: [MeetingSegment], gapMilliseconds: Int
  ) -> [MeetingSegment] {
    var result: [MeetingSegment] = []
    for segment in segments {
      guard var last = result.last,
        last.channel == segment.channel,
        last.speaker == segment.speaker,
        segment.startedMilliseconds - (last.endedMilliseconds ?? last.startedMilliseconds)
          <= gapMilliseconds
      else {
        result.append(segment)
        continue
      }
      last.text += " " + segment.text
      last.endedMilliseconds = segment.endedMilliseconds ?? last.endedMilliseconds
      result[result.count - 1] = last
    }
    return result
  }

  /// One line per segment, prefixed with who said it.
  public static func render(
    _ segments: [MeetingSegment], labels: MeetingSpeakerLabels
  ) -> [String] {
    segments.map { "\($0.displayName(labels)): \($0.text)" }
  }
}
