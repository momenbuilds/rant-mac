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
final class OnboardingUITests: XCTestCase {

  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    // A clean slate each run: the app reads this and starts from first-run state with
    // an in-memory database, so a UI test never touches the developer's real history.
    app.launchArguments += ["-rant-ui-testing", "YES"]
    app.launch()
  }

  override func tearDown() {
    app.terminate()
  }

  // MARK: - Onboarding

  func testOnboardingOpensOnTheWelcomeStep() {
    XCTAssertTrue(app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10))
  }

  func testEveryOnboardingStepCanBeSkippedSoNobodyIsTrapped() {
    XCTAssertTrue(app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10))
    // A permission the user will not grant must never be a dead end.
    for _ in 0..<6 {
      let skip = app.buttons["Skip"]
      if skip.exists { skip.click() } else { break }
    }
    XCTAssertTrue(app.buttons["Start using Rant"].waitForExistence(timeout: 5))
  }

  func testPermissionStepsExplainWhyBeforeAsking() {
    XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
    app.buttons["Continue"].click()
    XCTAssertTrue(app.staticTexts["Microphone"].waitForExistence(timeout: 5))
    // The explanation, not just the ask.
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'hold your dictation key'"))
        .firstMatch.exists)
  }

  func testCompletingOnboardingReachesTheMainWindow() {
    completeOnboarding()
    XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
  }

  // MARK: - Navigation

  func testSidebarNavigatesToEachDestination() {
    completeOnboarding()
    for destination in ["History", "Dictionary", "Snippets", "Settings", "Home"] {
      let item = app.staticTexts[destination]
      XCTAssertTrue(item.waitForExistence(timeout: 5), "\(destination) missing from the sidebar")
      item.click()
    }
  }

  // MARK: - CRUD

  func testAddingADictionaryEntry() {
    completeOnboarding()
    app.staticTexts["Dictionary"].click()

    let add = app.buttons["Add an entry"].exists ? app.buttons["Add an entry"] : app.buttons["Add"]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.click()

    let spoken = app.textFields["When I say"]
    XCTAssertTrue(spoken.waitForExistence(timeout: 5))
    spoken.click()
    spoken.typeText("super base")

    let written = app.textFields["Write"]
    written.click()
    written.typeText("Supabase")

    app.buttons["Save"].click()
    XCTAssertTrue(app.staticTexts["Supabase"].waitForExistence(timeout: 5))
  }

  func testAddingASnippet() {
    completeOnboarding()
    app.staticTexts["Snippets"].click()

    let add = app.buttons["Add a snippet"].exists ? app.buttons["Add a snippet"] : app.buttons["Add"]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.click()

    let trigger = app.textFields["When I say"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 5))
    trigger.click()
    trigger.typeText("my meeting link")

    app.textViews.firstMatch.click()
    app.textViews.firstMatch.typeText("https://cal.com/rant")

    app.buttons["Save"].click()
    XCTAssertTrue(app.staticTexts["my meeting link"].waitForExistence(timeout: 5))
  }

  // MARK: - Settings

  func testChangingTheCleanupLevelPersistsAcrossRelaunch() {
    completeOnboarding()
    app.staticTexts["Settings"].click()
    app.buttons["Intelligence"].click()

    let picker = app.popUpButtons["How much cleanup"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    picker.click()
    app.menuItems["Light"].click()

    app.terminate()
    app.launchArguments += ["-rant-ui-testing-keep-preferences", "YES"]
    app.launch()

    app.staticTexts["Settings"].click()
    app.buttons["Intelligence"].click()
    XCTAssertEqual(app.popUpButtons["How much cleanup"].value as? String, "Light")
  }

  /// The privacy claims are load-bearing, so they should be visible in the app and
  /// not only in a README that nobody opens.
  func testThePrivacyPaneStatesTheGuarantees() {
    completeOnboarding()
    app.staticTexts["Settings"].click()
    app.buttons["Privacy"].click()
    XCTAssertTrue(
      app.staticTexts["No account, no telemetry, no analytics SDK"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Rant never reads from or types into a password field"].exists)
  }

  // MARK: - Helpers

  private func completeOnboarding() {
    guard app.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10) else { return }
    for _ in 0..<8 {
      if app.buttons["Start using Rant"].exists {
        app.buttons["Start using Rant"].click()
        return
      }
      if app.buttons["Skip"].exists { app.buttons["Skip"].click() } else { break }
    }
  }
}
