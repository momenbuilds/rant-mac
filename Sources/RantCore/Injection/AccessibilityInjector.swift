#if canImport(AppKit)
import AppKit
import ApplicationServices

/// Puts text where the user was typing, on a real Mac.
///
/// Two strategies, in order of preference:
///
/// 1. **Accessibility.** Set `AXSelectedText` on the focused element. This inserts at
///    the caret (or replaces the selection) with no synthesised keystrokes and no
///    clipboard involvement at all. It is instant and invisible — but plenty of apps
///    either do not implement it or implement it badly.
/// 2. **Clipboard and ⌘V.** Save whatever the user had copied, write the transcript,
///    synthesise ⌘V, then put their clipboard back after the paste has settled.
///
/// The subtle part is step 2's ending. The paste is asynchronous: `CGEvent.post`
/// returns long before the target app has read the pasteboard. Restoring the previous
/// contents immediately is a race that loses often enough to be maddening and rarely
/// enough to be hard to reproduce, so we wait, and we only restore if nothing else has
/// written to the pasteboard in the meantime.
public actor AccessibilityInjector: TextInjector {
  private let pasteboard: any PasteboardAccess
  private let policy: InjectionPolicy
  private let spacing = InsertionSpacing()
  private let log = RantLog("Injection")
  /// Injected so tests do not have to sleep for real.
  private let sleeper: @Sendable (Duration) async -> Void

  public init(
    pasteboard: any PasteboardAccess = SystemPasteboard(),
    policy: InjectionPolicy = InjectionPolicy(),
    sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.pasteboard = pasteboard
    self.policy = policy
    self.sleeper = sleeper
  }

  public func inject(_ request: InjectionRequest) async throws -> InjectionOutcome {
    if let refusal = policy.mustRefuse(request.context) {
      log.warning("refusing injection: \(refusal.localizedDescription)")
      throw refusal
    }

    let plan = spacing.plan(
      text: request.text,
      before: request.context?.textBeforeCursor,
      after: request.context?.textAfterCursor)
    guard !plan.text.isEmpty else { return .refused(reason: "nothing to insert") }

    if request.target == .clipboard {
      pasteboard.write(plan.text)
      return .leftOnClipboard(reason: "you asked for the clipboard")
    }

    guard AXIsProcessTrusted() else {
      // Without Accessibility we cannot read the focused element *or* reliably post
      // a keystroke, so the honest outcome is to hand the text over on the clipboard
      // and say why.
      pasteboard.write(plan.text)
      log.warning("accessibility not granted; text left on clipboard")
      return .leftOnClipboard(reason: "Rant does not have Accessibility permission yet")
    }

    if plan.text.count <= policy.directInsertionCharacterLimit,
      await insertViaAccessibility(plan.text)
    {
      log.info("inserted directly via accessibility")
      return .insertedDirectly
    }

    log.info("accessibility insertion declined; falling back to ⌘V")
    return await pasteViaClipboard(plan.text)
  }

  // MARK: - Strategy 1: Accessibility

  /// Returns true when the focused element actually took the text.
  ///
  /// "Actually" is the operative word, and the reason this reads the element back.
  /// `AXUIElementSetAttributeValue` returning `.success` means the element accepted
  /// the *message*, not that anything changed — Electron apps, browser text areas and
  /// a good deal of web-rendered UI report success and quietly do nothing. Trusting
  /// the status code produced the worst possible outcome: Rant logged
  /// `insertedDirectly`, told the user it had worked, and the cursor stayed empty.
  ///
  /// So the length of the element's value is measured before and after. If it did not
  /// grow, the write was ignored and the caller falls through to ⌘V, which those apps
  /// do honour. Only the *length* is read — never the content — because the value of a
  /// focused text field is the user's own writing and has no business in this process
  /// beyond answering "did it change".
  private func insertViaAccessibility(_ text: String) async -> Bool {
    await MainActor.run {
      let system = AXUIElementCreateSystemWide()
      var focused: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
          == .success,
        let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
      else { return false }
      let target = unsafeDowncast(element, to: AXUIElement.self)

      // Belt and braces: re-check the role here as well as in the policy, because
      // focus can move between context capture and injection.
      var role: CFTypeRef?
      var roleName: String?
      if AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role) == .success,
        let name = role as? String
      {
        roleName = name
        if InjectionPolicy.secureFieldRoles.contains(name) { return false }
      }

      // Which application is about to be written into. Identity only — no content —
      // so that "it said it worked and nothing appeared" is a diagnosable sentence.
      let owner = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

      // Some elements report that they cannot be written to. Asking first avoids a
      // half-applied edit.
      var settable: DarwinBoolean = false
      guard
        AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable)
          == .success, settable.boolValue
      else {
        log.info("\(owner) [\(roleName ?? "no role")] does not accept direct insertion")
        return false
      }

      let lengthBefore = Self.valueLength(of: target)
      let status = AXUIElementSetAttributeValue(
        target, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
      guard status == .success else {
        log.info("\(owner) [\(roleName ?? "no role")] refused direct insertion (\(status.rawValue))")
        return false
      }

      // The read-back. An element that cannot report its own length cannot be
      // verified, and an unverifiable success is treated as a failure — the clipboard
      // path is slower and duller and it works.
      guard let before = lengthBefore, let after = Self.valueLength(of: target) else {
        log.info("\(owner) [\(roleName ?? "no role")] accepted the write but cannot be read back")
        return false
      }
      guard after > before else {
        log.info(
          "\(owner) [\(roleName ?? "no role")] reported success but did not change; using ⌘V")
        return false
      }
      log.info("inserted into \(owner) [\(roleName ?? "no role")]")
      return true
    }
  }

  // MARK: - Strategy 2: clipboard and ⌘V

  private func pasteViaClipboard(_ text: String) async -> InjectionOutcome {
    let saved = pasteboard.read()
    pasteboard.write(text)
    let afterWrite = pasteboard.changeCount

    log.info("clipboard written, posting ⌘V")
    guard postCommandV() else {
      log.warning("could not synthesise ⌘V; text left on clipboard")
      return .leftOnClipboard(reason: "Rant could not send ⌘V — the text is on your clipboard")
    }

    // Give the target app time to actually read the pasteboard before we put the
    // user's clipboard back.
    await sleeper(policy.clipboardRestoreDelay)

    if let saved {
      // If something else wrote to the pasteboard while we waited — a clipboard
      // manager, or the user copying something — restoring would clobber it. Their
      // newer content wins.
      if pasteboard.changeCount == afterWrite {
        pasteboard.write(saved)
      } else {
        log.info("pasteboard changed during paste; leaving the newer contents alone")
      }
    }
    return .pastedViaClipboard
  }

  /// How many characters the element's value holds, or nil if it will not say.
  ///
  /// Length only. The value of a focused text field is whatever the user has written,
  /// and the single question worth asking about it here is whether it grew.
  private static func valueLength(of element: AXUIElement) -> Int? {
    var count: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
      let number = count as? Int
    {
      return number
    }
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
      let text = value as? String
    else { return nil }
    return text.count
  }

  /// Synthesises a real-looking ⌘V.
  ///
  /// Two details here are the difference between a paste that works everywhere and one
  /// that works in TextEdit and silently does nothing in the apps people actually
  /// write in.
  ///
  /// **The Command key is pressed, not merely implied.** The previous version posted a
  /// single "V" carrying `.maskCommand` and no modifier events at all. AppKit accepts
  /// that; Chromium — and therefore Electron, and every browser text box — tracks
  /// modifier state from key events and sees a bare V with a flag it never watched
  /// arrive, so it types nothing and reports nothing. The full sequence is ⌘ down,
  /// V down, V up, ⌘ up.
  ///
  /// **It goes to the HID tap.** `.cgAnnotatedSessionEventTap` injects below the point
  /// several apps read from. `.cghidEventTap` is where hardware arrives, which is what
  /// makes this indistinguishable from the user pressing the keys themselves.
  private nonisolated func postCommandV() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
    // Keep our own synthetic keystrokes from coming back through Rant's event tap and
    // being read as the user pressing something.
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval)

    let command: CGKeyCode = 55  // left ⌘
    let vKey: CGKeyCode = 9  // ANSI "v"

    guard
      let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
      let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
      let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
    else { return false }

    // The modifier events carry the flag too: a ⌘-down that does not say ⌘ is held is
    // not a state change anything can follow.
    commandDown.flags = .maskCommand
    vDown.flags = .maskCommand
    vUp.flags = .maskCommand
    commandUp.flags = []

    for event in [commandDown, vDown, vUp, commandUp] {
      Self.markAsRantsOwn(event)
      event.post(tap: .cghidEventTap)
    }
    return true
  }

  /// Stamp an event so Rant's own hotkey engine can tell it apart from a real key.
  ///
  /// Posting to the HID tap is what makes the paste work, and it is also what makes
  /// these events indistinguishable from hardware — including to Rant. Somebody whose
  /// dictation trigger is a Command key would otherwise have their own paste start
  /// another dictation. The suppression filter is a timing-based defence and this is
  /// not: the marker travels on the event itself.
  static func markAsRantsOwn(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
  }

  /// Arbitrary, and only ever compared against itself.
  public static let syntheticEventMarker: Int64 = 0x52_414E_54  // "RANT"

  public static func isRantsOwn(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
  }

  /// Press Return, for a Mode that dictates into a chat box and sends.
  ///
  /// Same event-suppression as the paste: a synthesised Return must not come back
  /// through Rant's own event tap and be read as the user pressing a key.
  public nonisolated func pressReturn() async {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval)

    let returnKey: CGKeyCode = 36
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
    else { return }
    // The HID tap, for the same reason the paste uses it — and the same marker, so it
    // does not come back through Rant's own tap as a keystroke.
    for event in [down, up] {
      Self.markAsRantsOwn(event)
      event.post(tap: .cghidEventTap)
    }
  }
}

/// The real `NSPasteboard`.
public struct SystemPasteboard: PasteboardAccess {
  public init() {}

  public func read() -> String? {
    NSPasteboard.general.string(forType: .string)
  }

  public func write(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
  }

  public var changeCount: Int { NSPasteboard.general.changeCount }
}
#endif
