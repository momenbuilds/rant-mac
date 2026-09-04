import Foundation

/// The keys Rant can be triggered by. A *lone modifier* is the interesting case:
/// it types nothing on its own, so we can claim it without stealing a shortcut —
/// but only if we are careful to let ⌘C through untouched.
public enum TriggerKey: String, Codable, Sendable, CaseIterable {
  case rightCommand, leftCommand, rightOption, leftOption, rightControl, fnGlobe

  public var isModifier: Bool { true }

  public var displayName: String {
    switch self {
    case .rightCommand: "Right ⌘"
    case .leftCommand: "Left ⌘"
    case .rightOption: "Right ⌥"
    case .leftOption: "Left ⌥"
    case .rightControl: "Right ⌃"
    case .fnGlobe: "Fn / 🌐"
    }
  }
}

/// What the gate observed. The adapter over `CGEventTap` translates raw events into
/// exactly these; nothing else about the event reaches the state machine.
public enum GateEvent: Equatable, Sendable {
  /// The trigger key went down, with the set of *other* modifiers held at that moment.
  case triggerDown(otherModifiersHeld: Bool)
  /// The trigger key came up.
  case triggerUp
  /// Any non-trigger key was pressed while the trigger was held — which means the
  /// user is typing a shortcut, not starting a dictation.
  case otherKeyDown
  /// Escape.
  case escape
  /// The user asked to stop from somewhere other than the keyboard (overlay button,
  /// menu bar item).
  case externalStop
  /// The session finished or failed on its own.
  case sessionEnded
}

/// What the world should do about it.
public enum GateAction: Equatable, Sendable {
  case startRecording(Recording)
  /// Upgrade the recording that is *already running* to hands-free. Deliberately
  /// distinct from `startRecording(.handsFree)`: a double-tap must not discard the
  /// audio captured during the first tap, so the caller keeps its existing capture
  /// and only changes how it will end.
  case promoteToHandsFree
  case stopAndTranscribe
  case cancel
  /// Let the keystroke reach the app underneath. The tap consumes the event only
  /// when this is absent, so a shortcut is never swallowed.
  case passThrough

  public enum Recording: Equatable, Sendable {
    /// Ends when the key is released.
    case pushToTalk
    /// Ends on the next tap of the trigger.
    case toggled
    /// Ends only on an explicit stop — the double-tap "hands free" case.
    case handsFree
  }
}

/// The activation styles a user can choose.
public enum ActivationMode: String, Codable, Sendable, CaseIterable {
  /// Hold to talk; a quick tap does nothing.
  case holdOnly
  /// Tap to start, tap to stop; holding also works and behaves as push-to-talk.
  case hybrid
  /// Tap to toggle only; holding is treated as a long toggle.
  case toggleOnly

  public var displayName: String {
    switch self {
    case .holdOnly: "Hold to talk"
    case .hybrid: "Hold to talk, tap to toggle"
    case .toggleOnly: "Tap to toggle"
    }
  }
}

/// Timing thresholds, in seconds. Separated out so tests can state them explicitly
/// rather than depending on whatever the defaults happen to be.
public struct GateTimings: Equatable, Sendable {
  /// Below this, a press is a *tap*; at or above it, a *hold*.
  public var tapThreshold: TimeInterval
  /// Two taps closer together than this are a double-tap.
  public var doubleTapWindow: TimeInterval

  public init(tapThreshold: TimeInterval = 0.28, doubleTapWindow: TimeInterval = 0.35) {
    self.tapThreshold = tapThreshold
    self.doubleTapWindow = doubleTapWindow
  }

  public static let `default` = GateTimings()
}

/// The decision layer for the trigger key: hold versus tap versus double-tap, and
/// whether a given press is a dictation at all or just the user reaching for ⌘C.
///
/// This is a value type on purpose. It owns no timer, opens no event tap, and reads
/// no clock — every input carries its own timestamp. That is what lets the test
/// suite drive thousands of event orderings deterministically, including the ones
/// that are painful to produce by hand: a modifier released after the shortcut it
/// belongs to, a double-tap whose second press is also a hold, an escape arriving
/// between the release and the transcript.
///
/// The effectful wrapper that owns the real `CGEventTap` lives in `HotkeyEngine`.
public struct DictationGate: Equatable, Sendable {
  public private(set) var state: State
  public var mode: ActivationMode
  public var timings: GateTimings

  /// Which flavour of recording is running. Kept separate from `State` so the
  /// "key is held down again while recording" case can name it without `State`
  /// becoming recursive.
  public enum RecordingKind: Equatable, Sendable {
    /// Started by a hold; ends on release.
    case hold
    /// Started by a tap; ends on the next tap.
    case toggled
    /// Double-tapped; ends only on an explicit stop.
    case handsFree
  }

  public enum State: Equatable, Sendable {
    case idle
    /// Trigger is down and we have not yet decided what the press means.
    case pressed(since: TimeInterval, contaminated: Bool)
    /// Audio is running.
    case recording(RecordingKind)
    /// Recording, and the trigger is currently held down again — we are waiting to
    /// see whether this press is the stop tap or a hold-to-stop.
    case recordingKeyHeld(RecordingKind, since: TimeInterval)
    /// Audio has stopped; the transcript is in flight. Escape still cancels.
    case finishing
  }

  /// Timestamp of the last completed tap, for double-tap detection.
  private var lastTapAt: TimeInterval?

  public init(
    mode: ActivationMode = .hybrid,
    timings: GateTimings = .default,
    state: State = .idle
  ) {
    self.mode = mode
    self.timings = timings
    self.state = state
  }

  /// True whenever audio is being captured — which includes the `pressed` state,
  /// because a hold starts recording on the way *down* rather than waiting to find
  /// out whether the press was a tap. A contaminated press started nothing.
  public var isRecording: Bool {
    switch state {
    case .recording, .recordingKeyHeld: true
    case .pressed(_, let contaminated): !contaminated && mode != .toggleOnly
    case .idle, .finishing: false
    }
  }

  /// Feed one event. Returns the actions the caller should perform, in order.
  ///
  /// `passThrough` is meaningful: the event tap consumes the trigger key only when
  /// the returned actions do *not* contain it, so a modifier that turned out to be
  /// part of a shortcut still reaches the focused app.
  public mutating func handle(_ event: GateEvent, at now: TimeInterval) -> [GateAction] {
    switch event {
    case .triggerDown(let otherModifiersHeld):
      return triggerDown(otherModifiersHeld: otherModifiersHeld, at: now)
    case .triggerUp:
      return triggerUp(at: now)
    case .otherKeyDown:
      return otherKeyDown()
    case .escape:
      return escape()
    case .externalStop:
      return externalStop()
    case .sessionEnded:
      state = .idle
      return []
    }
  }

  // MARK: - Individual transitions

  private mutating func triggerDown(otherModifiersHeld: Bool, at now: TimeInterval) -> [GateAction] {
    switch state {
    case .idle:
      // A trigger pressed *while another modifier is already down* is part of a
      // combination — ⌥⌘, say — and never a dictation. Mark it contaminated so the
      // eventual release does nothing but pass through.
      state = .pressed(since: now, contaminated: otherModifiersHeld)
      if otherModifiersHeld { return [.passThrough] }
      // In hold-capable modes we start immediately rather than waiting to find out
      // whether this is a tap. Waiting would clip the first syllable, which is the
      // single most noticeable failure in a dictation app. If it turns out to be a
      // tap we either keep going (hybrid, as a toggle) or cancel (hold-only) — and
      // cancelling a 200 ms recording costs nothing.
      switch mode {
      case .holdOnly, .hybrid:
        return [.startRecording(.pushToTalk)]
      case .toggleOnly:
        return []
      }

    case .recording(let kind):
      state = .recordingKeyHeld(kind, since: now)
      return []

    case .pressed, .recordingKeyHeld, .finishing:
      // Auto-repeat, or a press we are already reasoning about. Ignore.
      return []
    }
  }

  private mutating func triggerUp(at now: TimeInterval) -> [GateAction] {
    switch state {
    case .pressed(let since, let contaminated):
      let held = now - since
      let wasTap = held < timings.tapThreshold
      let doubleTap = wasTap && lastTapAt.map { now - $0 < timings.doubleTapWindow } ?? false

      if contaminated {
        // The press belonged to a shortcut. Nothing was started, nothing to stop.
        state = .idle
        lastTapAt = nil
        return [.passThrough]
      }

      if doubleTap {
        lastTapAt = nil
        state = .recording(.handsFree)
        return [.promoteToHandsFree]
      }

      if wasTap { lastTapAt = now }

      switch mode {
      case .holdOnly:
        if wasTap {
          state = .idle
          return [.cancel]
        }
        state = .finishing
        return [.stopAndTranscribe]

      case .hybrid:
        if wasTap {
          // Became a toggle. Keep recording; the next tap stops it.
          state = .recording(.toggled)
          return []
        }
        state = .finishing
        return [.stopAndTranscribe]

      case .toggleOnly:
        // Nothing was started on the way down.
        state = .recording(.toggled)
        return [.startRecording(.toggled)]
      }

    case .recordingKeyHeld(let kind, let since):
      // The common path: a press while recording means stop. But this is also where
      // the *second* tap of a double-tap lands — the first tap already left us
      // recording — so check for the promotion before treating it as a stop.
      let held = now - since
      let wasTap = held < timings.tapThreshold
      if wasTap, kind != .handsFree,
        let last = lastTapAt, now - last < timings.doubleTapWindow
      {
        lastTapAt = nil
        state = .recording(.handsFree)
        return [.promoteToHandsFree]
      }
      lastTapAt = nil
      state = .finishing
      return [.stopAndTranscribe]

    case .idle, .recording, .finishing:
      return []
    }
  }

  private mutating func otherKeyDown() -> [GateAction] {
    switch state {
    case .pressed(let since, let contaminated):
      guard !contaminated else { return [.passThrough] }
      // The trigger turned out to be the modifier half of a shortcut. Abandon the
      // recording we optimistically started and let the keystroke through.
      state = .pressed(since: since, contaminated: true)
      return [.cancel, .passThrough]
    default:
      return [.passThrough]
    }
  }

  private mutating func escape() -> [GateAction] {
    switch state {
    case .idle:
      return [.passThrough]
    case .pressed:
      state = .idle
      return [.cancel]
    case .recording, .recordingKeyHeld, .finishing:
      state = .idle
      lastTapAt = nil
      return [.cancel]
    }
  }

  /// Stop requested from the overlay button or the menu bar. Works from every
  /// recording state including a hold still physically held down — the key release
  /// that follows finds `finishing` and correctly does nothing.
  private mutating func externalStop() -> [GateAction] {
    guard isRecording else { return [] }
    state = .finishing
    lastTapAt = nil
    return [.stopAndTranscribe]
  }
}
