import XCTest

/// UI tests for the surfaces a person actually walks through.
///
/// These deliberately do **not** try to test global text injection. Driving another
/// application's text field from XCUITest, with real Accessibility permissions and a
/// real microphone, produces a test that fails for reasons unrelated to the change
/// being tested — and a flaky test that guards something important is worse than an
/// honest manual checklist. That work lives in `docs/SMOKE_TEST.md`, and
/// `scripts/check.sh` reports it as a skip rather than a pass.
///
/// What is worth automating is everything else: that onboarding renders and can be
/// completed, that the sidebar navigates, that settings persist, and that the CRUD
/// screens actually create things.
@MainActor
final class OnboardingUITests: XCTestCase {

  private var app: XCUIApplication!

  // The `async` overloads of setUp and tearDown, rather than the synchronous ones.
  //
  // XCTest declares the synchronous versions `nonisolated`, so a main-actor test class
  // cannot touch its own properties from them — and `XCUIElement`'s methods *are*
  // main-actor isolated under Xcode 16, which is what CI builds with. The async
  // overloads inherit the class's isolation, so both compilers agree. Xcode 26 accepts
  // the naive version and Xcode 16 does not, which is exactly the difference that
  // turns "green on my machine" into a red build nobody can reproduce.
  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    // A clean slate each run: the app reads this and starts from first-run state with
    // an in-memory database, so a UI test never touches real history.
    app.launchArguments += ["-rant-ui-testing", "YES"]
    app.launch()
  }

  override func tearDown() async throws {
    app?.terminate()
  }

  // MARK: - Onboarding

  func testOnboardingOpensOnTheWelcomeStep() {
    XCTAssertTrue(app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10))
  }

  func testEveryOnboardingStepCanBeSkippedSoNobodyIsTrapped() {
    XCTAssertTrue(app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10))
    // A permission the user will not grant must never be a dead end.
    for _ in 0..<8 {
      let skip = element("onboarding.skip")
      if skip.exists { skip.click() } else { break }
    }
    XCTAssertTrue(element("onboarding.finish").waitForExistence(timeout: 5))
  }

  func testPermissionStepsExplainWhyBeforeAsking() {
    XCTAssertTrue(element("onboarding.continue").waitForExistence(timeout: 10))
    element("onboarding.continue").click()
    XCTAssertTrue(app.staticTexts["Microphone"].waitForExistence(timeout: 5))
    // The explanation, not just the ask.
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'hold your dictation key'"))
        .firstMatch.exists)
  }

  func testCompletingOnboardingReachesTheMainWindow() {
    completeOnboarding()
    XCTAssertTrue(element("sidebar.home").waitForExistence(timeout: 5))
  }

  // MARK: - Navigation

  func testSidebarNavigatesToEachDestination() {
    completeOnboarding()
    for destination in ["history", "dictionary", "snippets", "settings", "home"] {
      XCTAssertTrue(click("sidebar.\(destination)"), "\(destination) missing from the sidebar")
    }
  }

  // MARK: - CRUD

  func testAddingADictionaryEntry() {
    completeOnboarding()
    click("sidebar.dictionary")

    let add = element("dictionary.add").exists ? element("dictionary.add") : element("dictionary.addToolbar")
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.click()

    let spoken = element("dictionary.spoken")
    XCTAssertTrue(spoken.waitForExistence(timeout: 5))
    spoken.click()
    spoken.typeText("super base")

    let written = element("dictionary.written")
    written.click()
    written.typeText("Supabase")

    element("dictionary.save").click()
    XCTAssertTrue(app.staticTexts["Supabase"].waitForExistence(timeout: 5))
  }

  func testAddingASnippet() {
    completeOnboarding()
    click("sidebar.snippets")

    let add = element("snippets.add").exists ? element("snippets.add") : element("snippets.addToolbar")
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.click()

    let trigger = element("snippets.trigger")
    XCTAssertTrue(trigger.waitForExistence(timeout: 5))
    trigger.click()
    trigger.typeText("my meeting link")

    app.textViews.firstMatch.click()
    app.textViews.firstMatch.typeText("https://cal.com/rant")

    element("snippets.save").click()
    XCTAssertTrue(app.staticTexts["my meeting link"].waitForExistence(timeout: 5))
  }

  // MARK: - Settings

  /// Settings must survive a relaunch, or every preference is a lie.
  ///
  /// This drives a toggle rather than the cleanup-level picker, deliberately. A
  /// SwiftUI `Picker` opens a real menu, and XCUITest's "wait for menu open"
  /// handshake is unreliable enough that the test failed for reasons unrelated to
  /// persistence. A flaky test guarding something important is worse than a solid
  /// test guarding the same mechanism through a different control — the value still
  /// goes through `Preferences` to `UserDefaults` either way.
  func testASettingPersistsAcrossRelaunch() {
    completeOnboarding()
    click("sidebar.settings")

    // A General-pane toggle rather than the privacy one, and for the same reason the
    // note above chose a toggle over a picker: this test is about persistence, and it
    // should fail when persistence breaks rather than when a settings pane grows.
    //
    // It used to drive Privacy → "Local only", which sits below several context
    // sections. Adding the Notetaker, Integrations and Advanced tabs pushed it under
    // the fold on CI's smaller display, and the test started failing for a layout
    // reason with nothing to say about whether settings survive a relaunch. Scrolling
    // the form did not reach it — SwiftUI's `Form` is not exposed as a scroll area the
    // test can drive — so the honest fix is to stop depending on where a control sits.
    // The value still travels through `Preferences` to `UserDefaults` identically.
    let toggle = switchElement("settings.overlayAlwaysVisible")
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(
      scrollIntoView(toggle),
      "the privacy toggle exists but could not be brought on screen")
    let before = isOn(toggle)
    toggle.click()
    XCTAssertTrue(
      waitForState(toggle, toDifferFrom: before),
      "clicking the toggle did not change it — \(describe(toggle))")

    app.terminate()
    app.launchArguments += ["-rant-ui-testing-keep-preferences", "YES"]
    app.launch()

    click("sidebar.settings")
    let after = switchElement("settings.overlayAlwaysVisible")
    XCTAssertTrue(after.waitForExistence(timeout: 5))
    XCTAssertTrue(scrollIntoView(after), "the toggle could not be brought back on screen")
    XCTAssertTrue(
      waitForState(after, toDifferFrom: before),
      "the setting did not survive a relaunch — \(describe(after))")
  }

  /// The privacy claims are load-bearing, so they should be visible in the app and
  /// not only in a README that nobody opens.
  func testThePrivacyPaneStatesTheGuarantees() {
    completeOnboarding()
    click("sidebar.settings")
    settingsTab("Privacy").click()
    XCTAssertTrue(
      app.staticTexts["No account, no telemetry, no analytics SDK"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Rant never reads from or types into a password field"].exists)
  }

  // MARK: - Helpers

  /// Look an element up by identifier without caring what type SwiftUI chose to
  /// render it as. `.buttonStyle(.link)` produces a `Link`, not a `Button`, and a
  /// test that hard-codes the element type breaks on a purely visual change.
  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  /// Resolve a toggle to the control itself rather than to whatever wraps it.
  ///
  /// `descendants(matching: .any)` returns the first node carrying the identifier,
  /// and SwiftUI does not guarantee that is the switch — a containing group can carry
  /// it too, and a group has no `value`, so the test reads every state as "off" and
  /// compares nothing to nothing. Ask for the switch (macOS may render it as a
  /// checkbox), and fall back only if neither exists.
  private func switchElement(_ identifier: String) -> XCUIElement {
    if app.switches[identifier].exists { return app.switches[identifier] }
    if app.checkBoxes[identifier].exists { return app.checkBoxes[identifier] }
    // SwiftUI may hang the identifier on a wrapper rather than on the control, in
    // which case the control is a descendant of it — and the wrapper has no `value`,
    // so reading the wrapper reports "off" no matter what the switch is doing.
    let container = element(identifier)
    if container.switches.firstMatch.exists { return container.switches.firstMatch }
    if container.checkBoxes.firstMatch.exists { return container.checkBoxes.firstMatch }
    return container
  }

  /// A click is delivered asynchronously and SwiftUI redraws on the next runloop pass,
  /// so reading the value on the very next line races the update. Poll instead of
  /// sleeping a fixed amount: fast when it works, and still honest when it does not.
  private func waitForState(
    _ element: XCUIElement, toDifferFrom before: Bool, timeout: TimeInterval = 5
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if isOn(element) != before { return true }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
  }

  /// Put the element's type and raw value in the failure message. Without it, a
  /// toggle that reports "off" because it is the wrong element looks exactly like a
  /// toggle that reports "off" because the setting did not persist.
  private func describe(_ element: XCUIElement) -> String {
    "elementType=\(element.elementType.rawValue) value=\(String(describing: element.value))"
  }

  /// Bring an element on screen, scrolling the form if it is below the fold.
  ///
  /// A settings pane is a scrolling form, so whether a given control is hittable
  /// depends on how much sits above it — which changes whenever a section is added.
  /// This test failed exactly that way once the pane picker grew from five tabs to
  /// eight. Asserting `isHittable` and giving up made the test a tripwire for layout
  /// rather than for persistence, which is not what it is for.
  @discardableResult
  private func scrollIntoView(_ element: XCUIElement, attempts: Int = 8) -> Bool {
    if element.isHittable { return true }
    let form = app.scrollViews.firstMatch
    guard form.exists else { return element.isHittable }
    for _ in 0..<attempts {
      form.scroll(byDeltaX: 0, deltaY: -60)
      if element.isHittable { return true }
    }
    return element.isHittable
  }

  /// Read a toggle's on/off state without depending on how it bridges.
  ///
  /// `XCUIElement.value` is `Any?`, and the concrete type is not contractual: the
  /// same switch arrives as an `Int` under one Xcode and as the string "0"/"1" under
  /// another. `value as? Int ?? 0` therefore quietly reports "off" for every state on
  /// the toolchain where it bridges as a string, which is exactly how this test passed
  /// locally and failed in CI.
  private func isOn(_ element: XCUIElement) -> Bool {
    switch element.value {
    case let flag as Bool: return flag
    case let number as NSNumber: return number.boolValue
    case let text as String: return ["1", "true", "on"].contains(text.lowercased())
    default: return false
    }
  }

  /// The settings pane picker is the app's own control, so each tab carries an
  /// identifier. It used to be a `TabView`, whose tabs surfaced as bare radio buttons
  /// and could only be found by their visible label — which made this test break on a
  /// rename that changed nothing about behaviour.
  private func settingsTab(_ title: String) -> XCUIElement {
    element("settings.tab.\(title.lowercased())")
  }

  /// Wait, then click. Clicking an element that has not appeared yet is the single
  /// most common source of a UI test that passes locally and fails in CI, and it is
  /// entirely avoidable.
  @discardableResult
  private func click(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
    let target = element(identifier)
    guard target.waitForExistence(timeout: timeout) else {
      XCTFail("\(identifier) never appeared")
      return false
    }
    target.click()
    return true
  }

  private func completeOnboarding() {
    // Onboarding may already be behind us when preferences were kept from a previous
    // launch, so its absence is not a failure — only never reaching the main window is.
    if app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10) {
      for _ in 0..<12 {
        if element("onboarding.finish").exists {
          element("onboarding.finish").click()
          break
        }
        guard element("onboarding.skip").exists else { break }
        element("onboarding.skip").click()
      }
    }
    XCTAssertTrue(
      element("sidebar.home").waitForExistence(timeout: 10),
      "never reached the main window after onboarding")
  }
}
