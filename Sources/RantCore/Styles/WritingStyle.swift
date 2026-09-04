import Foundation

/// How Rant should write for you in a given place.
///
/// A style is just an instruction appended to the cleanup instruction. Keeping it
/// that simple is deliberate: it means a style works identically whether cleanup is
/// happening at the provider or locally, and it means a user can read exactly what
/// their style does rather than trusting a label.
public struct WritingStyle: Equatable, Sendable, Identifiable, Codable {
  /// Identity is the name, not the database row id.
  ///
  /// A built-in style has no row until it is customised, so `rowID` is nil for all of
  /// them — and a list keyed on that treats every built-in as the same item and draws
  /// the first one ten times. The name is unique (asserted in `StyleTests`) and is
  /// what a user actually identifies a style by.
  public var id: String { name }
  public var rowID: Int64?
  public var name: String
  public var instructions: String
  /// Which surface this style is the default for, if any.
  public var category: UsageCategory?
  public var builtIn: Bool
  public var createdAt: Date

  public init(
    rowID: Int64? = nil,
    name: String,
    instructions: String,
    category: UsageCategory? = nil,
    builtIn: Bool = false,
    createdAt: Date = Date()
  ) {
    self.rowID = rowID
    self.name = name
    self.instructions = instructions
    self.category = category
    self.builtIn = builtIn
    self.createdAt = createdAt
  }

  /// The styles Rant ships with.
  ///
  /// Each instruction is written the way you would brief a person: what to do, and
  /// what not to. The negative half matters more than it looks — without "do not add
  /// a greeting", a model helpfully invents "Hi Marcus," on the front of a sentence
  /// you were dictating into the middle of a paragraph.
  public static let builtIns: [WritingStyle] = [
    WritingStyle(
      name: "Natural",
      instructions: "Write it the way the speaker said it, just tidied up. Keep their vocabulary and their rhythm.",
      builtIn: true),
    WritingStyle(
      name: "Casual",
      instructions: "Relaxed and conversational. Contractions are fine. Keep it short and human. No greeting or sign-off unless the speaker said one.",
      category: .personal, builtIn: true),
    WritingStyle(
      name: "Very casual",
      instructions: "The way you would text a friend. Lower case is fine, fragments are fine, keep it brief. No formalities at all.",
      builtIn: true),
    WritingStyle(
      name: "Formal",
      instructions: "Complete sentences, no contractions, professional register. Do not add a greeting or sign-off the speaker did not say.",
      category: .work, builtIn: true),
    WritingStyle(
      name: "Concise",
      instructions: "As few words as will carry the meaning. Cut hedging and throat-clearing. Never drop a fact, name or number.",
      builtIn: true),
    WritingStyle(
      name: "Email",
      instructions: "Clear email prose, well paragraphed. Keep the speaker's intent and tone. Do not invent a subject line, greeting or sign-off.",
      category: .email, builtIn: true),
    WritingStyle(
      name: "Excited",
      instructions: "Warm and enthusiastic, but do not overdo the exclamation marks — at most one, and only where the speaker's own emphasis warrants it.",
      builtIn: true),
    WritingStyle(
      name: "Developer",
      instructions: "Technical register. Preserve identifiers, file names, commands and casing exactly as spoken — camelCase, PascalCase, snake_case and SCREAMING_SNAKE all stay as they are. Use backticks around code and paths. Do not translate jargon into plain English.",
      category: .developer, builtIn: true),
    WritingStyle(
      name: "AI prompt",
      instructions: "Rewrite as a clear instruction to an AI assistant: state the goal, the constraints and the expected output. Keep every specific the speaker gave. Do not answer the prompt — you are writing it, not responding to it.",
      category: .aiPrompt, builtIn: true),
    WritingStyle(
      name: "Notes",
      instructions: "Structure as notes: short lines, bullets where there is a list, headings where the speaker changed subject. Keep every detail.",
      category: .documents, builtIn: true),
  ]

  public static let natural = builtIns[0]
}

/// Picks the style for where you are typing.
///
/// The resolution order is most-specific-first, and it is deliberately explicit
/// rather than clever: a per-site override beats a per-app override, which beats the
/// category default, which beats the global default. A user who sets something
/// specific should never be surprised by a general rule winning.
public struct StyleResolver: Equatable, Sendable, Codable {
  /// Style name to use in a specific app, keyed by bundle identifier.
  public var perApp: [String: String]
  /// Style name to use on a specific site, keyed by host.
  public var perSite: [String: String]
  /// Style name per surface category.
  public var perCategory: [UsageCategory: String]
  /// Fallback when nothing else matches.
  public var defaultStyleName: String
  /// A one-off override for the next dictation only.
  public var sessionOverride: String?

  public var available: [WritingStyle]

  public init(
    available: [WritingStyle] = WritingStyle.builtIns,
    perApp: [String: String] = [:],
    perSite: [String: String] = [:],
    perCategory: [UsageCategory: String] = StyleResolver.defaultCategoryStyles,
    defaultStyleName: String = "Natural",
    sessionOverride: String? = nil
  ) {
    self.available = available
    self.perApp = perApp
    self.perSite = perSite
    self.perCategory = perCategory
    self.defaultStyleName = defaultStyleName
    self.sessionOverride = sessionOverride
  }

  /// Built-in styles that name a category become that category's default.
  public static let defaultCategoryStyles: [UsageCategory: String] = {
    var map: [UsageCategory: String] = [:]
    for style in WritingStyle.builtIns {
      if let category = style.category { map[category] = style.name }
    }
    return map
  }()

  public func resolve(
    context: TranscriptionContext, classifier: SurfaceClassifier = SurfaceClassifier()
  ) -> WritingStyle {
    if let override = sessionOverride, let style = style(named: override) { return style }
    if let host = context.browserHost, let name = matchSite(host), let style = style(named: name) {
      return style
    }
    if let bundle = context.appBundleID, let name = perApp[bundle], let style = style(named: name) {
      return style
    }
    let category = classifier.classify(context).category
    if let name = perCategory[category], let style = style(named: name) { return style }
    return style(named: defaultStyleName) ?? WritingStyle.natural
  }

  /// Sites match by suffix so `mail.google.com` is covered by a rule on
  /// `google.com`, with the longest — most specific — rule winning.
  func matchSite(_ host: String) -> String? {
    let normalised = host.lowercased()
    return perSite
      .filter { normalised == $0.key || normalised.hasSuffix("." + $0.key) }
      .max(by: { $0.key.count < $1.key.count })?
      .value
  }

  public func style(named name: String) -> WritingStyle? {
    available.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }
}
