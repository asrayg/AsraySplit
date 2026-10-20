import Foundation

enum SplitMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case equal, exact, percentage, shares, adjustment, itemized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equal: String(localized: "Equally")
        case .exact: String(localized: "Exact amounts")
        case .percentage: String(localized: "Percentages")
        case .shares: String(localized: "Shares")
        case .adjustment: String(localized: "Adjustments")
        case .itemized: String(localized: "Itemized")
        }
    }

    /// Methods offered in the manual expense editor (itemized comes from the receipt flow).
    static let manual: [SplitMethod] = [.equal, .exact, .percentage, .shares, .adjustment]
}

enum SplitError: Error, Equatable, Sendable {
    case noParticipants
    case zeroAmount
    case sumMismatch(expected: Int64, actual: Int64)
    case percentagesMustTotal100(actual: Decimal)
    case invalidValue(UUID)
    case tooPrecise(UUID)
    case adjustmentsExceedTotal
    case unassignedItems([UUID])
    case mixedSigns
    case overflow
}

/// How an expense total is divided among participants. Values are user inputs; `allocate` turns them
/// into exact minor-unit shares that always sum to the total.
enum SplitRule: Equatable, Sendable {
    case equal([UUID])
    case exact([UUID: Int64])
    /// Percent values such as 33.3333. At most four fractional digits.
    case percentage([UUID: Decimal])
    /// Positive weights such as 1, 2, or 1.5. At most three fractional digits.
    case shares([UUID: Decimal])
    /// Each participant's adjustment (may be zero or negative) is added after splitting the rest equally.
    case adjustment([UUID: Int64])
    case itemized(ItemizedSplit)

    var method: SplitMethod {
        switch self {
        case .equal: .equal
        case .exact: .exact
        case .percentage: .percentage
        case .shares: .shares
        case .adjustment: .adjustment
        case .itemized: .itemized
        }
    }

    var participants: [UUID] {
        let ids: [UUID]
        switch self {
        case .equal(let list): ids = list
        case .exact(let values): ids = Array(values.keys)
        case .percentage(let values): ids = Array(values.keys)
        case .shares(let values): ids = Array(values.keys)
        case .adjustment(let values): ids = Array(values.keys)
        case .itemized(let split): ids = Array(split.participants)
        }
        return Array(Set(ids)).sorted { $0.sortKey < $1.sortKey }
    }

    func allocate(total: Int64) throws -> [UUID: Int64] {
        guard total != 0 else { throw SplitError.zeroAmount }
        do {
            switch self {
            case .equal(let ids):
                guard !ids.isEmpty else { throw SplitError.noParticipants }
                return try Apportionment.equal(total, among: ids)

            case .exact(let values):
                guard !values.isEmpty else { throw SplitError.noParticipants }
                for (id, value) in values where value != 0 && (value < 0) != (total < 0) { throw SplitError.invalidValue(id) }
                let sum = try Int64.checkedSum(values.values)
                guard sum == total else { throw SplitError.sumMismatch(expected: total, actual: sum) }
                return values

            case .percentage(let values):
                guard !values.isEmpty else { throw SplitError.noParticipants }
                let weights = try Self.scaledWeights(values, digits: 4)
                let sum = values.values.reduce(Decimal(0), +)
                guard sum == 100 else { throw SplitError.percentagesMustTotal100(actual: sum) }
                return try Apportionment.allocate(total, weights: weights)

            case .shares(let values):
                guard !values.isEmpty else { throw SplitError.noParticipants }
                let weights = try Self.scaledWeights(values, digits: 3)
                guard weights.values.contains(where: { $0 > 0 }) else { throw SplitError.noParticipants }
                return try Apportionment.allocate(total, weights: weights)

            case .adjustment(let values):
                guard !values.isEmpty else { throw SplitError.noParticipants }
                let adjustments = try Int64.checkedSum(values.values)
                let (remaining, overflow) = total.subtractingReportingOverflow(adjustments)
                guard !overflow else { throw SplitError.overflow }
                guard remaining == 0 || (remaining < 0) == (total < 0) else { throw SplitError.adjustmentsExceedTotal }
                let base = remaining == 0 ? values.mapValues { _ in Int64(0) } : try Apportionment.equal(remaining, among: Array(values.keys))
                var result: [UUID: Int64] = [:]
                for (id, adjustment) in values {
                    let (value, overflow) = base[id, default: 0].addingReportingOverflow(adjustment)
                    guard !overflow else { throw SplitError.overflow }
                    guard value == 0 || (value < 0) == (total < 0) else { throw SplitError.invalidValue(id) }
                    result[id] = value
                }
                return result

            case .itemized(let split):
                let computed = try split.allocate()
                let sum = try Int64.checkedSum(computed.values)
                guard sum == total else { throw SplitError.sumMismatch(expected: total, actual: sum) }
                return computed
            }
        } catch let error as AllocationError {
            switch error {
            case .noParticipants, .zeroTotalWeight: throw SplitError.noParticipants
            case .nonPositiveWeight(let id): throw SplitError.invalidValue(id)
            case .overflow: throw SplitError.overflow
            }
        } catch is MoneyError {
            throw SplitError.overflow
        }
    }

    /// Converts decimal inputs to integer weights scaled by 10^digits, rejecting negative or overly precise values.
    private static func scaledWeights(_ values: [UUID: Decimal], digits: Int) throws -> [UUID: Int64] {
        var scale = Decimal(1)
        for _ in 0..<digits { scale *= 10 }
        var weights: [UUID: Int64] = [:]
        for (id, value) in values {
            guard value >= 0 else { throw SplitError.invalidValue(id) }
            var scaled = value * scale
            var rounded = Decimal()
            NSDecimalRound(&rounded, &scaled, 0, .plain)
            guard rounded == scaled else { throw SplitError.tooPrecise(id) }
            guard rounded <= Decimal(Int64.max) else { throw SplitError.overflow }
            weights[id] = NSDecimalNumber(decimal: rounded).int64Value
        }
        return weights
    }
}

/// A receipt or manual itemization: each line item is split among its assignees by weight, then
/// tax, service fees, tip, and discounts are distributed in proportion to each person's item subtotal.
struct ItemizedSplit: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        var id: UUID
        var amountMinor: Int64
        /// Participant -> weight (1 for an even share). Empty means unassigned.
        var assignees: [UUID: Decimal]
    }

    var items: [Item]
    var taxMinor: Int64 = 0
    var serviceFeeMinor: Int64 = 0
    var tipMinor: Int64 = 0
    var discountMinor: Int64 = 0

    var participants: Set<UUID> { Set(items.flatMap { $0.assignees.keys }) }

    var itemsSubtotal: Int64 { (try? Int64.checkedSum(items.map(\.amountMinor))) ?? 0 }
    var extrasMinor: Int64 { taxMinor + serviceFeeMinor + tipMinor - discountMinor }
    var totalMinor: Int64 { itemsSubtotal + extrasMinor }

    func allocate() throws -> [UUID: Int64] {
        let unassigned = items.filter { $0.amountMinor != 0 && !$0.assignees.values.contains { $0 > 0 } }.map(\.id)
        guard unassigned.isEmpty else { throw SplitError.unassignedItems(unassigned) }
        guard !participants.isEmpty else { throw SplitError.noParticipants }

        var itemShares: [UUID: Int64] = [:]
        for item in items where item.amountMinor != 0 {
            let positive = item.assignees.filter { $0.value > 0 }
            let shares = try SplitRule.shares(positive).allocate(total: item.amountMinor)
            for (id, value) in shares { itemShares[id, default: 0] += value }
        }

        let extras = extrasMinor
        guard extras != 0 else { return itemShares }
        let weights = itemShares.mapValues { max($0, 0) }
        guard weights.values.contains(where: { $0 > 0 }) else { throw SplitError.mixedSigns }
        let extraShares = try Apportionment.allocate(extras, weights: weights)
        var result = itemShares
        for (id, value) in extraShares { result[id, default: 0] += value }
        return result
    }
}
