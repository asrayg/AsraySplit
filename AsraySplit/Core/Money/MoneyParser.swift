import Foundation

/// Parses user-typed amounts into exact minor units using the user's locale.
///
/// Parsing happens once at the edge of the system; everything downstream uses integer minor units.
struct MoneyParser: Sendable {
    var locale: Locale = .current

    func parse(_ input: String, currency: CurrencyCode, allowNegative: Bool = false) throws -> Money {
        let decimal = try parseDecimal(input)
        if !allowNegative && decimal < 0 { throw MoneyError.negativeNotAllowed }
        return try Money(decimal: decimal, currency: currency)
    }

    /// Accepts grouping separators, currency symbols, and both the locale decimal separator and `.`.
    func parseDecimal(_ input: String) throws -> Decimal {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MoneyError.invalidNumber }

        var negative = false
        if text.hasPrefix("-") || text.hasPrefix("−") { negative = true; text.removeFirst() }
        if text.hasPrefix("(") && text.hasSuffix(")") { negative = true; text = String(text.dropFirst().dropLast()) }

        // Remove currency symbols, letters and spaces (including narrow no-break spaces used as grouping).
        text = String(text.unicodeScalars.filter { scalar in
            CharacterSet.decimalDigits.contains(scalar) || String(scalar) == decimalSeparator || String(scalar) == groupingSeparator || scalar == "." || scalar == ","
        }.map(Character.init))
        guard !text.isEmpty else { throw MoneyError.invalidNumber }

        // Decide which separator is the decimal one. The last separator wins when followed by 1–3 digits
        // and it is the locale decimal separator, or it is the only separator kind present.
        let normalized: String
        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        switch (lastDot, lastComma) {
        case (nil, nil):
            normalized = text
        case let (dot?, comma?):
            let decimalIndex = max(dot, comma)
            normalized = Self.normalize(text, decimalAt: decimalIndex)
        case let (dot?, nil):
            normalized = Self.resolveSingleKind(text, separator: ".", lastIndex: dot, localeDecimal: decimalSeparator)
        case let (nil, comma?):
            normalized = Self.resolveSingleKind(text, separator: ",", lastIndex: comma, localeDecimal: decimalSeparator)
        }

        guard !normalized.isEmpty, normalized.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            throw MoneyError.invalidNumber
        }
        return negative ? -value : value
    }

    private static func normalize(_ text: String, decimalAt index: String.Index) -> String {
        let integer = text[..<index].filter(\.isNumber)
        let fraction = text[text.index(after: index)...].filter(\.isNumber)
        return fraction.isEmpty ? String(integer) : "\(integer).\(fraction)"
    }

    private static func resolveSingleKind(_ text: String, separator: Character, lastIndex: String.Index, localeDecimal: String) -> String {
        let count = text.filter { $0 == separator }.count
        let digitsAfter = text.distance(from: text.index(after: lastIndex), to: text.endIndex)
        // "1,234,567" or "1.234.567": multiple occurrences means grouping.
        if count > 1 {
            let groups = text.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.dropFirst().allSatisfy({ $0.count == 3 }), (1...3).contains(groups.first?.count ?? 0) else { return "" }
            return text.filter(\.isNumber)
        }
        // A single separator followed by exactly three digits is ambiguous ("1,234"). Trust the locale.
        if digitsAfter == 3 && String(separator) != localeDecimal { return text.filter(\.isNumber) }
        return normalize(text, decimalAt: lastIndex)
    }

    /// Plain editable representation (no grouping, no symbol) for pre-filling text fields.
    func editableString(for money: Money) -> String {
        let digits = money.currency.fractionDigits
        let magnitude = money.minorUnits.magnitude
        let scale = UInt64(money.currency.minorUnitScale)
        let sign = money.minorUnits < 0 ? "-" : ""
        guard digits > 0 else { return "\(sign)\(magnitude)" }
        let fraction = String(magnitude % scale)
        let padded = String(repeating: "0", count: digits - fraction.count) + fraction
        return "\(sign)\(magnitude / scale)\(locale.decimalSeparator ?? ".")\(padded)"
    }
}
