import Foundation

/// Everything Rant knows about where you are typing, at the moment you started
/// speaking.
///
/// Most of this never leaves the machine. The split matters enough that it is
/// enforced in one place — `OutboundContext` — rather than trusted to each provider.
public struct TranscriptionContext: Equatable, Sendable, Codable {
  /// Bundle identifier of the frontmost application, e.g. `com.apple.Safari`.
  public var appBundleID: String?
  public var appName: String?
  public var windowTitle: String?
  /// Host of the page in a browser, when readable — `mail.google.com`, not the full
  /// URL. We deliberately keep the host rather than the path: the host is enough to
  /// classify the surface, and the path is where the private part of a URL lives.
  public var browserHost: String?
  /// Accessibility role of the focused element, e.g. `AXTextArea`.
  public var fieldRole: String?
  /// Accessibility label or placeholder of the focused element, e.g. "Subject".
  public var fieldLabel: String?
  /// True when the focused element is a password field. When this is set, every
  /// other text member is empty by construction — see `ContextEngine`.
  public var isSecureField: Bool
  /// Text immediately before the insertion point.
  public var textBeforeCursor: String?
  /// Text immediately after the insertion point.
  public var textAfterCursor: String?
  /// The user's current selection, when there is one.
  public var selectedText: String?
  /// Clipboard contents — populated only when the user has enabled clipboard context.
  public var clipboardText: String?
  /// Text harvested from the visible window by OCR — only when explicitly enabled.
  public var screenText: String?
  /// Identifiers seen in a code editor: file names, symbols, types.
  public var developerSymbols: [String]
  /// The user's recent dictations, newest last. Continuity across utterances is what
  /// lets "and then" attach to the right sentence.
  public var recentDictations: [String]
  /// Dictionary entries to bias recognition toward.
  public var keyTerms: [String]

  public init(
    appBundleID: String? = nil,
    appName: String? = nil,
    windowTitle: String? = nil,
    browserHost: String? = nil,
    fieldRole: String? = nil,
    fieldLabel: String? = nil,
    isSecureField: Bool = false,
    textBeforeCursor: String? = nil,
    textAfterCursor: String? = nil,
    selectedText: String? = nil,
    clipboardText: String? = nil,
    screenText: String? = nil,
    developerSymbols: [String] = [],
    recentDictations: [String] = [],
    keyTerms: [String] = []
  ) {
    self.appBundleID = appBundleID
    self.appName = appName
    self.windowTitle = windowTitle
    self.browserHost = browserHost
    self.fieldRole = fieldRole
    self.fieldLabel = fieldLabel
    self.isSecureField = isSecureField
    self.textBeforeCursor = textBeforeCursor
    self.textAfterCursor = textAfterCursor
    self.selectedText = selectedText
    self.clipboardText = clipboardText
    self.screenText = screenText
    self.developerSymbols = developerSymbols
    self.recentDictations = recentDictations
    self.keyTerms = keyTerms
  }

  public static let empty = TranscriptionContext()
}

/// Which context sources the user has switched on. Everything here defaults to the
/// least surprising setting: the cheap, obviously-safe signals are on, and anything
/// that reads content the user did not point us at is off until they say so.
public struct ContextSettings: Equatable, Sendable, Codable {
  public var enabled: Bool
  public var useApp: Bool
  public var useWindowTitle: Bool
  public var useBrowserHost: Bool
  public var useFocusedField: Bool
  public var useTextAroundCursor: Bool
  public var useSelection: Bool
  public var useClipboard: Bool
  public var useScreenOCR: Bool
  public var useDeveloperSymbols: Bool
  public var useRecentDictations: Bool
  /// The big one: when false, context is gathered and used on-device but *nothing*
  /// derived from it is placed in a network request.
  public var allowSendingToCloud: Bool
  /// Bundle identifiers Rant collects no context from at all.
  public var excludedBundleIDs: Set<String>

  public init(
    enabled: Bool = true,
    useApp: Bool = true,
    useWindowTitle: Bool = true,
    useBrowserHost: Bool = true,
    useFocusedField: Bool = true,
    useTextAroundCursor: Bool = true,
    useSelection: Bool = true,
    useClipboard: Bool = false,
    useScreenOCR: Bool = false,
    useDeveloperSymbols: Bool = true,
    useRecentDictations: Bool = true,
    allowSendingToCloud: Bool = true,
    excludedBundleIDs: Set<String> = ContextSettings.defaultExclusions
  ) {
    self.enabled = enabled
    self.useApp = useApp
    self.useWindowTitle = useWindowTitle
    self.useBrowserHost = useBrowserHost
    self.useFocusedField = useFocusedField
    self.useTextAroundCursor = useTextAroundCursor
    self.useSelection = useSelection
    self.useClipboard = useClipboard
    self.useScreenOCR = useScreenOCR
    self.useDeveloperSymbols = useDeveloperSymbols
    self.useRecentDictations = useRecentDictations
    self.allowSendingToCloud = allowSendingToCloud
    self.excludedBundleIDs = excludedBundleIDs
  }

  /// Password managers and the keychain UI. Nothing good comes of reading the text
  /// around the cursor in 1Password, and shipping with these already excluded is
  /// kinder than expecting the user to think of it.
  public static let defaultExclusions: Set<String> = [
    "com.apple.keychainaccess",
    "com.1password.1password",
    "com.1password.1password7",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.dashlane.Dashlane",
    "in.sinew.Enpass-Desktop",
    "com.lastpass.LastPass",
  ]

  public static let `default` = ContextSettings()

  /// Everything off. What the "context off" toggle in the menu bar produces.
  public static let allDisabled = ContextSettings(
    enabled: false, useApp: false, useWindowTitle: false, useBrowserHost: false,
    useFocusedField: false, useTextAroundCursor: false, useSelection: false,
    useClipboard: false, useScreenOCR: false, useDeveloperSymbols: false,
    useRecentDictations: false, allowSendingToCloud: false)
}

/// The single boundary between "context Rant knows" and "context that goes on the
/// wire".
///
/// There is exactly one function here that produces network-bound text, so the
/// question "what can leave my machine?" has a one-function answer that a reviewer
/// can read in a minute and a test can pin. Everything else in
/// `TranscriptionContext` — app name, window title, field label, selection,
/// clipboard, OCR, symbols — is for on-device use: choosing a style, picking a mode,
/// repairing identifier casing. None of it is sent.
public enum OutboundContext {
  /// AssemblyAI's `conversation_context` cap.
  public static let characterBudget = 4096
  /// AssemblyAI's `word_boost` cap.
  public static let keyTermsBudget = 2048

  /// The prior dialogue that goes on the wire: recent dictations oldest-first, then
  /// the text immediately before the cursor. Redacted, then trimmed to budget from
  /// the *oldest* end, because the most recent turn is the most useful one.
  public static func wireTurns(
    context: TranscriptionContext?,
    settings: ContextSettings = .default,
    redactor: SecretRedactor = SecretRedactor()
  ) -> [String] {
    guard let context, settings.enabled, settings.allowSendingToCloud else { return [] }
    if context.isSecureField { return [] }
    if let bundle = context.appBundleID, settings.excludedBundleIDs.contains(bundle) { return [] }

    var turns: [String] = []
    if settings.useRecentDictations {
      turns.append(contentsOf: context.recentDictations)
    }
    if settings.useTextAroundCursor,
      let before = context.textBeforeCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
      !before.isEmpty
    {
      turns.append(before)
    }

    let redacted = turns
      .map(redactor.redact)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return fit(redacted, budget: characterBudget)
  }

  /// Dictionary key terms as a boost list, newest-first order preserved, trimmed to
  /// its own separate budget.
  public static func wireKeyTerms(
    context: TranscriptionContext?,
    settings: ContextSettings = .default
  ) -> [String] {
    guard let context, settings.enabled else { return [] }
    // Key terms are the user's own dictionary, not observed content, so they are
    // sent even when `allowSendingToCloud` is off — sending "Supabase" is not a
    // privacy event, and without it the provider misspells it every time.
    let terms = context.keyTerms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return fit(terms, budget: keyTermsBudget)
  }

  /// Keeps the *last* entries that fit the budget: recency beats completeness.
  static func fit(_ items: [String], budget: Int) -> [String] {
    var total = 0
    var kept: [String] = []
    for item in items.reversed() {
      let cost = item.count + 1
      if total + cost > budget { break }
      total += cost
      kept.append(item)
    }
    return kept.reversed()
  }
}
