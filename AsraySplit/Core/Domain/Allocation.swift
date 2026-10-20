import Foundation

/// Stable ordering used everywhere a tie must be broken. Matches PostgreSQL `uuid` ordering
/// (bytewise == lowercase hexadecimal string ordering).
extension UUID {
    var sortKey: String { uuidString.lowercased() }
}

enum AllocationError: Error, Equatable, Sendable {
    case noParticipants
    case nonPositiveWeight(UUID)
    case zeroTotalWeight
    case overflow
}

/// Deterministic largest-remainder apportionment of an integer amount by integer weights.
///
/// The result always sums exactly to `total`. Remainder units go to the largest fractional remainders,
/// ties broken by ascending participant ID, so every device and the server compute identical splits.
enum Apportionment {
    static func allocate(_ total: Int64, weights: [UUID: Int64]) throws -> [UUID: Int64] {
        guard !weights.isEmpty else { throw AllocationError.noParticipants }
        for (id, weight) in weights where weight < 0 { throw AllocationError.nonPositiveWeight(id) }
        let weightSum = try Int64.checkedSum(weights.values)
        guard weightSum > 0 else { throw AllocationError.zeroTotalWeight }
        if total == 0 { return weights.mapValues { _ in 0 } }

        let magnitude = total.magnitude
        let divisor = UInt64(weightSum)
        var floors: [UUID: UInt64] = [:]
        var remainders: [(id: UUID, remainder: UInt64)] = []
        var assigned: UInt64 = 0

        for (id, weight) in weights {
            let product = magnitude.multipliedFullWidth(by: UInt64(weight))
            let (quotient, remainder) = divisor.dividingFullWidth(product)
            floors[id] = quotient
            assigned += quotient
            remainders.append((id, remainder))
        }

        var leftover = magnitude - assigned
        remainders.sort { lhs, rhs in
            lhs.remainder != rhs.remainder ? lhs.remainder > rhs.remainder : lhs.id.sortKey < rhs.id.sortKey
        }
        var index = 0
        while leftover > 0 {
            let id = remainders[index % remainders.count].id
            // Zero-weight participants never receive remainder units.
            if weights[id, default: 0] > 0 {
                floors[id, default: 0] += 1
                leftover -= 1
            }
            index += 1
        }

        let sign: Int64 = total < 0 ? -1 : 1
        return floors.mapValues { Int64($0) * sign }
    }

    /// Splits `total` equally among `participants`.
    static func equal(_ total: Int64, among participants: [UUID]) throws -> [UUID: Int64] {
        guard !participants.isEmpty else { throw AllocationError.noParticipants }
        return try allocate(total, weights: Dictionary(participants.map { ($0, Int64(1)) }, uniquingKeysWith: { first, _ in first }))
    }
}

/// Exact currency conversion with a stored rate. Rounds half away from zero, like PostgreSQL `round(numeric)`.
enum CurrencyConversion {
    /// - Parameter rate: units of `to` per one unit of `from` (major units).
    static func convert(_ minorUnits: Int64, from: CurrencyCode, to: CurrencyCode, rate: Decimal) throws -> Int64 {
        if from == to { return minorUnits }
        var value = Decimal(minorUnits) * rate * Decimal(to.minorUnitScale) / Decimal(from.minorUnitScale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard rounded <= Decimal(Int64.max), rounded >= Decimal(Int64.min) else { throw MoneyError.overflow }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    /// Converts a set of original-currency shares into base-currency shares that sum exactly to the
    /// converted total, using the original shares as apportionment weights.
    static func convertShares(_ shares: [UUID: Int64], total: Int64, from: CurrencyCode, to: CurrencyCode, rate: Decimal) throws -> [UUID: Int64] {
        if from == to { return shares }
        let baseTotal = try convert(total, from: from, to: to, rate: rate)
        let weights = shares.mapValues { $0.magnitude > UInt64(Int64.max) ? Int64.max : Int64($0.magnitude) }
        if weights.values.allSatisfy({ $0 == 0 }) { return shares.mapValues { _ in 0 } }
        return try Apportionment.allocate(baseTotal, weights: weights)
    }
}
