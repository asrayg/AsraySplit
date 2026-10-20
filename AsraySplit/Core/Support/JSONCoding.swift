import Foundation

/// JSON coders matching PostgREST/PostgreSQL output: snake_case keys, timestamps with optional
/// fractional seconds and offsets, and plain `YYYY-MM-DD` dates.
enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PostgresDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(text)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PostgresDate.timestamp(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PostgresDate.timestamp(date))
        }
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()
}

enum PostgresDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        var text = raw.replacingOccurrences(of: " ", with: "T")
        if text.count == 10 { return dayFormatter.date(from: text) }
        // PostgreSQL emits "+00" style offsets and up to 6 fractional digits; normalize both.
        if let match = text.range(of: #"[+-]\d{2}$"#, options: .regularExpression) { text.replaceSubrange(match, with: text[match] + ":00") }
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let digits = text[text.index(after: dot)..<zone]
            let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text.replaceSubrange(text.index(after: dot)..<zone, with: trimmed)
        }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    static func timestamp(_ date: Date) -> String { fractional.string(from: date) }

    /// Calendar day in UTC, used for trip start/end dates.
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}

/// A `Decimal` that round-trips exactly through JSON numbers or strings (PostgreSQL `numeric`).
@propertyWrapper
struct ExactDecimal: Codable, Hashable, Sendable {
    var wrappedValue: Decimal

    init(wrappedValue: Decimal) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            wrappedValue = value
        } else {
            // Double's description is the shortest string that round-trips, e.g. 0.0067 -> "0.0067".
            let number = try container.decode(Double.self)
            wrappedValue = Decimal(string: "\(number)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(number)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(NSDecimalNumber(decimal: wrappedValue).stringValue)
    }
}

@propertyWrapper
struct OptionalExactDecimal: Codable, Hashable, Sendable {
    var wrappedValue: Decimal?

    init(wrappedValue: Decimal?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { wrappedValue = nil } else { wrappedValue = try ExactDecimal(from: decoder).wrappedValue }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(NSDecimalNumber(decimal: wrappedValue).stringValue) } else { try container.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: OptionalExactDecimal.Type, forKey key: Key) throws -> OptionalExactDecimal {
        try decodeIfPresent(type, forKey: key) ?? OptionalExactDecimal(wrappedValue: nil)
    }
}

/// Minimal JSON value for loosely-typed payloads such as activity data and AI results.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String), integer(Int64), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var int64Value: Int64? {
        switch self {
        case .integer(let value): value
        case .number(let value): Int64(exactly: value.rounded())
        case .string(let value): Int64(value)
        default: nil
        }
    }
    subscript(key: String) -> JSONValue? { if case .object(let value) = self { value[key] } else { nil } }
}

extension JSONValue {
    /// Converts any Encodable into a JSONValue using the API encoder (snake_case keys preserved).
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONCoding.encoder.encode(value))
    }

    static func decoding(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
