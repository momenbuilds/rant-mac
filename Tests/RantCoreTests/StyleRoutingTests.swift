import XCTest

@testable import RantCore

/// Does the style a user picked actually reach the provider?
///
/// `StyleResolver` was implemented and unit-tested, the Styles screen listed every
/// instruction in full, and none of it reached a dictation: `DictationSettings` never
/// carried a style, so `styleInstruction` was nil on every request and the resolver was
/// dead code. Testing the resolver in isolation could not catch that — only following
/// the value all the way to the transcription options can.
final class StyleRoutingTests: XCTestCase {

  private func session(
    transcriber: ScriptedTranscriber, context: TranscriptionContext
  ) -> DictationSession {
    DictationSession(
      audio: FixtureAudioCapture.tone(),
      transcriber: transcriber,
      injector: RecordingInjector(),
      context: StaticContextProvider(context),
      store: nil,
      enhancer: nil,
      vocabulary: VocabularyApplier(),
      now: { Date(timeIntervalSince1970: 1_700_000_000) })
  }

  private func run(
    settings: DictationSettings, context: TranscriptionContext = .empty
  ) async throws -> TranscriptionOptions {
    let transcriber = ScriptedTranscriber(raw: "hello")
    let session = session(transcriber: transcriber, context: context)
    await session.start()
    _ = await session.stopAndTranscribe(settings: settings)
    return try XCTUnwrap(transcriber.receivedOptions.first)
  }

  private var formal: WritingStyle {
    WritingStyle(name: "Formal", instructions: "Write formally.", builtIn: false)
  }

  private var casual: WritingStyle {
    WritingStyle(name: "Casual", instructions: "Keep it loose.", builtIn: false)
  }

  // MARK: - The routing itself

  func testTheGlobalDefaultStyleReachesTheProvider() async throws {
    let resolver = StyleResolver(
      available: [formal], perCategory: [:], defaultStyleName: "Formal")
    let options = try await run(
      settings: DictationSettings(styleResolver: resolver))
    XCTAssertEqual(options.styleInstruction, "Write formally.")
  }

  func testWithNoResolverNoStyleIsSent() async throws {
    let options = try await run(settings: DictationSettings())
    XCTAssertNil(
      options.styleInstruction,
      "no configured style must mean no instruction, not an invented one")
  }

  /// The per-app rule is the feature people actually notice: Slack should not read
  /// like a contract.
  func testAPerAppRuleBeatsTheGlobalDefault() async throws {
    let resolver = StyleResolver(
      available: [formal, casual],
      perApp: ["com.tinyspeck.slackmacgap": "Casual"],
      perCategory: [:],
      defaultStyleName: "Formal")
    var context = TranscriptionContext.empty
    context.appBundleID = "com.tinyspeck.slackmacgap"

    let options = try await run(
      settings: DictationSettings(styleResolver: resolver), context: context)
    XCTAssertEqual(options.styleInstruction, "Keep it loose.")
  }

  func testAPerSiteRuleBeatsAPerAppRule() async throws {
    let resolver = StyleResolver(
      available: [formal, casual],
      perApp: ["com.apple.Safari": "Casual"],
      perSite: ["github.com": "Formal"],
      perCategory: [:],
      defaultStyleName: "Casual")
    var context = TranscriptionContext.empty
    context.appBundleID = "com.apple.Safari"
    context.browserHost = "gist.github.com"

    let options = try await run(
      settings: DictationSettings(styleResolver: resolver), context: context)
    XCTAssertEqual(
      options.styleInstruction, "Write formally.",
      "a site rule is more specific than an app rule and must win")
  }

  /// A one-off override is the most specific thing there is.
  func testAnExplicitInstructionOverridesTheResolver() async throws {
    let resolver = StyleResolver(
      available: [formal], perCategory: [:], defaultStyleName: "Formal")
    let options = try await run(
      settings: DictationSettings(
        styleInstruction: "Answer in one word.", styleResolver: resolver))
    XCTAssertEqual(options.styleInstruction, "Answer in one word.")
  }

  func testAStyleThatNoLongerExistsFallsBackRatherThanSendingNothingUseful()
    async throws
  {
    // A rule can outlive the style it names — the user deleted it. Falling through to
    // a real style is right; sending the missing name as an instruction would not be.
    let resolver = StyleResolver(
      available: [formal],
      perApp: ["com.apple.mail": "Deleted style"],
      perCategory: [:],
      defaultStyleName: "Formal")
    var context = TranscriptionContext.empty
    context.appBundleID = "com.apple.mail"

    let options = try await run(
      settings: DictationSettings(styleResolver: resolver), context: context)
    XCTAssertEqual(options.styleInstruction, "Write formally.")
  }
}
