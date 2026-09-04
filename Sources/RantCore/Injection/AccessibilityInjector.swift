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

  /// Returns true when the focused element accepted the text.
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
      if AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role) == .success,
        let roleName = role as? String,
        InjectionPolicy.secureFieldRoles.contains(roleName)
      {
        return false
      }

      // Some elements report that they cannot be written to. Asking first avoids a
      // half-applied edit.
      var settable: DarwinBoolean = false
      guard
        AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable)
          == .success, settable.boolValue
      else { return false }

      let status = AXUIElementSetAttributeValue(
        target, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
      return status == .success
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

  /// Synthesises ⌘V into the session event stream.
  private nonisolated func postCommandV() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
    // Suppress our own synthetic events from being seen by our own event tap, so a
    // paste can never be mistaken for the user pressing the trigger key.
    source.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)

    let vKey: CGKeyCode = 9  // ANSI "v"
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
    return true
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
