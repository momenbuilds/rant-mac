import XCTest
@testable import RantCore

/// Styles and modes both answer "what should happen here?", and both resolve
/// most-specific-first. These tests pin that precedence, because a general rule
/// quietly beating a specific one is the kind of bug a user experiences as "it
/// ignores my settings".
final class StyleTests: XCTestCase {

  // MARK: - Surface classification

  func testBrowsersAreClassifiedByTheSiteNotTheBrowser() {
    let classifier = SurfaceClassifier()
    let gmail = TranscriptionContext(appBundleID: "com.google.Chrome", browserHost: "mail.google.com")
    let github = TranscriptionContext(appBundleID: "com.google.Chrome", browserHost: "github.com")
    XCTAssertEqual(classifier.classify(gmail).category, .email)
    XCTAssertEqual(classifier.classify(github).category, .developer)
  }

  func testSubdomainsInheritTheirSiteRule() {
    let classifier = SurfaceClassifier()
    let context = TranscriptionContext(appBundleID: "com.apple.Safari", browserHost: "www.github.com")
    XCTAssertEqual(classifier.classify(context).category, .developer)
  }

  /// `app.slack.com` must not be beaten by a shorter rule that also matches.
  func testTheLongestMatchingSiteRuleWins() {
    XCTAssertEqual(SurfaceClassifier.match(host: "app.slack.com")?.category, .work)
  }

  func testEditorsAreDeveloperContexts() {
    let classifier = SurfaceClassifier()
    for bundle in ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.googlecode.iterm2"] {
      let surface = classifier.classify(TranscriptionContext(appBundleID: bundle))
      XCTAssertEqual(surface.category, .developer, "\(bundle)")
      XCTAssertTrue(surface.isDeveloperContext, "\(bundle)")
    }
  }

  func testAIAssistantsAreRecognisedByAppAndBySite() {
    let classifier = SurfaceClassifier()
    XCTAssertTrue(classifier.classify(
      TranscriptionContext(appBundleID: "com.anthropic.claudefordesktop")).isAIAssistant)
    XCTAssertTrue(classifier.classify(
      TranscriptionContext(appBundleID: "com.apple.Safari", browserHost: "claude.ai")).isAIAssistant)
  }

  /// Guessing a category we do not recognise would apply the wrong writing style
  /// silently, which is worse than doing nothing.
  func testAnUnknownSurfaceIsOtherRatherThanAGuess() {
    let classifier = SurfaceClassifier()
    XCTAssertEqual(
      classifier.classify(TranscriptionContext(appBundleID: "com.unknown.app")).category, .other)
    XCTAssertEqual(classifier.classify(.empty).category, .other)
  }

  func testABrowserOnAnUnknownSiteIsNotClassifiedAsTheBrowser() {
    let classifier = SurfaceClassifier()
    let context = TranscriptionContext(appBundleID: "com.google.Chrome", browserHost: "example.com")
    XCTAssertEqual(classifier.classify(context).category, .other)
  }

  // MARK: - Style resolution

  func testTheCategoryDefaultAppliesWhenNothingMoreSpecificIsSet() {
    let resolver = StyleResolver()
    let email = TranscriptionContext(appBundleID: "com.apple.mail")
    XCTAssertEqual(resolver.resolve(context: email).name, "Email")
  }

  func testAPerAppOverrideBeatsTheCategoryDefault() {
    var resolver = StyleResolver()
    resolver.perApp["com.apple.mail"] = "Very casual"
    XCTAssertEqual(
      resolver.resolve(context: TranscriptionContext(appBundleID: "com.apple.mail")).name,
      "Very casual")
  }

  func testAPerSiteOverrideBeatsAPerAppOverride() {
    var resolver = StyleResolver()
    resolver.perApp["com.google.Chrome"] = "Formal"
    resolver.perSite["github.com"] = "Developer"
    let context = TranscriptionContext(appBundleID: "com.google.Chrome", browserHost: "github.com")
    XCTAssertEqual(resolver.resolve(context: context).name, "Developer")
  }

  func testASessionOverrideBeatsEverything() {
    var resolver = StyleResolver()
    resolver.perSite["github.com"] = "Developer"
    resolver.sessionOverride = "Concise"
    let context = TranscriptionContext(appBundleID: "com.google.Chrome", browserHost: "github.com")
    XCTAssertEqual(resolver.resolve(context: context).name, "Concise")
  }

  func testTheGlobalDefaultIsTheLastResort() {
    let resolver = StyleResolver()
    XCTAssertEqual(
      resolver.resolve(context: TranscriptionContext(appBundleID: "com.unknown.app")).name,
      "Natural")
  }

  func testAnOverrideNamingAMissingStyleFallsBackRatherThanFailing() {
    var resolver = StyleResolver()
    resolver.sessionOverride = "A style that was deleted"
    XCTAssertEqual(resolver.resolve(context: .empty).name, "Natural")
  }

  func testSiteRulesMatchSubdomainsWithTheLongestRuleWinning() {
    var resolver = StyleResolver()
    resolver.perSite["google.com"] = "Formal"
    resolver.perSite["mail.google.com"] = "Email"
    XCTAssertEqual(resolver.matchSite("mail.google.com"), "Email")
    XCTAssertEqual(resolver.matchSite("docs.google.com"), "Formal")
  }

  // MARK: - Built-in style content

  /// Without an explicit prohibition a model invents a greeting on the front of a
  /// sentence dictated into the middle of a paragraph.
  func testStylesThatCouldInventAGreetingForbidIt() {
    for name in ["Email", "Formal", "Casual"] {
      let style = try! XCTUnwrap(StyleResolver().style(named: name))
      XCTAssertTrue(
        style.instructions.lowercased().contains("greeting"),
        "\(name) must say something about not inventing a greeting")
    }
  }

  func testTheAIPromptStyleTellsTheModelNotToAnswerThePrompt() {
    let style = try! XCTUnwrap(StyleResolver().style(named: "AI prompt"))
    XCTAssertTrue(style.instructions.contains("not responding to it"))
  }

  func testBuiltInStyleNamesAreUnique() {
    let names = WritingStyle.builtIns.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
  }

  // MARK: - Modes

  func testAnEditorSwitchesToDeveloperMode() {
    let resolver = ModeResolver()
    let mode = resolver.resolve(context: TranscriptionContext(appBundleID: "com.apple.dt.Xcode"))
    XCTAssertEqual(mode.name, "Developer")
  }

  /// A "helpfully" added full stop turns a working shell command into a broken one.
  func testTerminalModeDoesNoCleanupAtAll() {
    let resolver = ModeResolver()
    let mode = resolver.resolve(context: TranscriptionContext(appBundleID: "com.apple.Terminal"))
    XCTAssertEqual(mode.name, "Terminal")
    XCTAssertEqual(mode.configuration.cleanupLevel, .none)
  }

  func testAnAIChatSiteSwitchesToPromptMode() {
    let resolver = ModeResolver()
    let context = TranscriptionContext(appBundleID: "com.apple.Safari", browserHost: "claude.ai")
    XCTAssertEqual(resolver.resolve(context: context).name, "AI prompt")
  }

  func testAnUnknownSurfaceUsesTheDefaultMode() {
    let resolver = ModeResolver()
    XCTAssertEqual(
      resolver.resolve(context: TranscriptionContext(appBundleID: "com.unknown.app")).name, "Clean")
  }

  func testASessionOverrideBeatsAnAppTrigger() {
    var resolver = ModeResolver()
    resolver.sessionOverride = "Email"
    XCTAssertEqual(
      resolver.resolve(context: TranscriptionContext(appBundleID: "com.apple.dt.Xcode")).name,
      "Email")
  }

  func testSpokenModeSwitching() {
    var modes = Mode.builtIns
    modes[4].configuration.wordTrigger = "developer mode"
    let resolver = ModeResolver(modes: modes)
    XCTAssertEqual(resolver.modeForSpokenTrigger(in: "switch to developer mode please")?.name, "Developer")
    XCTAssertNil(resolver.modeForSpokenTrigger(in: "nothing to see here"))
  }

  func testBuiltInModeNamesAreUnique() {
    let names = Mode.builtIns.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
  }

  func testAModeRoundTripsThroughJSONSoItCanBeStoredAndExported() throws {
    let mode = Mode.builtIns[4]
    let data = try JSONEncoder().encode(mode.configuration)
    let decoded = try JSONDecoder().decode(Mode.Configuration.self, from: data)
    XCTAssertEqual(decoded, mode.configuration)
  }
}
