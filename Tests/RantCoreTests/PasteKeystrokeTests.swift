#if canImport(AppKit)
import AppKit
import ApplicationServices
import XCTest

@testable import RantCore

/// The synthesised ⌘V, on its own.
///
/// Split out from `InjectionSmokeTests` because when that test crashed there was no way
/// to tell whether the fault was in the keystroke — which ships — or in the harness
/// driving `NSPasteboard` from a background thread, which does not. A fake pasteboard
/// removes the second possibility, so a crash here is unambiguously ours.
final class PasteKeystrokeTests: XCTestCase {

  func testTheClipboardPathDoesNotCrashWhenAccessibilityIsGranted() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["RANT_INJECTION_SMOKE"] == "1",
      "opt-in — posts a real keystroke. Run scripts/injection-smoke.sh")
    try XCTSkipUnless(AXIsProcessTrusted(), "this process has no Accessibility grant")

    // With the direct limit at zero the injector must reach `postCommandV`, which is
    // the code under test. Everything else is a fake.
    var policy = InjectionPolicy()
    policy.directInsertionCharacterLimit = 0
    let pasteboard = FakePasteboard()
    pasteboard.write("what the user had")

    let injector = AccessibilityInjector(
      pasteboard: pasteboard, policy: policy, sleeper: { _ in })
    let outcome = try await injector.inject(
      InjectionRequest(text: "a synthesised paste", context: nil))

    XCTAssertEqual(outcome, .pastedViaClipboard)
    XCTAssertEqual(
      pasteboard.read(), "what the user had",
      "the clipboard has to be handed back exactly as it was found")
  }
}
#endif
