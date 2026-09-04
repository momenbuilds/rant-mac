import Foundation

/// A reusable bundle of "how this particular kind of dictation should work".
///
/// Styles change the wording; a Mode changes the whole pipeline — which provider,
/// which model, whether cleanup runs, what context is allowed, where the output goes.
/// It exists because "dictating an email" and "dictating a shell command" want
/// genuinely different machinery, and making the user reconfigure Settings between
/// them is not a product.
public struct Mode: Equatable, Sendable, Identifiable, Codable {
  /// Same reasoning as `WritingStyle`: a built-in has no row id, so identity has to be
  /// the name or a list draws one mode repeatedly.
  public var id: String { name }
  public var rowID: Int64?
  public var name: String
  public var builtIn: Bool
  public var createdAt: Date
  public var configuration: Configuration

  public struct Configuration: Equatable, Sendable, Codable {
    /// Provider identifier, or nil to use whatever is configured globally.
    public var providerIdentifier: String?
    public var languageCode: String?
    public var cleanupLevel: CleanupLevel
    public var styleName: String?
    public var enhancementEnabled: Bool
    public var enhancementProviderIdentifier: String?
    /// Extra instruction appended for this mode.
    public var prompt: String?
    /// Which context sources this mode is allowed to use.
    public var contextSettings: ContextSettings
    public var outputTarget: InjectionTarget
    /// Press Return after inserting — useful for chat inputs.
    public var autoSend: Bool
    /// Bundle identifiers that switch to this mode automatically.
    public var appTriggers: [String]
    /// Hosts that switch to this mode automatically.
    public var siteTriggers: [String]
    /// A spoken phrase that switches to this mode.
    public var wordTrigger: String?

    public init(
      providerIdentifier: String? = nil,
      languageCode: String? = nil,
      cleanupLevel: CleanupLevel = .medium,
      styleName: String? = nil,
      enhancementEnabled: Bool = false,
      enhancementProviderIdentifier: String? = nil,
      prompt: String? = nil,
      contextSettings: ContextSettings = .default,
      outputTarget: InjectionTarget = .cursor,
      autoSend: Bool = false,
      appTriggers: [String] = [],
      siteTriggers: [String] = [],
      wordTrigger: String? = nil
    ) {
      self.providerIdentifier = providerIdentifier
      self.languageCode = languageCode
      self.cleanupLevel = cleanupLevel
      self.styleName = styleName
      self.enhancementEnabled = enhancementEnabled
      self.enhancementProviderIdentifier = enhancementProviderIdentifier
      self.prompt = prompt
      self.contextSettings = contextSettings
      self.outputTarget = outputTarget
      self.autoSend = autoSend
      self.appTriggers = appTriggers
      self.siteTriggers = siteTriggers
      self.wordTrigger = wordTrigger
    }
  }

  public init(
    rowID: Int64? = nil,
    name: String,
    builtIn: Bool = false,
    createdAt: Date = Date(),
    configuration: Configuration
  ) {
    self.rowID = rowID
    self.name = name
    self.builtIn = builtIn
    self.createdAt = createdAt
    self.configuration = configuration
  }

  public static let builtIns: [Mode] = [
    Mode(name: "Dictation", builtIn: true, configuration: .init(cleanupLevel: .light)),
    Mode(name: "Clean", builtIn: true, configuration: .init(cleanupLevel: .medium)),
    Mode(
      name: "Email", builtIn: true,
      configuration: .init(cleanupLevel: .medium, styleName: "Email")),
    Mode(
      name: "Message", builtIn: true,
      configuration: .init(cleanupLevel: .medium, styleName: "Casual", autoSend: false)),
    Mode(
      name: "Developer", builtIn: true,
      configuration: .init(
        cleanupLevel: .light, styleName: "Developer",
        appTriggers: [
          "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
          "dev.zed.Zed", "com.exafunction.windsurf",
        ])),
    Mode(
      name: "Terminal", builtIn: true,
      configuration: .init(
        // A shell command must be transcribed, not prettified: a "helpfully" added
        // full stop is a broken command.
        cleanupLevel: .none, styleName: "Developer",
        appTriggers: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"])),
    Mode(
      name: "AI prompt", builtIn: true,
      configuration: .init(
        cleanupLevel: .medium, styleName: "AI prompt",
        siteTriggers: ["claude.ai", "chatgpt.com", "gemini.google.com"])),
    Mode(
      name: "Notes", builtIn: true,
      configuration: .init(cleanupLevel: .medium, styleName: "Notes")),
    Mode(
      name: "Rewrite", builtIn: true,
      configuration: .init(cleanupLevel: .high, enhancementEnabled: true)),
  ]
}

/// Chooses the active mode for a context.
///
/// Same precedence rule as styles — site, then app, then the user's chosen default —
/// so the two behave alike and there is one idea to learn rather than two.
public struct ModeResolver: Equatable, Sendable, Codable {
  public var modes: [Mode]
  public var defaultModeName: String
  public var sessionOverride: String?

  public init(
    modes: [Mode] = Mode.builtIns,
    defaultModeName: String = "Clean",
    sessionOverride: String? = nil
  ) {
    self.modes = modes
    self.defaultModeName = defaultModeName
    self.sessionOverride = sessionOverride
  }

  public func resolve(context: TranscriptionContext) -> Mode {
    if let override = sessionOverride, let mode = mode(named: override) { return mode }

    if let host = context.browserHost?.lowercased() {
      let matches = modes.filter { mode in
        mode.configuration.siteTriggers.contains { host == $0 || host.hasSuffix("." + $0) }
      }
      // Longest trigger wins, so a rule on `mail.google.com` beats one on `google.com`.
      if let best = matches.max(by: { longestTrigger($0) < longestTrigger($1) }) { return best }
    }
    if let bundle = context.appBundleID,
      let mode = modes.first(where: { $0.configuration.appTriggers.contains(bundle) })
    {
      return mode
    }
    return mode(named: defaultModeName) ?? modes.first ?? Mode.builtIns[1]
  }

  private func longestTrigger(_ mode: Mode) -> Int {
    mode.configuration.siteTriggers.map(\.count).max() ?? 0
  }

  public func mode(named name: String) -> Mode? {
    modes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// Spoken mode switching: "switch to developer mode".
  public func modeForSpokenTrigger(in text: String) -> Mode? {
    let lowered = text.lowercased()
    return modes.first { mode in
      guard let trigger = mode.configuration.wordTrigger?.lowercased(), !trigger.isEmpty else {
        return false
      }
      return lowered.contains(trigger)
    }
  }
}
