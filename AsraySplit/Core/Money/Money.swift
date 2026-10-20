import Foundation

enum MoneyError: Error, Equatable, Sendable {
    case currencyMismatch(CurrencyCode, CurrencyCode)
    case overflow
    case tooManyFractionDigits(allowed: Int)
    case invalidNumber
    case negativeNotAllowed
}

/// An exact amount of money stored as integer minor units (cents, yen, fils…).
///
/// `Double` must never be used for money. Arithmetic is checked for overflow and currency mismatch.
struct Money: Hashable, Codable, Sendable, CustomStringConvertible {
    let minorUnits: Int64
    let currency: CurrencyCode

    init(minorUnits: Int64, currency: CurrencyCode) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    static func zero(_ currency: CurrencyCode) -> Money { Money(minorUnits: 0, currency: currency) }

    var isZero: Bool { minorUnits == 0 }
    var isNegative: Bool { minorUnits < 0 }
    var isPositive: Bool { minorUnits > 0 }

    /// Exact decimal value in major units, e.g. 1234 USD minor units -> 12.34.
    var decimalValue: Decimal {
        Decimal(minorUnits) / Decimal(currency.minorUnitScale)
    }

    /// Converts a decimal major-unit amount into exact minor units, rejecting extra precision.
    init(decimal: Decimal, currency: CurrencyCode) throws {
        var scaled = decimal * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw MoneyError.tooManyFractionDigits(allowed: currency.fractionDigits) }
        guard rounded <= Decimal(Int64.max), rounded >= Decimal(Int64.min) else { throw MoneyError.overflow }
        self.init(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currency: currency)
    }

    func adding(_ other: Money) throws -> Money {
        guard other.currency == currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        let (value, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: value, currency: currency)
    }

    func subtracting(_ other: Money) throws -> Money {
        guard other.currency == currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        let (value, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: value, currency: currency)
    }

    var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }
    var absolute: Money { Money(minorUnits: minorUnits == .min ? .max : abs(minorUnits), currency: currency) }

    static func sum(_ values: [Money], currency: CurrencyCode) throws -> Money {
        try values.reduce(.zero(currency)) { try $0.adding($1) }
    }

    var description: String { "\(decimalValue) \(currency.rawValue)" }

    func formatted(locale: Locale = .current) -> String {
        decimalValue.formatted(.currency(code: currency.rawValue).locale(locale).precision(.fractionLength(currency.fractionDigits)))
    }
}

extension Int64 {
    /// Checked sum used by domain code; traps are never acceptable for user money.
    static func checkedSum<S: Sequence>(_ values: S) throws -> Int64 where S.Element == Int64 {
        try values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw MoneyError.overflow }
            return result
        }
    }
}
