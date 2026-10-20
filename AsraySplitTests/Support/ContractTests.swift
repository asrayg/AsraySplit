import XCTest
@testable import AsraySplit

/// Decodes JSON produced by the real database RPCs (regenerate with
/// `DB_FIXTURES_OUT=$PWD/AsraySplitTests/Fixtures scripts/db-test.sh`).
final class ContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "Missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    func testDecodesTrip() throws {
        let trip = try JSONCoding.decoder.decode(Trip.self, from: fixture("trip"))
        XCTAssertEqual(trip.name, "Fixture Trip")
        XCTAssertEqual(trip.baseCurrency, .usd)
        XCTAssertEqual(trip.budgetMinor, 150_000)
        XCTAssertEqual(trip.myRole, .owner)
        XCTAssertEqual(trip.participants.count, 2)
        XCTAssertNotNil(trip.startDate)
        XCTAssertEqual(try JSONCoding.decoder.decode([Trip].self, from: fixture("trips")).count, 1)
    }

    func testDecodesExpenseAndMatchesLocalProjection() throws {
        let expenses = try JSONCoding.decoder.decode([Expense].self, from: fixture("expenses"))
        let expense = try XCTUnwrap(expenses.first)
        XCTAssertEqual(expense.originalCurrency, .jpy)
        XCTAssertEqual(expense.originalMinor, 10_000)
        XCTAssertEqual(expense.baseMinor, 6_700)
        XCTAssertEqual(expense.exchangeRate, Decimal(string: "0.0067"))
        XCTAssertEqual(expense.splitMethod, .itemized)
        XCTAssertEqual(expense.items.first?.quantity, 2)
        XCTAssertEqual(expense.items.first?.assignees.count, 2)
        XCTAssertEqual(expense.tags, ["food"])

        // The offline projection must compute the same base shares as the server.
        let payload = ExpensePayload(expense: expense)
        let projected = try payload.optimisticExpense(tripID: expense.tripId, baseCurrency: .usd, revision: 1, createdBy: nil)
        XCTAssertEqual(projected.baseMinor, expense.baseMinor)
        XCTAssertEqual(projected.allocations.map(\.baseAmountMinor), expense.allocations.map(\.baseAmountMinor))
        XCTAssertEqual(projected.payments.map(\.baseAmountMinor), expense.payments.map(\.baseAmountMinor))
    }

    func testDecodesLedgerAggregates() throws {
        let settlements = try JSONCoding.decoder.decode([Settlement].self, from: fixture("settlements"))
        XCTAssertEqual(settlements.first?.method, .venmo)
        XCTAssertEqual(settlements.first?.reference, "abc")

        let balances = try JSONCoding.decoder.decode([ServerBalance].self, from: fixture("balances"))
        XCTAssertEqual(balances.map(\.netMinor).reduce(0, +), 0)

        // Server balances equal the Swift ledger computed from the same facts.
        let expenses = try JSONCoding.decoder.decode([Expense].self, from: fixture("expenses"))
        let local = try Ledger.balances(participants: balances.map(\.participantId), expenses: expenses.map(\.ledgerFact), settlements: settlements.map(\.ledgerFact))
        XCTAssertEqual(local.map(\.netMinor), balances.sorted { $0.participantId.sortKey < $1.participantId.sortKey }.map(\.netMinor))

        let suggestions = try JSONCoding.decoder.decode([SuggestedTransfer].self, from: fixture("suggestions"))
        XCTAssertEqual(suggestions, Ledger.simplify(local))

        let summary = try JSONCoding.decoder.decode(TripSummary.self, from: fixture("summary"))
        XCTAssertEqual(summary.totalSpentMinor, 6_700)
        XCTAssertEqual(summary.byCategory.first?.category, .food)

        let activity = try JSONCoding.decoder.decode([ActivityEvent].self, from: fixture("activity"))
        let created = try XCTUnwrap(activity.first { $0.kind == "expense_created" })
        XCTAssertEqual(created.value("amount_minor")?.int64Value, 10_000, "\(created.data)")
        XCTAssertEqual(created.value("description")?.stringValue, "Dinner")
    }

    func testDecodesInvites() throws {
        let invite = try JSONCoding.decoder.decode(TripInvite.self, from: fixture("invite"))
        XCTAssertEqual(invite.code.count, 8)
        let preview = try JSONCoding.decoder.decode(InvitePreview.self, from: fixture("invite_preview"))
        XCTAssertEqual(preview.name, "Fixture Trip")
        XCTAssertFalse(preview.alreadyMember)
        XCTAssertEqual(preview.claimableParticipants.map(\.displayName), ["Guest Gus"])
    }

    func testPayloadEncodingUsesServerKeys() throws {
        let payload = ExpensePayload(title: "Taxi", category: .transport, paymentMethod: .cash, spentAt: Date(timeIntervalSince1970: 0), splitMethod: .equal,
                                     amountMinor: 1000, currency: .eur, exchangeRate: Decimal(string: "1.0825"),
                                     payments: [.init(participantId: UUID(), amountMinor: 1000)], allocations: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(payload)) as? [String: Any])
        XCTAssertEqual(json["description"] as? String, "Taxi")
        XCTAssertEqual(json["amount_minor"] as? Int, 1000)
        XCTAssertEqual(json["exchange_rate"] as? String, "1.0825")
        XCTAssertEqual(json["payment_method"] as? String, "cash")
        XCTAssertNotNil(json["idempotency_key"])
        XCTAssertEqual(json["spent_at"] as? String, "1970-01-01T00:00:00.000Z")
    }

    func testPostgresDateParsing() {
        XCTAssertNotNil(PostgresDate.parse("2026-10-20T07:41:12.345678+00:00"))
        XCTAssertNotNil(PostgresDate.parse("2026-10-20 07:41:12+00"))
        XCTAssertNotNil(PostgresDate.parse("2026-10-20T07:41:12Z"))
        XCTAssertEqual(PostgresDate.parse("2026-11-01").map(PostgresDate.day), "2026-11-01")
    }
}
