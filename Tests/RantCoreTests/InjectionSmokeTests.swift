#if canImport(AppKit)
import AppKit
import ApplicationServices
import XCTest

@testable import RantCore

/// Does text actually land in another application?
///
/// `InjectionTests` proves the injector's *decisions* against fakes — which strategy,
/// what spacing, when to refuse. It cannot prove the thing users care about, because a
/// fake pasteboard and a fake element will agree with anything. This drives the real
/// `AccessibilityInjector` at a real application and reads the result back out of it.
///
/// TextEdit, and only TextEdit, on purpose. Verifying insertion means putting text into
/// somebody's running applications, and the consequences are not symmetrical: a stray
/// paste into Slack sends a message and into Terminal runs a command. A scratch
/// document in TextEdit can be thrown away.
///
/// Opt-in, because it needs the Accessibility grant and takes over the keyboard for a
/// moment:
///
/// ```
/// bash scripts/injection-smoke.sh
/// ```
final class InjectionSmokeTests: XCTestCase {

  private var textEdit: NSRunningApplication?

  override func tearDown() {
    // Terminate rather than close: the document was never saved and there is nothing
    // to keep, and leaving a window open would make a second run ambiguous.
    textEdit?.forceTerminate()
    textEdit = nil
  }

  func testTextReachesARealApplicationsTextField() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      environment["RANT_INJECTION_SMOKE"] == "1",
      "opt-in — needs Accessibility. Run scripts/injection-smoke.sh")
    try XCTSkipUnless(AXIsProcessTrusted(), "this process has no Accessibility grant")

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("rant-injection-\(UUID().uuidString).txt")
    try Data("".utf8).write(to: scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }

    textEdit = try await openInTextEdit(scratch)
    // Give the window a moment to take focus; the injector writes wherever focus is.
    try await Task.sleep(for: .seconds(2))

    // Refuse to inject unless TextEdit is genuinely in front.
    //
    // This is a safety guard, not a convenience. A synthetic ⌘V goes wherever focus
    // actually is, and TextEdit does not always win it — an earlier run of this test
    // pasted into a browser because focus had moved on. Skipping is the only
    // acceptable outcome: a test that types into whatever application happens to be
    // frontmost is a test that will one day send a message.
    let front = await MainActor.run {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    }
    let role = await MainActor.run { Self.focusedRole() ?? "none" }
    print("frontmost app: \(front)  focused role: \(role)")
    try XCTSkipUnless(
      front == "com.apple.TextEdit",
      "TextEdit did not take focus (\(front) is in front) — refusing to paste into it")

    let sentence = "the quick brown fox jumps over the lazy dog"
    let injector = AccessibilityInjector()
    let outcome = try await injector.inject(InjectionRequest(text: sentence, context: nil))
    print("injection outcome: \(outcome)")

    // Read back by asking TextEdit, not through Accessibility.
    //
    // A command-line test process cannot resolve the system-wide focused element —
    // `kAXFocusedUIElementAttribute` returns nothing here even with the grant — so an
    // AX read-back reports an empty field whether or not the paste worked, and would
    // fail this test for a reason belonging to the harness. Asking the application for
    // its own document text has no such limitation.
    var landed = ""
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(100))
      landed = Self.textEditDocumentText() ?? ""
      if landed.contains("quick brown fox") { break }
    }

    print("focused field now reads: \(landed)")
    XCTAssertTrue(
      landed.contains("quick brown fox"),
      """
      the injector reported \(outcome) and TextEdit's field does not contain the text. \
      This is the failure users describe as "it says it worked and nothing appears".
      """)
  }

  // MARK: - Driving TextEdit

  private func openInTextEdit(_ url: URL) async throws -> NSRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let textEditURL = try XCTUnwrap(
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"),
      "TextEdit is not installed")
    return try await NSWorkspace.shared.open(
      [url], withApplicationAt: textEditURL, configuration: configuration)
  }

  /// TextEdit's own account of what its front document contains.
  private static func textEditDocumentText() -> String? {
    let source = "tell application \"TextEdit\" to get text of document 1"
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { print("applescript: \(error)") }
    return result?.stringValue
  }

  @MainActor
  private static func focusedRole() -> String? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success,
      let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }
    var role: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        unsafeDowncast(element, to: AXUIElement.self), kAXRoleAttribute as CFString, &role)
        == .success
    else { return nil }
    return role as? String
  }

  /// Whatever the focused text element currently contains, read the same way the
  /// injector finds its target.
  @MainActor
  private static func focusedText() -> String? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success,
      let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }
    let target = unsafeDowncast(element, to: AXUIElement.self)

    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }
}
#endif
