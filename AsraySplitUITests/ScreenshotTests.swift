import XCTest

/// Captures key screens for visual review and App Store screenshots. Writes PNGs to SCREENSHOT_DIR
/// when set (simulator only); otherwise attaches them to the test result.
final class ScreenshotTests: XCTestCase {
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func run(contentSize: String?, suffix: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (contentSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        XCTAssertTrue(app.navigationBars["Puerto Rico Thanksgiving"].waitForExistence(timeout: 15))
        capture("02-trip\(suffix)")
        let balances = app.buttons["balancesLink"].firstMatch
        for _ in 0..<4 where !balances.isHittable { app.swipeUp() }
        balances.tap()
        sleep(1)
        capture("03-balances\(suffix)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let add = app.buttons["addExpense"]
        for _ in 0..<4 where !add.isHittable { app.swipeDown() }
        add.tap()
        sleep(1)
        capture("04-add-expense\(suffix)")
    }

    func testScreensDefaultSize() { run(contentSize: nil, suffix: "") }
    func testScreensLargestAccessibilitySize() { run(contentSize: "UICTContentSizeCategoryAccessibilityXXXL", suffix: "-ax5") }
}
