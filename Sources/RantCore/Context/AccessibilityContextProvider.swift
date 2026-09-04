#if canImport(AppKit)
import AppKit
import ApplicationServices

/// Reads the frontmost app, the focused field, and the text around the cursor
/// through Accessibility.
///
/// Three rules shape this code:
///
/// **Secure fields short-circuit everything.** The moment the focused element reports
/// a password role, we return a context with `isSecureField` set and no text at all.
/// Not "we collect it and filter later" — we never read it. That is what makes the
/// guarantee in `SECURITY.md` checkable.
///
/// **Only what the user enabled.** Each source is behind its own flag, and an
/// excluded application contributes nothing whatsoever.
///
/// **Speed.** This runs between the hotkey and the first audio sample, so it must not
/// stall. Accessibility calls into an unresponsive app can block, so every read is
/// bounded and a slow app yields nothing rather than delaying the recording.
public struct AccessibilityContextProvider: ContextProvider {
  private let log = RantLog("Context")
  /// How much text either side of the cursor is worth reading.
  private let windowCharacters: Int
  /// Supplies recent dictations for conversational continuity.
  private let recentDictations: @Sendable () -> [String]
  /// Supplies dictionary key terms.
  private let keyTerms: @Sendable () -> [String]

  public init(
    windowCharacters: Int = 600,
    recentDictations: @escaping @Sendable () -> [String] = { [] },
    keyTerms: @escaping @Sendable () -> [String] = { [] }
  ) {
    self.windowCharacters = windowCharacters
    self.recentDictations = recentDictations
    self.keyTerms = keyTerms
  }

  public func capture(settings: ContextSettings = .default) async -> TranscriptionContext {
    guard settings.enabled else { return .empty }

    var context = TranscriptionContext()
    context.keyTerms = keyTerms()

    guard AXIsProcessTrusted() else {
      // Without Accessibility we can still name the frontmost app, which is enough
      // for style selection.
      if settings.useApp, let app = NSWorkspace.shared.frontmostApplication {
        context.appBundleID = app.bundleIdentifier
        context.appName = app.localizedName
      }
      if settings.useRecentDictations { context.recentDictations = recentDictations() }
      return context
    }

    if let app = NSWorkspace.shared.frontmostApplication {
      let bundleID = app.bundleIdentifier
      // An excluded app contributes nothing at all — not even its name.
      if let bundleID, settings.excludedBundleIDs.contains(bundleID) {
        log.info("context skipped for excluded application")
        return TranscriptionContext(keyTerms: context.keyTerms)
      }
      if settings.useApp {
        context.appBundleID = bundleID
        context.appName = app.localizedName
      }
      if let bundleID {
        readElements(pid: app.processIdentifier, bundleID: bundleID, settings: settings, into: &context)
      }
    }

    if settings.useClipboard, let clipboard = NSPasteboard.general.string(forType: .string) {
      context.clipboardText = String(clipboard.prefix(windowCharacters))
    }
    if settings.useRecentDictations {
      context.recentDictations = recentDictations()
    }
    return context
  }

  private func readElements(
    pid: pid_t, bundleID: String, settings: ContextSettings, into context: inout TranscriptionContext
  ) {
    let application = AXUIElementCreateApplication(pid)

    if settings.useWindowTitle,
      let window = element(copy(application, kAXFocusedWindowAttribute)),
      let title = copy(window, kAXTitleAttribute) as? String
    {
      context.windowTitle = title
      if settings.useBrowserHost, SurfaceClassifier.browserBundleIDs.contains(bundleID) {
        context.browserHost = Self.host(fromDocument: copy(window, kAXDocumentAttribute) as? String)
          ?? Self.host(fromTitle: title)
      }
    }

    guard let focused = element(copy(application, kAXFocusedUIElementAttribute)) else { return }

    let role = copy(focused, kAXRoleAttribute) as? String
    let subrole = copy(focused, kAXSubroleAttribute) as? String

    // The refusal. Nothing below this line runs for a password field.
    if let role, InjectionPolicy.secureFieldRoles.contains(role) {
      context.isSecureField = true
      context.fieldRole = role
      return
    }
    if let subrole, subrole == "AXSecureTextField" {
      context.isSecureField = true
      context.fieldRole = subrole
      return
    }

    if settings.useFocusedField {
      context.fieldRole = role
      context.fieldLabel =
        (copy(focused, kAXDescriptionAttribute) as? String)
        ?? (copy(focused, kAXPlaceholderValueAttribute) as? String)
        ?? (copy(focused, kAXTitleAttribute) as? String)
    }

    if settings.useSelection, let selected = copy(focused, kAXSelectedTextAttribute) as? String,
      !selected.isEmpty
    {
      context.selectedText = String(selected.prefix(4_000))
    }

    if settings.useTextAroundCursor, let value = copy(focused, kAXValueAttribute) as? String {
      let caret = caretOffset(in: focused) ?? value.count
      let index = value.index(value.startIndex, offsetBy: min(caret, value.count))
      context.textBeforeCursor = String(value[..<index].suffix(windowCharacters))
      context.textAfterCursor = String(value[index...].prefix(windowCharacters))
    }
  }

  private func caretOffset(in element: AXUIElement) -> Int? {
    guard let rangeValue = copy(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range) else {
      return nil
    }
    return range.location
  }

  /// Narrows an attribute value to an `AXUIElement`, checking the type first —
  /// Accessibility hands back `AnyObject` and a wrong assumption here is a crash.
  private func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  /// Safari and Chrome expose the page URL as `AXDocument` on the focused window.
  static func host(fromDocument document: String?) -> String? {
    guard let document, let url = URL(string: document), let host = url.host else { return nil }
    return host.lowercased()
  }

  /// Fallback for browsers that do not expose `AXDocument`: some put the host in the
  /// window title. Deliberately conservative — a wrong host picks a wrong writing
  /// style, so we only accept something that actually looks like a bare domain.
  static func host(fromTitle title: String) -> String? {
    let candidates = title.split(whereSeparator: { $0 == " " || $0 == "—" || $0 == "-" || $0 == "|" })
    for candidate in candidates {
      let text = candidate.lowercased().trimmingCharacters(in: .punctuationCharacters)
      guard text.contains("."), !text.contains("/"), !text.contains("@"),
        text.split(separator: ".").count >= 2,
        text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
      else { continue }
      return text
    }
    return nil
  }
}
#endif
