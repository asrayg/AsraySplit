import XCTest
@testable import AsraySplit

final class MoneyTests: XCTestCase {
    func testFractionDigits() {
        XCTAssertEqual(CurrencyCode.usd.fractionDigits, 2)
        XCTAssertEqual(CurrencyCode.jpy.fractionDigits, 0)
        XCTAssertEqual(CurrencyCode.kwd.fractionDigits, 3)
        XCTAssertEqual(CurrencyCode(String("isk"))?.fractionDigits, 0)
        XCTAssertNil(CurrencyCode(String("US")))
        XCTAssertNil(CurrencyCode(String("U$D")))
    }

    func testDecimalConversionIsExact() throws {
        XCTAssertEqual(try Money(decimal: Decimal(string: "12.34")!, currency: .usd).minorUnits, 1234)
        XCTAssertEqual(try Money(decimal: 1500, currency: .jpy).minorUnits, 1500)
        XCTAssertEqual(try Money(decimal: Decimal(string: "1.005")!, currency: .kwd).minorUnits, 1005)
        XCTAssertThrowsError(try Money(decimal: Decimal(string: "1.005")!, currency: .usd))
        XCTAssertThrowsError(try Money(decimal: Decimal(string: "10.5")!, currency: .jpy))
    }

    func testArithmeticChecksCurrencyAndOverflow() throws {
        let a = Money(minorUnits: 100, currency: .usd)
        XCTAssertEqual(try a.adding(Money(minorUnits: 23, currency: .usd)).minorUnits, 123)
        XCTAssertThrowsError(try a.adding(Money(minorUnits: 1, currency: .eur))) { error in
            XCTAssertEqual(error as? MoneyError, .currencyMismatch(.usd, .eur))
        }
        XCTAssertThrowsError(try Money(minorUnits: .max, currency: .usd).adding(Money(minorUnits: 1, currency: .usd)))
        XCTAssertThrowsError(try Int64.checkedSum([.max, 1]))
    }

    func testParserHandlesLocales() throws {
        let us = MoneyParser(locale: Locale(identifier: "en_US"))
        let de = MoneyParser(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(try us.parse("1,234.56", currency: .usd).minorUnits, 123_456)
        XCTAssertEqual(try us.parse("$12.5", currency: .usd).minorUnits, 1250)
        XCTAssertEqual(try us.parse("1,234", currency: .usd).minorUnits, 123_400)
        XCTAssertEqual(try de.parse("1.234,56", currency: .eur).minorUnits, 123_456)
        XCTAssertEqual(try de.parse("12,5", currency: .eur).minorUnits, 1250)
        XCTAssertEqual(try de.parse("1.234", currency: .eur).minorUnits, 123_400)
        XCTAssertEqual(try us.parse("12.50", currency: .eur).minorUnits, 1250)
        XCTAssertEqual(try us.parse("¥1,500", currency: .jpy).minorUnits, 1500)
        XCTAssertEqual(try us.parse("1.250", currency: .kwd).minorUnits, 1250)
        XCTAssertEqual(try us.parse("0.5", currency: .usd).minorUnits, 50)
    }

    func testParserRejectsBadInput() {
        let us = MoneyParser(locale: Locale(identifier: "en_US"))
        XCTAssertThrowsError(try us.parse("", currency: .usd))
        XCTAssertThrowsError(try us.parse("abc", currency: .usd))
        XCTAssertThrowsError(try us.parse("1.234.5", currency: .usd))
        XCTAssertThrowsError(try us.parse("12.345", currency: .usd)) // decimal in en_US; too precise for USD
        XCTAssertThrowsError(try us.parse("-5", currency: .usd))
        XCTAssertEqual(try us.parse("-5", currency: .usd, allowNegative: true).minorUnits, -500)
        XCTAssertThrowsError(try us.parse("10.5", currency: .jpy))
    }

    func testEditableStringRoundTrips() throws {
        let us = MoneyParser(locale: Locale(identifier: "en_US"))
        for money in [Money(minorUnits: 5, currency: .usd), Money(minorUnits: 123_456, currency: .usd), Money(minorUnits: 1500, currency: .jpy), Money(minorUnits: 1005, currency: .kwd), Money(minorUnits: -250, currency: .usd)] {
            let text = us.editableString(for: money)
            XCTAssertEqual(try us.parse(text, currency: money.currency, allowNegative: true), money, text)
        }
        XCTAssertEqual(us.editableString(for: Money(minorUnits: 5, currency: .usd)), "0.05")
    }

    func testFormattingUsesCurrencyDigits() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(Money(minorUnits: 1500, currency: .jpy).formatted(locale: locale), "¥1,500")
        XCTAssertEqual(Money(minorUnits: 123_456, currency: .usd).formatted(locale: locale), "$1,234.56")
        XCTAssertTrue(Money(minorUnits: 1005, currency: .kwd).formatted(locale: locale).contains("1.005"))
    }

    func testCurrencyConversionRoundsHalfAwayFromZero() throws {
        // 10.00 EUR at 1.0825 USD/EUR = 10.825 -> 10.83
        XCTAssertEqual(try CurrencyConversion.convert(1000, from: .eur, to: .usd, rate: Decimal(string: "1.0825")!), 1083)
        XCTAssertEqual(try CurrencyConversion.convert(-1000, from: .eur, to: .usd, rate: Decimal(string: "1.0825")!), -1083)
        // 1,500 JPY at 0.0067 USD/JPY = 10.05
        XCTAssertEqual(try CurrencyConversion.convert(1500, from: .jpy, to: .usd, rate: Decimal(string: "0.0067")!), 1005)
        // 10.00 USD at 149.5 JPY/USD = 1495
        XCTAssertEqual(try CurrencyConversion.convert(1000, from: .usd, to: .jpy, rate: Decimal(string: "149.5")!), 1495)
        XCTAssertEqual(try CurrencyConversion.convert(777, from: .usd, to: .usd, rate: 2), 777)
    }

    func testConvertedSharesSumToConvertedTotal() throws {
        let ids = (0..<3).map { _ in UUID() }
        let shares = Dictionary(uniqueKeysWithValues: zip(ids, [Int64(334), 333, 333]))
        let converted = try CurrencyConversion.convertShares(shares, total: 1000, from: .eur, to: .jpy, rate: Decimal(string: "161.37")!)
        XCTAssertEqual(converted.values.reduce(0, +), try CurrencyConversion.convert(1000, from: .eur, to: .jpy, rate: Decimal(string: "161.37")!))
    }
}
