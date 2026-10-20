import XCTest

/// Runs against the in-memory demo backend (`-uiTesting`), so no network or credentials are needed.
final class CoreFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCreateTripAddExpenseAndSeeBalance() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-emptyDemo"]
        app.launch()

        let add = app.buttons["addMenu"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["New trip"].tap()
        let name = app.textFields["tripName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Kyoto")
        let guest = app.textFields["Add a traveler’s name"]
        guest.tap()
        guest.typeText("Kai\n")
        app.buttons["saveTrip"].tap()

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
        XCTAssertTrue(app.staticTexts["Kai pays You"].waitForExistence(timeout: 10) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pays'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testDemoTripLoads() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon Escape"].waitForExistence(timeout: 15))
    }
}
