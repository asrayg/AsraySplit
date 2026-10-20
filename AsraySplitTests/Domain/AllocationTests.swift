import XCTest
@testable import AsraySplit

/// Deterministic pseudo-random generator so property tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func fixedIDs(_ count: Int) -> [UUID] {
    (0..<count).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))! }
}

final class AllocationTests: XCTestCase {
    func testEqualSplitGivesRemainderToLowestIDs() throws {
        let ids = fixedIDs(3)
        let result = try SplitRule.equal(ids).allocate(total: 100)
        XCTAssertEqual(result[ids[0]], 34)
        XCTAssertEqual(result[ids[1]], 33)
        XCTAssertEqual(result[ids[2]], 33)
    }

    func testEqualSplitIsIndependentOfInputOrder() throws {
        let ids = fixedIDs(7)
        let a = try SplitRule.equal(ids).allocate(total: 1003)
        let b = try SplitRule.equal(ids.reversed()).allocate(total: 1003)
        XCTAssertEqual(a, b)
    }

    func testNegativeTotalsMirrorPositive() throws {
        let ids = fixedIDs(3)
        let positive = try SplitRule.equal(ids).allocate(total: 100)
        let negative = try SplitRule.equal(ids).allocate(total: -100)
        XCTAssertEqual(negative, positive.mapValues { -$0 })
    }

    func testZeroAmountRejected() {
        XCTAssertThrowsError(try SplitRule.equal(fixedIDs(2)).allocate(total: 0)) { XCTAssertEqual($0 as? SplitError, .zeroAmount) }
        XCTAssertThrowsError(try SplitRule.equal([]).allocate(total: 10)) { XCTAssertEqual($0 as? SplitError, .noParticipants) }
    }

    func testExactMustMatchTotal() throws {
        let ids = fixedIDs(2)
        XCTAssertEqual(try SplitRule.exact([ids[0]: 700, ids[1]: 300]).allocate(total: 1000), [ids[0]: 700, ids[1]: 300])
        XCTAssertThrowsError(try SplitRule.exact([ids[0]: 700, ids[1]: 299]).allocate(total: 1000)) {
            XCTAssertEqual($0 as? SplitError, .sumMismatch(expected: 1000, actual: 999))
        }
        XCTAssertThrowsError(try SplitRule.exact([ids[0]: 1100, ids[1]: -100]).allocate(total: 1000))
    }

    func testPercentages() throws {
        let ids = fixedIDs(3)
        let thirds: [UUID: Decimal] = [ids[0]: Decimal(string: "33.3333")!, ids[1]: Decimal(string: "33.3333")!, ids[2]: Decimal(string: "33.3334")!]
        let result = try SplitRule.percentage(thirds).allocate(total: 10_000)
        XCTAssertEqual(result.values.reduce(0, +), 10_000)
        XCTAssertThrowsError(try SplitRule.percentage([ids[0]: 50, ids[1]: 49]).allocate(total: 100)) {
            XCTAssertEqual($0 as? SplitError, .percentagesMustTotal100(actual: 99))
        }
        XCTAssertThrowsError(try SplitRule.percentage([ids[0]: Decimal(string: "50.00001")!, ids[1]: Decimal(string: "49.99999")!]).allocate(total: 100))
        XCTAssertThrowsError(try SplitRule.percentage([ids[0]: 150, ids[1]: -50]).allocate(total: 100))
    }

    func testSharesWithFractionalWeights() throws {
        let ids = fixedIDs(3)
        // couple (2), single (1), child (0.5) of 3.50
        let result = try SplitRule.shares([ids[0]: 2, ids[1]: 1, ids[2]: Decimal(string: "0.5")!]).allocate(total: 350)
        XCTAssertEqual(result, [ids[0]: 200, ids[1]: 100, ids[2]: 50])
        XCTAssertThrowsError(try SplitRule.shares([ids[0]: 0, ids[1]: 0]).allocate(total: 350))
        XCTAssertThrowsError(try SplitRule.shares([ids[0]: Decimal(string: "0.0001")!]).allocate(total: 350))
    }

    func testZeroShareParticipantGetsNothing() throws {
        let ids = fixedIDs(3)
        let result = try SplitRule.shares([ids[0]: 1, ids[1]: 1, ids[2]: 0]).allocate(total: 101)
        XCTAssertEqual(result[ids[2]], 0)
        XCTAssertEqual(result.values.reduce(0, +), 101)
    }

    func testAdjustments() throws {
        let ids = fixedIDs(3)
        // 90.00 dinner, first person had a 15.00 extra drink, second gets 3.00 off.
        let result = try SplitRule.adjustment([ids[0]: 1500, ids[1]: -300, ids[2]: 0]).allocate(total: 9000)
        XCTAssertEqual(result.values.reduce(0, +), 9000)
        XCTAssertEqual(result[ids[0]], 2600 + 1500)
        XCTAssertEqual(result[ids[1]], 2600 - 300)
        XCTAssertEqual(result[ids[2]], 2600)
        XCTAssertThrowsError(try SplitRule.adjustment([ids[0]: 10_000, ids[1]: 0]).allocate(total: 9000)) {
            XCTAssertEqual($0 as? SplitError, .adjustmentsExceedTotal)
        }
    }

    func testItemizedWithTaxTipAndDiscount() throws {
        let ids = fixedIDs(3)
        let split = ItemizedSplit(items: [
            .init(id: UUID(), amountMinor: 1600, assignees: [ids[0]: 1]),
            .init(id: UUID(), amountMinor: 1850, assignees: [ids[1]: 1]),
            .init(id: UUID(), amountMinor: 1100, assignees: [ids[0]: 1, ids[1]: 1, ids[2]: 1]),
            .init(id: UUID(), amountMinor: 700, assignees: [ids[2]: 1]),
        ], taxMinor: 459, serviceFeeMinor: 0, tipMinor: 1050, discountMinor: 200)
        let result = try SplitRule.itemized(split).allocate(total: split.totalMinor)
        XCTAssertEqual(result.values.reduce(0, +), 5250 + 459 + 1050 - 200)
        XCTAssertGreaterThan(result[ids[1]]!, result[ids[2]]!)
    }

    func testItemizedRejectsUnassignedItems() {
        let ids = fixedIDs(2)
        let orphan = UUID()
        let split = ItemizedSplit(items: [.init(id: UUID(), amountMinor: 500, assignees: [ids[0]: 1]), .init(id: orphan, amountMinor: 300, assignees: [:])])
        XCTAssertThrowsError(try split.allocate()) { XCTAssertEqual($0 as? SplitError, .unassignedItems([orphan])) }
    }

    func testItemizedWeightedSharedItem() throws {
        let ids = fixedIDs(2)
        let split = ItemizedSplit(items: [.init(id: UUID(), amountMinor: 900, assignees: [ids[0]: 2, ids[1]: 1])])
        XCTAssertEqual(try split.allocate(), [ids[0]: 600, ids[1]: 300])
    }

    // MARK: Property tests

    func testPropertyAllocationsAlwaysSumToTotal() throws {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<5_000 {
            let count = Int.random(in: 1...12, using: &rng)
            let ids = (0..<count).map { _ in UUID() }
            let total = Int64.random(in: -10_000_000...10_000_000, using: &rng)
            guard total != 0 else { continue }
            let weights = Dictionary(uniqueKeysWithValues: ids.map { ($0, Decimal(Int.random(in: 0...20, using: &rng)) / 4) })
            if weights.values.allSatisfy({ $0 == 0 }) { continue }

            let equal = try SplitRule.equal(ids).allocate(total: total)
            XCTAssertEqual(equal.values.reduce(0, +), total)
            let spread = equal.values.map { $0 }.max()! - equal.values.map { $0 }.min()!
            XCTAssertLessThanOrEqual(spread, 1, "Equal split differs by more than one minor unit")

            let shares = try SplitRule.shares(weights).allocate(total: total)
            XCTAssertEqual(shares.values.reduce(0, +), total)
            for (id, weight) in weights where weight == 0 { XCTAssertEqual(shares[id], 0) }
        }
    }

    func testPropertyLargeValuesDoNotOverflow() throws {
        let ids = fixedIDs(5)
        let total: Int64 = 9_000_000_000_000_000
        let result = try SplitRule.shares(Dictionary(uniqueKeysWithValues: ids.map { ($0, Decimal(999_999)) })).allocate(total: total)
        XCTAssertEqual(result.values.reduce(0, +), total)
    }

    func testPropertyItemizedAlwaysReconciles() throws {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<1_000 {
            let ids = fixedIDs(Int.random(in: 1...6, using: &rng))
            let items = (0..<Int.random(in: 1...15, using: &rng)).map { _ -> ItemizedSplit.Item in
                let assignees = ids.filter { _ in Bool.random(using: &rng) }
                return .init(id: UUID(), amountMinor: Int64.random(in: 1...50_000, using: &rng),
                             assignees: Dictionary(uniqueKeysWithValues: (assignees.isEmpty ? [ids[0]] : assignees).map { ($0, Decimal(Int.random(in: 1...3, using: &rng))) }))
            }
            let split = ItemizedSplit(items: items, taxMinor: Int64.random(in: 0...5_000, using: &rng), serviceFeeMinor: Int64.random(in: 0...2_000, using: &rng),
                                      tipMinor: Int64.random(in: 0...5_000, using: &rng), discountMinor: Int64.random(in: 0...1_000, using: &rng))
            let result = try split.allocate()
            XCTAssertEqual(result.values.reduce(0, +), split.totalMinor)
        }
    }
}
