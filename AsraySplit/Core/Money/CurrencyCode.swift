import Foundation

/// An ISO 4217 alphabetic currency code with the metadata needed for exact minor-unit math.
struct CurrencyCode: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let rawValue: String

    init?(_ value: String) {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        rawValue = code
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let code = CurrencyCode(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid currency code \(raw)"))
        }
        self = code
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    /// Number of digits after the decimal separator (ISO 4217 minor unit exponent).
    var fractionDigits: Int {
        if Self.zeroDecimal.contains(rawValue) { return 0 }
        if Self.threeDecimal.contains(rawValue) { return 3 }
        return 2
    }

    /// 10^fractionDigits as an integer scale.
    var minorUnitScale: Int64 {
        var scale: Int64 = 1
        for _ in 0..<fractionDigits { scale *= 10 }
        return scale
    }

    func localizedName(locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: rawValue) ?? rawValue
    }

    static func < (lhs: CurrencyCode, rhs: CurrencyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    // Kept in sync with `public.currencies` seed data in the database migrations.
    static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
    static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static let usd: CurrencyCode = "USD"
    static let eur: CurrencyCode = "EUR"
    static let gbp: CurrencyCode = "GBP"
    static let jpy: CurrencyCode = "JPY"
    static let kwd: CurrencyCode = "KWD"

    /// Currencies offered in pickers. The database accepts any code present in `public.currencies`.
    static let common: [CurrencyCode] = {
        let codes: [String] = ["USD", "EUR", "GBP", "CAD", "AUD", "NZD", "JPY", "CHF", "MXN", "INR", "THB", "SGD", "HKD", "KRW", "SEK", "NOK", "DKK", "ISK", "BRL", "ZAR", "AED", "KWD", "TRY", "IDR", "VND", "PHP", "CZK", "PLN", "HUF"]
        return codes.compactMap { CurrencyCode($0) }
    }()
}

extension CurrencyCode: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        guard let code = CurrencyCode(value) else { preconditionFailure("Invalid currency literal \(value)") }
        self = code
    }
}
