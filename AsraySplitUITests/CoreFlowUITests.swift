import XCTest

/// Runs against the in-memory demo backend (`-uiTesting`), so no network or credentials are needed.
final class CoreFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAddExpenseToCrewTripAndSeeBalance() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-emptyDemo"]
        app.launch()

        let addExpense = app.buttons["addExpense"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 10))
        addExpense.tap()
        let title = app.textFields["expenseTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Ramen")
        let amount = app.textFields["expenseAmount"]
        amount.tap()
        amount.typeText("30")
        app.buttons["saveExpense"].tap()

        XCTAssertTrue(app.staticTexts["Ramen"].waitForExistence(timeout: 10))
        app.buttons["balancesLink"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pays'")).firstMatch.waitForExistence(timeout: 10))
    }

    func testOpensStraightIntoTheCrewTrip() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-emptyDemo"]
        app.launch()
        XCTAssertTrue(app.buttons["addExpense"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Photos"].exists && app.staticTexts["Chat"].exists && app.staticTexts["Itinerary"].exists)
    }
}
