import XCTest

/// Prints the real element tree. Kept in the suite because "which query finds this
/// control?" is a question that comes back every time the UI changes, and guessing at
/// it is slower than looking.
@MainActor
final class HierarchyDiagnostic: XCTestCase {
  func testDumpOnboardingHierarchy() {
    let app = XCUIApplication()
    app.launchArguments += ["-rant-ui-testing", "YES", "-rant-ui-skip-onboarding", "YES"]
    app.launch()
    _ = app.staticTexts["Home"].waitForExistence(timeout: 10)
    print("=== RANT HIERARCHY BEGIN ===")
    print(app.debugDescription)
    print("=== RANT HIERARCHY END ===")
  }
}
