import XCTest
@testable import AsraySplit

@MainActor
final class EasterEggTests: XCTestCase {
    override func setUp() { UserDefaults.standard.removeObject(forKey: "eggs.found"); UserDefaults.standard.removeObject(forKey: "eggs.turkeyShown"); UserDefaults.standard.removeObject(forKey: "eggs.lateNight") }

    func testThereAreTwelve() { XCTAssertEqual(Egg.allCases.count, 12) }

    func testChatWords() {
        let eggs = EasterEggs(); var toasts: [String] = []; eggs.toast = { toasts.append($0) }
        eggs.chatSent("WEPA let's go"); eggs.chatSent("who wants a medalla"); eggs.chatSent("mofongo time"); eggs.chatSent("hello")
        XCTAssertEqual(eggs.foundCount, 3)
        XCTAssertEqual(toasts.count, 3)
        XCTAssertNotNil(eggs.rain)
    }

    func testTapCounterNeedsAllTapsInWindow() {
        let eggs = EasterEggs()
        XCTAssertFalse((1...6).map { _ in eggs.tap("coqui", needed: 7) }.contains(true))
        XCTAssertTrue(eggs.tap("coqui", needed: 7))
        XCTAssertFalse(eggs.tap("coqui", needed: 7), "counter resets after firing")
    }

    func testBigSpenderThreshold() {
        let eggs = EasterEggs()
        eggs.expenseSaved(amountMinor: 49_999); XCTAssertEqual(eggs.foundCount, 0)
        eggs.expenseSaved(amountMinor: 50_000); XCTAssertTrue(eggs.found.contains(Egg.bigSpender.rawValue))
    }

    func testThanksgivingAndLateNightOncePerDay() throws {
        let eggs = EasterEggs(); var toasts = 0; eggs.toast = { _ in toasts += 1 }
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 26; c.hour = 3
        c.timeZone = TimeZone(identifier: "America/Puerto_Rico")
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: c))
        eggs.appOpened(now: date); eggs.appOpened(now: date)
        XCTAssertTrue(eggs.found.isSuperset(of: [Egg.turkey.rawValue, Egg.lateNight.rawValue]))
        XCTAssertEqual(toasts, 2, "each fires once that day")
    }
}
