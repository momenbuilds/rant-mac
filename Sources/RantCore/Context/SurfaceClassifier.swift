import Foundation

/// Works out what kind of writing you are doing, from the app and the site.
///
/// This is what makes "app-aware styles" actually work. Recognising Chrome is
/// useless — you write very differently in Gmail and in a GitHub issue, and both are
/// Chrome. So a browser is classified by its host, and everything else by its bundle
/// identifier.
///
/// Pure and table-driven, so adding an app is a one-line change with a one-line test
/// rather than a hunt through a view controller.
public struct SurfaceClassifier: Sendable {

  public struct Surface: Equatable, Sendable {
    public var category: UsageCategory
    /// True when the target is a code editor, which turns on identifier casing repair
    /// and symbol context.
    public var isDeveloperContext: Bool
    /// True when the target is a chat with an AI assistant, where a prompt reads
    /// differently from prose.
    public var isAIAssistant: Bool

    public init(
      category: UsageCategory, isDeveloperContext: Bool = false, isAIAssistant: Bool = false
    ) {
      self.category = category
      self.isDeveloperContext = isDeveloperContext
      self.isAIAssistant = isAIAssistant
    }
  }

  /// Bundle identifiers of browsers, whose *host* decides the category.
  public static let browserBundleIDs: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
    "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
    "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    "app.zen-browser.zen", "com.sigmaos.sigmaos", "ai.perplexity.comet",
  ]

  static let byBundleID: [String: Surface] = [
    // Editors and terminals
    "com.microsoft.VSCode": Surface(category: .developer, isDeveloperContext: true),
    "com.microsoft.VSCodeInsiders": Surface(category: .developer, isDeveloperContext: true),
    "com.todesktop.230313mzl4w4u92": Surface(category: .developer, isDeveloperContext: true), // Cursor
    "com.exafunction.windsurf": Surface(category: .developer, isDeveloperContext: true),
    "com.apple.dt.Xcode": Surface(category: .developer, isDeveloperContext: true),
    "com.jetbrains.intellij": Surface(category: .developer, isDeveloperContext: true),
    "com.jetbrains.pycharm": Surface(category: .developer, isDeveloperContext: true),
    "com.jetbrains.WebStorm": Surface(category: .developer, isDeveloperContext: true),
    "dev.zed.Zed": Surface(category: .developer, isDeveloperContext: true),
    "com.sublimetext.4": Surface(category: .developer, isDeveloperContext: true),
    "com.apple.Terminal": Surface(category: .developer, isDeveloperContext: true),
    "com.googlecode.iterm2": Surface(category: .developer, isDeveloperContext: true),
    "dev.warp.Warp-Stable": Surface(category: .developer, isDeveloperContext: true),
    "com.github.wez.wezterm": Surface(category: .developer, isDeveloperContext: true),
    "net.kovidgoyal.kitty": Surface(category: .developer, isDeveloperContext: true),
    "com.github.GitHubClient": Surface(category: .developer, isDeveloperContext: true),
    "com.torusknot.SourceTreeNotMAS": Surface(category: .developer, isDeveloperContext: true),

    // AI assistants
    "com.anthropic.claudefordesktop": Surface(category: .aiPrompt, isAIAssistant: true),
    "com.openai.chat": Surface(category: .aiPrompt, isAIAssistant: true),
    "com.perplexity.desktop": Surface(category: .aiPrompt, isAIAssistant: true),
    "ai.raycast.macos": Surface(category: .aiPrompt, isAIAssistant: true),

    // Work chat
    "com.tinyspeck.slackmacgap": Surface(category: .work),
    "com.microsoft.teams2": Surface(category: .work),
    "com.hnc.Discord": Surface(category: .personal),
    "com.linear": Surface(category: .work),
    "com.electron.asana": Surface(category: .work),

    // Personal messaging
    "com.apple.MobileSMS": Surface(category: .personal),
    "net.whatsapp.WhatsApp": Surface(category: .personal),
    "ru.keepcoder.Telegram": Surface(category: .personal),
    "com.apple.FaceTime": Surface(category: .personal),

    // Mail
    "com.apple.mail": Surface(category: .email),
    "com.readdle.smartemail-Mac": Surface(category: .email),
    "com.superhuman.electron": Surface(category: .email),
    "com.missiveapp.desktop": Surface(category: .email),

    // Documents
    "com.apple.Notes": Surface(category: .documents),
    "notion.id": Surface(category: .documents),
    "md.obsidian": Surface(category: .documents),
    "com.microsoft.Word": Surface(category: .documents),
    "com.apple.iWork.Pages": Surface(category: .documents),
    "com.agiletortoise.Drafts-OSX": Surface(category: .documents),
    "com.linearapp.Linear": Surface(category: .work),
    "com.culturedcode.ThingsMac": Surface(category: .personal),
  ]

  /// Hosts, matched by suffix so `mail.google.com` and `www.mail.google.com` agree.
  static let byHost: [(suffix: String, surface: Surface)] = [
    ("mail.google.com", Surface(category: .email)),
    ("outlook.office.com", Surface(category: .email)),
    ("outlook.live.com", Surface(category: .email)),
    ("mail.proton.me", Surface(category: .email)),
    ("fastmail.com", Surface(category: .email)),

    ("claude.ai", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("chatgpt.com", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("chat.openai.com", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("gemini.google.com", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("perplexity.ai", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("poe.com", Surface(category: .aiPrompt, isAIAssistant: true)),
    ("v0.app", Surface(category: .aiPrompt, isAIAssistant: true)),

    ("github.com", Surface(category: .developer, isDeveloperContext: true)),
    ("gitlab.com", Surface(category: .developer, isDeveloperContext: true)),
    ("stackoverflow.com", Surface(category: .developer, isDeveloperContext: true)),
    ("vercel.com", Surface(category: .developer, isDeveloperContext: true)),
    ("console.cloud.google.com", Surface(category: .developer, isDeveloperContext: true)),
    ("supabase.com", Surface(category: .developer, isDeveloperContext: true)),

    ("app.slack.com", Surface(category: .work)),
    ("teams.microsoft.com", Surface(category: .work)),
    ("linear.app", Surface(category: .work)),
    ("atlassian.net", Surface(category: .work)),
    ("asana.com", Surface(category: .work)),
    ("app.shortcut.com", Surface(category: .work)),

    ("web.whatsapp.com", Surface(category: .personal)),
    ("messenger.com", Surface(category: .personal)),
    ("web.telegram.org", Surface(category: .personal)),
    ("discord.com", Surface(category: .personal)),
    ("reddit.com", Surface(category: .personal)),
    ("x.com", Surface(category: .personal)),
    ("bsky.app", Surface(category: .personal)),

    ("notion.so", Surface(category: .documents)),
    ("docs.google.com", Surface(category: .documents)),
    ("coda.io", Surface(category: .documents)),
    ("craft.do", Surface(category: .documents)),
    ("hackmd.io", Surface(category: .documents)),
  ]

  public init() {}

  /// Classify a context. The host wins for browsers; the bundle identifier
  /// otherwise. An unrecognised surface is `.other`, which is honest — guessing
  /// would apply the wrong writing style silently.
  public func classify(_ context: TranscriptionContext) -> Surface {
    if let bundle = context.appBundleID, Self.browserBundleIDs.contains(bundle) {
      if let host = context.browserHost, let match = Self.match(host: host) { return match }
      return Surface(category: .other)
    }
    if let bundle = context.appBundleID, let match = Self.byBundleID[bundle] { return match }
    // A host without a recognised browser still tells us something — a niche browser,
    // or an Electron app that reports one.
    if let host = context.browserHost, let match = Self.match(host: host) { return match }
    return Surface(category: .other)
  }

  static func match(host: String) -> Surface? {
    let normalised = host.lowercased()
    // Longest suffix first, so `app.slack.com` beats a hypothetical `slack.com`.
    return byHost
      .filter { normalised == $0.suffix || normalised.hasSuffix("." + $0.suffix) }
      .max(by: { $0.suffix.count < $1.suffix.count })?
      .surface
  }
}
