#if canImport(AppKit)
import AppKit
import Foundation

/// The thin effectful shell around `DictationGate`.
///
/// It owns the `CGEventTap` and the clock, translates raw events into the handful of
/// `GateEvent` cases the state machine understands, and performs the actions the gate
/// returns. It contains no decisions of its own — that is the whole point of the
/// split, because a `CGEventTap` cannot be unit tested and the decisions absolutely
/// must be.
///
/// The tap is a *listen-only* tap for modifier changes and a passive observer for
/// everything else, so Rant cannot swallow a keystroke it did not mean to. The one
/// case where the tap consumes an event is Escape while a recording is running,
/// because otherwise cancelling dictation also dismisses the dialog underneath.
public final class HotkeyEngine: @unchecked Sendable {

  public struct Configuration: Equatable, Sendable {
    public var trigger: TriggerKey
    public var mode: ActivationMode
    public var timings: GateTimings
    /// When false the tap is installed but ignores everything, so the user can
    /// disable dictation without losing their Accessibility grant.
    public var enabled: Bool

    public init(
      trigger: TriggerKey = .rightCommand,
      mode: ActivationMode = .hybrid,
      timings: GateTimings = .default,
      enabled: Bool = true
    ) {
      self.trigger = trigger
      self.mode = mode
      self.timings = timings
      self.enabled = enabled
    }
  }

  /// What the engine wants the app to do.
  public enum Command: Equatable, Sendable {
    case startRecording(GateAction.Recording)
    case promoteToHandsFree
    case stopAndTranscribe
    case cancel
  }

  private var gate: DictationGate
  private var configuration: Configuration
  private let handler: @Sendable (Command) -> Void
  private let log = RantLog("Hotkey")

  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let lock = NSRecursiveLock()

  public init(
    configuration: Configuration = Configuration(),
    handler: @escaping @Sendable (Command) -> Void
  ) {
    self.configuration = configuration
    self.handler = handler
    self.gate = DictationGate(mode: configuration.mode, timings: configuration.timings)
  }

  deinit { stop() }

  // MARK: - Tap lifecycle

  /// Installs the event tap. Requires Accessibility permission; returns false without
  /// it so the caller can show the onboarding step rather than failing silently.
  @discardableResult
  public func start() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard tap == nil else { return true }
    guard AXIsProcessTrusted() else {
      log.warning("cannot install event tap: Accessibility not granted to this bundle")
      return false
    }

    let mask =
      (1 << CGEventType.flagsChanged.rawValue)
      | (1 << CGEventType.keyDown.rawValue)

    let callback: CGEventTapCallBack = { proxy, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let engine = Unmanaged<HotkeyEngine>.fromOpaque(refcon).takeUnretainedValue()
      return engine.handle(proxy: proxy, type: type, event: event)
    }

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      log.error("event tap creation failed")
      return false
    }

    self.tap = tap
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log.info("event tap installed for \(configuration.trigger.rawValue)")
    return true
  }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }
    tap = nil
    runLoopSource = nil
  }

  public func update(_ configuration: Configuration) {
    lock.withLock {
      self.configuration = configuration
      gate.mode = configuration.mode
      gate.timings = configuration.timings
    }
  }

  /// Stop from the overlay button or the menu bar rather than the keyboard.
  public func requestStop() {
    dispatch(lock.withLock { gate.handle(.externalStop, at: Self.now()) })
  }

  public func requestCancel() {
    dispatch(lock.withLock { gate.handle(.escape, at: Self.now()) })
  }

  /// Tell the gate the pipeline finished, so a stray key release does not restart it.
  public func sessionEnded() {
    _ = lock.withLock { gate.handle(.sessionEnded, at: Self.now()) }
  }

  public var isRecording: Bool { lock.withLock { gate.isRecording } }

  // MARK: - Event translation

  private func handle(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    // macOS disables a tap that takes too long or when the system is under load. It
    // tells us, and the only correct response is to turn it straight back on —
    // otherwise the hotkey silently stops working until the app restarts.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      log.warning("event tap was disabled by the system; re-enabled")
      return Unmanaged.passUnretained(event)
    }

    guard lock.withLock({ configuration.enabled }) else { return Unmanaged.passUnretained(event) }

    let now = Self.now()
    var actions: [GateAction] = []
    var consume = false

    switch type {
    case .flagsChanged:
      let flags = event.flags
      let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      guard let trigger = lock.withLock({ configuration.trigger }).keyCode, keyCode == trigger
      else {
        // Some other modifier moved. If it went down while our trigger is held, the
        // user is building a shortcut.
        if lock.withLock({ gate.isRecording }) == false, !flags.isEmpty {
          actions = lock.withLock { gate.handle(.otherKeyDown, at: now) }
        }
        break
      }
      let isDown = Self.isDown(keyCode: keyCode, flags: flags)
      log.info("trigger key \(keyCode) \(isDown ? "down" : "up")")
      if isDown {
        let others = Self.otherModifiersPresent(flags, excluding: keyCode)
        actions = lock.withLock { gate.handle(.triggerDown(otherModifiersHeld: others), at: now) }
      } else {
        actions = lock.withLock { gate.handle(.triggerUp, at: now) }
      }

    case .keyDown:
      let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      if keyCode == 53 {  // Escape
        let recording = lock.withLock { gate.isRecording }
        actions = lock.withLock { gate.handle(.escape, at: now) }
        // Swallow Escape only while we are actually recording, so cancelling
        // dictation does not also dismiss whatever is on screen — and so Escape
        // behaves completely normally the rest of the time.
        consume = recording
      } else {
        actions = lock.withLock { gate.handle(.otherKeyDown, at: now) }
      }

    default:
      break
    }

    dispatch(actions)
    return consume ? nil : Unmanaged.passUnretained(event)
  }

  private func dispatch(_ actions: [GateAction]) {
    if !actions.isEmpty {
      log.info("gate produced \(actions.count) action(s)")
    }
    for action in actions {
      switch action {
      case .startRecording(let kind): handler(.startRecording(kind))
      case .promoteToHandsFree: handler(.promoteToHandsFree)
      case .stopAndTranscribe: handler(.stopAndTranscribe)
      case .cancel: handler(.cancel)
      case .passThrough: break
      }
    }
  }

  private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// A modifier's flags tell you the whole modifier state, not whether *this* key went
  /// down — so "is it down" means "is this key's flag bit set".
  static func isDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
    guard let required = TriggerKey.deviceFlag(for: keyCode) else { return false }
    return flags.rawValue & required != 0
  }

  static func otherModifiersPresent(_ flags: CGEventFlags, excluding keyCode: CGKeyCode) -> Bool {
    let interesting: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    var present = flags.intersection(interesting)
    if let own = TriggerKey.maskFlag(for: keyCode) { present.remove(own) }
    return !present.isEmpty
  }
}

extension TriggerKey {
  /// Virtual key codes for the individual left/right modifier keys.
  public var keyCode: CGKeyCode? {
    switch self {
    case .rightCommand: 54
    case .leftCommand: 55
    case .rightOption: 61
    case .leftOption: 58
    case .rightControl: 62
    case .fnGlobe: 63
    }
  }

  /// Device-dependent flag bits, which are how you tell left from right.
  /// These constants are stable in `IOKit`'s `NX_DEVICE*` set.
  static func deviceFlag(for keyCode: CGKeyCode) -> UInt64? {
    switch keyCode {
    case 54: 0x0000_0010  // NX_DEVICERCMDKEYMASK
    case 55: 0x0000_0008  // NX_DEVICELCMDKEYMASK
    case 61: 0x0000_0040  // NX_DEVICERALTKEYMASK
    case 58: 0x0000_0020  // NX_DEVICELALTKEYMASK
    case 62: 0x0000_2000  // NX_DEVICERCTLKEYMASK
    case 63: UInt64(CGEventFlags.maskSecondaryFn.rawValue)
    default: nil
    }
  }

  static func maskFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
    switch keyCode {
    case 54, 55: .maskCommand
    case 58, 61: .maskAlternate
    case 62: .maskControl
    case 63: .maskSecondaryFn
    default: nil
    }
  }
}
#endif
