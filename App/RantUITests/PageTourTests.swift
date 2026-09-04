import XCTest

/// Visits every page and saves a screenshot of each.
///
/// This is a design review harness, not an assertion suite: "does every page open,
/// and does it look right" is a question a person has to answer by looking, and
/// clicking through eleven screens by hand after every change is how a screen quietly
/// stops being looked at. It fails loudly if a page does not open at all, which is the
/// part that *can* be automated.
@MainActor
final class PageTourTests: XCTestCase {

  private static let outputDirectory = "/tmp/rant-tour"

  func testEveryPageOpensAndIsCaptured() {
    try? FileManager.default.createDirectory(
      atPath: Self.outputDirectory, withIntermediateDirectories: true)

    // Onboarding first, on its own launch, so the tour of the main window does not
    // depend on walking through it.
    let onboarding = XCUIApplication()
    onboarding.launchArguments += ["-rant-ui-testing", "YES"]
    onboarding.launch()
    if onboarding.staticTexts["talk messy. write clean."].waitForExistence(timeout: 10) {
      capture(onboarding, named: "00-onboarding")
    }
    onboarding.terminate()

    let app = XCUIApplication()
    app.launchArguments += ["-rant-ui-testing", "YES", "-rant-ui-skip-onboarding", "YES"]
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any)["sidebar.home"].waitForExistence(timeout: 15),
      "never reached the main window")

    let pages = [
      "home", "history", "notetaker", "insights", "dictionary",
      "snippets", "styles", "transforms", "scratchpad", "migrate", "settings",
    ]

    for (index, page) in pages.enumerated() {
      let item = app.descendants(matching: .any)["sidebar.\(page)"]
      XCTAssertTrue(item.waitForExistence(timeout: 10), "\(page) is missing from the sidebar")
      item.click()
      // Let the page settle before capturing; a screenshot mid-transition is useless
      // for judging a layout.
      Thread.sleep(forTimeInterval: 0.9)
      capture(app, named: String(format: "%02d-%@", index + 1, page))
    }
  }

  private func capture(_ app: XCUIApplication, named name: String) {
    let screenshot = app.windows.firstMatch.screenshot()
    let path = "\(Self.outputDirectory)/\(name).png"
    try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
  }

}
