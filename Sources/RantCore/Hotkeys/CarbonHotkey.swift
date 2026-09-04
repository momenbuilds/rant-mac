#if canImport(Carbon)
import AppKit
import Carbon.HIToolbox

/// A global hotkey that needs **no Accessibility permission**.
///
/// The event tap Rant prefers can watch a lone modifier — hold Right ⌘ and talk —
/// but it requires Accessibility, which macOS will not let an application grant
/// itself. On a fresh install that leaves the app inert until someone visits System
/// Settings, and an app that does nothing until you have read its documentation is an
/// app most people delete.
///
/// `RegisterEventHotKey` is the old Carbon API and it is still the only way to claim a
/// system-wide shortcut with no permission at all. The trade-off is real and worth
/// stating: it can only bind a *combination* — a key plus modifiers — so the
/// hold-to-talk gesture on a bare modifier is not available here. What it gives is a
/// working product from the first launch: press the combination, speak, press again.
///
/// So Rant uses both. This is the fallback while Accessibility is missing, and the
/// event tap takes over the moment the permission arrives.
public final class CarbonHotkey: @unchecked Sendable {

  /// A key and its modifiers, in Carbon's vocabulary.
  public struct Combination: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let displayName: String

    public init(keyCode: UInt32, modifiers: UInt32, displayName: String) {
      self.keyCode = keyCode
      self.modifiers = modifiers
      self.displayName = displayName
    }

    /// ⌥Space. Chosen because it is unclaimed on a default macOS install, reachable
    /// with one hand, and hard to press by accident while typing prose.
    public static let optionSpace = Combination(
      keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), displayName: "⌥Space")

    /// ⌃⌥D, for anyone whose ⌥Space is already taken by a launcher.
    public static let controlOptionD = Combination(
      keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey),
      displayName: "⌃⌥D")

    /// ⌥⇧T — transform the selection. A combination rather than a lone modifier,
    /// because unlike dictation this acts on text that is already selected and a
    /// misfire would rewrite it.
    public static let optionShiftT = Combination(
      keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey),
      displayName: "⌥⇧T")

    /// ⌥⇧C — command mode. Distinct from the dictation key, as the spec requires:
    /// "make this shorter" must be an instruction, not something typed into the
    /// document.
    public static let optionShiftC = Combination(
      keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | shiftKey),
      displayName: "⌥⇧C")
  }

  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let onPress: @Sendable () -> Void
  private let log = RantLog("CarbonHotkey")
  public let combination: Combination

  /// Carbon hands the callback a raw pointer rather than a context object, so the
  /// live instances are kept here and looked up by the id in the event.
  nonisolated(unsafe) private static var registry: [UInt32: CarbonHotkey] = [:]
  nonisolated(unsafe) private static var nextID: UInt32 = 1
  private static let lock = NSLock()
  private let identifier: UInt32

  public init(_ combination: Combination, onPress: @escaping @Sendable () -> Void) {
    self.combination = combination
    self.onPress = onPress
    self.identifier = Self.lock.withLock {
      defer { Self.nextID += 1 }
      return Self.nextID
    }
  }

  deinit { unregister() }

  /// Claims the shortcut. Returns false when something else already owns it, which is
  /// information the user needs rather than a silent failure.
  @discardableResult
  public func register() -> Bool {
    guard reference == nil else { return true }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

    let callback: EventHandlerUPP = { _, event, _ in
      guard let event else { return noErr }
      var hotKeyID = EventHotKeyID()
      let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      guard status == noErr else { return noErr }
      let hotkey = CarbonHotkey.lock.withLock { CarbonHotkey.registry[hotKeyID.id] }
      hotkey?.onPress()
      return noErr
    }

    InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler)

    let hotKeyID = EventHotKeyID(signature: OSType(0x52_41_4E_54), id: identifier)  // 'RANT'
    let status = RegisterEventHotKey(
      combination.keyCode, combination.modifiers, hotKeyID, GetApplicationEventTarget(), 0,
      &reference)

    guard status == noErr, reference != nil else {
      log.warning("could not claim \(combination.displayName); something else owns it")
      return false
    }
    Self.lock.withLock { Self.registry[identifier] = self }
    log.info("registered \(combination.displayName) without Accessibility")
    return true
  }

  public func unregister() {
    if let reference {
      UnregisterEventHotKey(reference)
      self.reference = nil
    }
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
    Self.lock.withLock { Self.registry[identifier] = nil }
  }
}
#endif
