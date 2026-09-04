import XCTest

@testable import RantCore

/// Does a Mode actually change the pipeline?
///
/// `ModeResolver` was implemented and tested, the Modes screen described what each
/// mode does to cleanup, style, context and output, and nothing consulted it: the
/// resolver never reached `DictationSettings`, so every dictation used the global
/// settings whatever the screen said. The master prompt is explicit that a field with
/// no pipeline effect must be implemented or removed, so these follow each one through
/// to the request that leaves the session.
/// Records the settings each capture was asked with, so a test can assert on what was
/// collected rather than only on what came back.
private actor RecordingContextProvider: ContextProvider {
  private let first: TranscriptionContext
  private let second: TranscriptionContext
  private(set) var requested: [ContextSettings] = []

  init(first: TranscriptionContext, second: TranscriptionContext) {
    self.first = first
    self.second = second
  }

  func capture(settings: ContextSettings) async -> TranscriptionContext {
    requested.append(settings)
    return requested.count == 1 ? first : second
  }
}

final class ModeRoutingTests: XCTestCase {

  private func run(
    settings: DictationSettings, context: TranscriptionContext = .empty,
    raw: String = "so um we should ship it"
  ) async throws -> (options: TranscriptionOptions, injected: InjectionRequest) {
    let transcriber = ScriptedTranscriber(raw: raw)
    let injector = RecordingInjector()
    let session = DictationSession(
      audio: FixtureAudioCapture.tone(),
      transcriber: transcriber,
      injector: injector,
      context: StaticContextProvider(context),
      store: nil,
      enhancer: nil,
      vocabulary: VocabularyApplier(),
      now: { Date(timeIntervalSince1970: 1_700_000_000) })
    await session.start()
    _ = await session.stopAndTranscribe(settings: settings)
    return (
      try XCTUnwrap(transcriber.receivedOptions.first),
      try XCTUnwrap(injector.requests.last)
    )
  }

  private func mode(
    _ name: String, _ change: (inout Mode.Configuration) -> Void
  ) -> Mode {
    var configuration = Mode.Configuration()
    change(&configuration)
    return Mode(
      rowID: nil, name: name, builtIn: false, createdAt: Date(),
      configuration: configuration)
  }

  // MARK: - Cleanup

  /// The Terminal case, which is the one with real consequences: a helpfully added
  /// full stop turns a working shell command into a broken one.
  func testAModeCanTurnCleanupOffForTheAppItAppliesTo() async throws {
    let terminal = mode("Terminal") {
      $0.cleanupLevel = .none
      $0.appTriggers = ["com.apple.Terminal"]
    }
    var context = TranscriptionContext.empty
    context.appBundleID = "com.apple.Terminal"

    let result = try await run(
      settings: DictationSettings(
        cleanupLevel: .high,
        modeResolver: ModeResolver(modes: [terminal], defaultModeName: "Terminal")),
      context: context)

    XCTAssertEqual(result.options.cleanupLevel, .none)
  }

  func testWithoutAMatchingTriggerTheGlobalSettingStands() async throws {
    let terminal = mode("Terminal") {
      $0.cleanupLevel = .none
      $0.appTriggers = ["com.apple.Terminal"]
    }
    let fallback = mode("Clean") { $0.cleanupLevel = .medium }
    var context = TranscriptionContext.empty
    context.appBundleID = "com.apple.TextEdit"

    let result = try await run(
      settings: DictationSettings(
        modeResolver: ModeResolver(
          modes: [terminal, fallback], defaultModeName: "Clean")),
      context: context)
    XCTAssertEqual(result.options.cleanupLevel, .medium)
  }

  // MARK: - Language, style, prompt

  func testAModeCanForceALanguage() async throws {
    let spanish = mode("Español") { $0.languageCode = "es" }
    let result = try await run(
      settings: DictationSettings(
        languageCode: "en",
        modeResolver: ModeResolver(modes: [spanish], defaultModeName: "Español")))
    XCTAssertEqual(result.options.languageCode, "es")
  }

  func testAModeCanChooseAStyleByName() async throws {
    let formal = WritingStyle(
      name: "Formal", instructions: "Write formally.", builtIn: false)
    let email = mode("Email") { $0.styleName = "Formal" }
    let result = try await run(
      settings: DictationSettings(
        styleResolver: StyleResolver(available: [formal], perCategory: [:]),
        modeResolver: ModeResolver(modes: [email], defaultModeName: "Email")))
    XCTAssertEqual(result.options.styleInstruction, "Write formally.")
  }

  /// A mode's prompt adds to the style rather than replacing it: the user picked that
  /// voice deliberately and the mode is asking for one more thing.
  func testAModePromptIsAppendedToTheStyleRatherThanReplacingIt() async throws {
    let formal = WritingStyle(
      name: "Formal", instructions: "Write formally.", builtIn: false)
    let email = mode("Email") {
      $0.styleName = "Formal"
      $0.prompt = "Sign off with my name."
    }
    let result = try await run(
      settings: DictationSettings(
        styleResolver: StyleResolver(available: [formal], perCategory: [:]),
        modeResolver: ModeResolver(modes: [email], defaultModeName: "Email")))
    let instruction = try XCTUnwrap(result.options.styleInstruction)
    XCTAssertTrue(instruction.contains("Write formally."))
    XCTAssertTrue(instruction.contains("Sign off with my name."))
  }

  /// A mode that names no style must not clear the one the style resolver chose.
  func testAModeWithoutAStyleLeavesTheResolversChoiceAlone() async throws {
    let casual = WritingStyle(
      name: "Casual", instructions: "Keep it loose.", builtIn: false)
    let plain = mode("Plain") { $0.cleanupLevel = .light }
    let result = try await run(
      settings: DictationSettings(
        styleResolver: StyleResolver(
          available: [casual], perCategory: [:], defaultStyleName: "Casual"),
        modeResolver: ModeResolver(modes: [plain], defaultModeName: "Plain")))
    XCTAssertEqual(result.options.styleInstruction, "Keep it loose.")
  }

  // MARK: - Output

  func testAModeCanSendItsOutputToTheClipboardInsteadOfTheCursor() async throws {
    let copy = mode("Copy") { $0.outputTarget = .clipboard }
    let result = try await run(
      settings: DictationSettings(
        modeResolver: ModeResolver(modes: [copy], defaultModeName: "Copy")))
    XCTAssertEqual(result.injected.target, .clipboard)
  }

  func testTheDefaultOutputIsStillTheCursor() async throws {
    let result = try await run(settings: DictationSettings())
    XCTAssertEqual(result.injected.target, .cursor)
  }

  // MARK: - Context

  /// A mode carrying tighter context rules must tighten what is *collected*, not
  /// merely what is used. This is a privacy control, so the test asserts on the
  /// settings the provider was actually asked with.
  func testAModeThatDisablesContextCausesASecondCaptureUnderItsOwnRules() async throws {
    let recorder = RecordingContextProvider(
      // The first capture has to name the app, or no mode could be selected from it.
      first: { var c = TranscriptionContext.empty; c.appBundleID = "com.apple.Notes"; return c }(),
      second: .empty)
    let quiet = mode("Quiet") {
      $0.contextSettings = ContextSettings(enabled: false)
      $0.appTriggers = ["com.apple.Notes"]
    }
    let session = DictationSession(
      audio: FixtureAudioCapture.tone(),
      transcriber: ScriptedTranscriber(raw: "hello"),
      injector: RecordingInjector(),
      context: recorder,
      store: nil, enhancer: nil, vocabulary: VocabularyApplier(),
      now: { Date(timeIntervalSince1970: 1_700_000_000) })

    await session.start(
      settings: DictationSettings(
        contextSettings: ContextSettings(enabled: true),
        modeResolver: ModeResolver(modes: [quiet], defaultModeName: "Quiet")))
    _ = await session.stopAndTranscribe(
      settings: DictationSettings(
        contextSettings: ContextSettings(enabled: true),
        modeResolver: ModeResolver(modes: [quiet], defaultModeName: "Quiet")))

    let asked = await recorder.requested
    XCTAssertEqual(asked.count, 2, "the mode's rules should force a second capture")
    XCTAssertTrue(asked[0].enabled, "the first capture identifies the app")
    XCTAssertFalse(asked[1].enabled, "the second must run under the mode's rules")
  }

  // MARK: - Site beats app

  func testASiteTriggerBeatsAnAppTrigger() async throws {
    let browser = mode("Browser") {
      $0.cleanupLevel = .light
      $0.appTriggers = ["com.apple.Safari"]
    }
    let developer = mode("Developer") {
      $0.cleanupLevel = .none
      $0.siteTriggers = ["github.com"]
    }
    var context = TranscriptionContext.empty
    context.appBundleID = "com.apple.Safari"
    context.browserHost = "gist.github.com"

    let result = try await run(
      settings: DictationSettings(
        modeResolver: ModeResolver(
          modes: [browser, developer], defaultModeName: "Browser")),
      context: context)
    XCTAssertEqual(result.options.cleanupLevel, .none)
  }
}
