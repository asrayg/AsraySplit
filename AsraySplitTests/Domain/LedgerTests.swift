import XCTest
@testable import AsraySplit

final class LedgerTests: XCTestCase {
    func testBalancesFromExpensesAndSettlements() throws {
        let ids = fixedIDs(3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let dinner = LedgerExpenseFact(id: UUID(), payments: [a: 9000], allocations: [a: 3000, b: 3000, c: 3000])
        let taxi = LedgerExpenseFact(id: UUID(), payments: [b: 3000], allocations: [a: 1000, b: 1000, c: 1000])
        let settle = LedgerSettlementFact(id: UUID(), from: c, to: a, amountMinor: 2000)
        let balances = try Ledger.balances(participants: ids, expenses: [dinner, taxi], settlements: [settle])
        let net = Dictionary(uniqueKeysWithValues: balances.map { ($0.participantID, $0.netMinor) })
        XCTAssertEqual(net[a], 9000 - 4000 - 2000)
        XCTAssertEqual(net[b], 3000 - 4000)
        XCTAssertEqual(net[c], -4000 + 2000)
        XCTAssertEqual(net.values.reduce(0, +), 0)
    }

    func testFullSettlementZerosEveryone() throws {
        let ids = fixedIDs(2)
        let expense = LedgerExpenseFact(id: UUID(), payments: [ids[0]: 1000], allocations: [ids[0]: 500, ids[1]: 500])
        let settle = LedgerSettlementFact(id: UUID(), from: ids[1], to: ids[0], amountMinor: 500)
        let balances = try Ledger.balances(participants: ids, expenses: [expense], settlements: [settle])
        XCTAssertTrue(balances.allSatisfy { $0.netMinor == 0 })
        XCTAssertTrue(Ledger.simplify(balances).isEmpty)
    }

    func testRejectsUnbalancedExpenseAndSelfSettlement() {
        let ids = fixedIDs(2)
        XCTAssertThrowsError(try Ledger.balances(participants: ids, expenses: [.init(id: UUID(), payments: [ids[0]: 100], allocations: [ids[1]: 99])], settlements: []))
        XCTAssertThrowsError(try Ledger.balances(participants: ids, expenses: [], settlements: [.init(id: UUID(), from: ids[0], to: ids[0], amountMinor: 1)]))
        XCTAssertThrowsError(try Ledger.balances(participants: ids, expenses: [], settlements: [.init(id: UUID(), from: ids[0], to: ids[1], amountMinor: 0)]))
    }

    func testSimplifyMatchesDatabaseFixture() {
        // Same fixture as supabase/tests/004_balances_test.sql.
        let ids = fixedIDs(4)
        let balances = [
            ParticipantBalance(participantID: ids[0], paidMinor: 10_000, owedMinor: 2_500),
            ParticipantBalance(participantID: ids[1], paidMinor: 0, owedMinor: 2_500),
            ParticipantBalance(participantID: ids[2], paidMinor: 0, owedMinor: 2_500),
            ParticipantBalance(participantID: ids[3], paidMinor: 0, owedMinor: 2_500),
        ]
        XCTAssertEqual(Ledger.simplify(balances), [
            SuggestedTransfer(from: ids[1], to: ids[0], amountMinor: 2_500),
            SuggestedTransfer(from: ids[2], to: ids[0], amountMinor: 2_500),
            SuggestedTransfer(from: ids[3], to: ids[0], amountMinor: 2_500),
        ])
    }

    func testPropertySimplificationPreservesNetsAndUsesFewTransfers() throws {
        var rng = SeededGenerator(seed: 2026)
        for _ in 0..<2_000 {
            let ids = (0..<Int.random(in: 2...10, using: &rng)).map { _ in UUID() }
            var expenses: [LedgerExpenseFact] = []
            for _ in 0..<Int.random(in: 1...20, using: &rng) {
                let total = Int64.random(in: 1...100_000, using: &rng)
                let payer = ids.randomElement(using: &rng)!
                let consumers = ids.filter { _ in Bool.random(using: &rng) }
                let allocations = try SplitRule.equal(consumers.isEmpty ? [payer] : consumers).allocate(total: total)
                expenses.append(.init(id: UUID(), payments: [payer: total], allocations: allocations))
            }
            let balances = try Ledger.balances(participants: ids, expenses: expenses, settlements: [])
            XCTAssertEqual(balances.map(\.netMinor).reduce(0, +), 0)

            let transfers = Ledger.simplify(balances)
            let nonZero = balances.filter { $0.netMinor != 0 }.count
            XCTAssertLessThanOrEqual(transfers.count, max(nonZero - 1, 0))
            XCTAssertTrue(transfers.allSatisfy { $0.amountMinor > 0 && $0.from != $0.to })

            // Applying the suggested transfers as settlements zeroes every balance.
            let settlements = transfers.map { LedgerSettlementFact(id: UUID(), from: $0.from, to: $0.to, amountMinor: $0.amountMinor) }
            let after = try Ledger.balances(participants: ids, expenses: expenses, settlements: settlements)
            XCTAssertTrue(after.allSatisfy { $0.netMinor == 0 })
        }
    }
}

final class ReceiptReconcilerTests: XCTestCase {
    func testReconciledReceipt() {
        let totals = ReceiptTotals(itemsMinor: [550, 800], subtotalMinor: 1350, taxMinor: 121, declaredTotalMinor: 1471)
        XCTAssertTrue(ReceiptReconciler.isReconciled(totals))
    }

    func testDetectsMismatches() {
        let totals = ReceiptTotals(itemsMinor: [550, 800], subtotalMinor: 1360, taxMinor: 121, declaredTotalMinor: 1471)
        XCTAssertEqual(ReceiptReconciler.discrepancies(totals), [
            .itemsDoNotMatchSubtotal(itemsSum: 1350, subtotal: 1360),
            .totalMismatch(computed: 1481, declared: 1471),
        ])
        XCTAssertEqual(ReceiptReconciler.discrepancies(ReceiptTotals(itemsMinor: [])), [.empty])
        XCTAssertEqual(ReceiptReconciler.discrepancies(ReceiptTotals(itemsMinor: [100], taxMinor: -1)), [.negativeComponent])
    }

    func testVATInclusiveReceiptWithServiceFeeAndDiscount() {
        let totals = ReceiptTotals(itemsMinor: [1200, 950, 400], subtotalMinor: 2550, serviceFeeMinor: 255, tipMinor: 0, discountMinor: 300, declaredTotalMinor: 2505)
        XCTAssertTrue(ReceiptReconciler.isReconciled(totals))
    }
}
