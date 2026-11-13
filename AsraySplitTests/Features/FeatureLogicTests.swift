import XCTest
@testable import AsraySplit

final class DeepLinkTests: XCTestCase {
    let host = "asraysplit.app"

    func testParsesInviteLinks() {
        XCTAssertEqual(DeepLink.parse(URL(string: "https://asraysplit.app/join/abcDEF123_-xyz789abcDEF123_-xyz")!, inviteHost: host), .join(secret: "abcDEF123_-xyz789abcDEF123_-xyz"))
        XCTAssertEqual(DeepLink.parse(URL(string: "asraysplit://join/ABCD-EFGH")!, inviteHost: host), .join(secret: "ABCD-EFGH"))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://asraysplit.app/join?code=ABCDEFGH")!, inviteHost: host), .join(secret: "ABCDEFGH"))
        XCTAssertNil(DeepLink.parse(URL(string: "https://evil.example/join/ABCDEFGH")!, inviteHost: host))
        XCTAssertNil(DeepLink.parse(URL(string: "asraysplit://join/ab")!, inviteHost: host))
        XCTAssertNil(DeepLink.parse(URL(string: "asraysplit://join/%3Cscript%3E")!, inviteHost: host))
    }

    func testParsesRecordLinks() {
        let trip = UUID(), expense = UUID()
        XCTAssertEqual(DeepLink.parse(DeepLink.url(for: .trip(trip))!, inviteHost: host), .trip(trip))
        XCTAssertEqual(DeepLink.parse(DeepLink.url(for: .expense(trip, expense))!, inviteHost: host), .expense(trip, expense))
        XCTAssertEqual(DeepLink.parse(DeepLink.url(for: .balances(trip))!, inviteHost: host), .balances(trip))
        XCTAssertNil(DeepLink.parse(URL(string: "asraysplit://trip/not-a-uuid")!, inviteHost: host))
        if case .authCallback = DeepLink.parse(URL(string: "asraysplit://auth-callback?code=1")!, inviteHost: host) {} else { XCTFail() }
    }

    func testNotificationRouting() {
        let trip = UUID(), entity = UUID()
        XCTAssertEqual(DeepLink.fromNotification(["trip_id": trip.uuidString, "kind": "expense_created", "entity_id": entity.uuidString]), .expense(trip, entity))
        XCTAssertEqual(DeepLink.fromNotification(["trip_id": trip.uuidString, "kind": "settlement_recorded"]), .balances(trip))
        XCTAssertEqual(DeepLink.fromNotification(["trip_id": trip.uuidString, "kind": "member_joined"]), .trip(trip))
        XCTAssertNil(DeepLink.fromNotification(["kind": "expense_created"]))
    }
}

func makeTrip(currency: CurrencyCode = .usd, names: [String] = ["Ana", "Ben", "Cy"]) -> Trip {
    let id = UUID()
    let people = names.enumerated().map { Participant(id: fixedIDs(names.count)[$0.offset], tripId: id, displayName: $0.element) }
    return Trip(id: id, ownerId: nil, name: "Test", emoji: "✈️", colorHex: "23C58A", startDate: nil, endDate: nil, timezone: "UTC",
                baseCurrency: currency, budgetMinor: nil, revision: 1, archivedAt: nil, createdAt: .now, updatedAt: .now, myRole: .owner,
                participants: people, members: [])
}

final class ExporterTests: XCTestCase {
    func testCSVReconcilesAndEscapes() throws {
        let trip = makeTrip()
        let ids = trip.participants.map(\.id)
        let payload = ExpensePayload(title: "Dinner, \"fancy\"", notes: "=SUM(A1)", category: .food, paymentMethod: .card, spentAt: .now, splitMethod: .equal,
                                     amountMinor: 1000, currency: .usd, payments: [.init(participantId: ids[0], amountMinor: 1000)],
                                     allocations: try SplitRule.equal(ids).allocate(total: 1000).map { .init(participantId: $0.key, amountMinor: $0.value) })
        let expense = try payload.optimisticExpense(tripID: trip.id, baseCurrency: .usd, revision: 1, createdBy: nil)
        let csv = TripExporter.csv(trip: trip, expenses: [expense], settlements: [])
        XCTAssertTrue(csv.contains("\"Dinner, \"\"fancy\"\"\""))
        XCTAssertTrue(csv.contains("'=SUM(A1)"))
        XCTAssertTrue(csv.contains(",10.00,USD,"))
        XCTAssertTrue(csv.contains(",3.34,3.33,3.33"))
        XCTAssertEqual(TripExporter.escape("-5.00"), "-5.00")
    }
}

final class ReceiptTextParserTests: XCTestCase {
    func testParsesSimpleReceipt() {
        let result = ReceiptTextParser.parse("CAFE MARGO\nTable 12\nLatte 5.50\n2 x Toast 8.00\nSubtotal 13.50\nTax 1.21\nTOTAL 14.71\nVISA 14.71", currency: .usd, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(result.merchant, "Cafe Margo")
        XCTAssertEqual(result.items.map(\.amountMinor), [550, 800])
        XCTAssertEqual(result.items.last?.quantity, 2)
        XCTAssertEqual(result.subtotalMinor, 1350)
        XCTAssertEqual(result.taxMinor, 121)
        XCTAssertEqual(result.totalMinor, 1471)
        XCTAssertTrue(ReceiptReconciler.isReconciled(result.totals))
        XCTAssertEqual(result.source, .onDevice)
    }

    func testParsesEuropeanAndZeroDecimalReceipts() {
        let eu = ReceiptTextParser.parse("Taberna\nBacalhau 18,50\nVinho 12,00\nIVA 3,50\nTotal 34,00", currency: .eur, locale: Locale(identifier: "pt_PT"))
        XCTAssertEqual(eu.items.map(\.amountMinor), [1850, 1200])
        XCTAssertEqual(eu.taxMinor, 350)
        XCTAssertEqual(eu.totalMinor, 3400)
        let jp = ReceiptTextParser.parse("ラーメン屋\nRamen ¥1,200\nGyoza ¥450\nTotal ¥1,650", currency: .jpy, locale: Locale(identifier: "ja_JP"))
        XCTAssertEqual(jp.items.map(\.amountMinor), [1200, 450])
        XCTAssertEqual(jp.totalMinor, 1650)
    }

    func testDiscountsAndServiceFees() {
        let result = ReceiptTextParser.parse("Shop\nShirt 40.00\nDiscount -5.00\nService charge 3.50\nTip 4.00\nTotal 42.50", currency: .usd, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(result.discountMinor, 500)
        XCTAssertEqual(result.serviceFeeMinor, 350)
        XCTAssertEqual(result.tipMinor, 400)
        XCTAssertTrue(ReceiptReconciler.isReconciled(result.totals))
    }
}

final class ScanValidationTests: XCTestCase {
    func testRejectsOutOfBoundsAIOutput() {
        XCTAssertThrowsError(try ScanResultValidator.decode(Data(#"{"items":[{"name":"x","amount_minor":-1}],"tax_minor":-5,"confidence":0.9}"#.utf8)))
        XCTAssertThrowsError(try ScanResultValidator.decode(Data(#"{"items": "nope"}"#.utf8)))
        XCTAssertThrowsError(try ScanResultValidator.decode(Data("not json".utf8)))
        let items = (0..<301).map { _ in #"{"name":"a","amount_minor":1}"# }.joined(separator: ",")
        XCTAssertThrowsError(try ScanResultValidator.decode(Data(#"{"items":[\#(items)],"confidence":1}"#.utf8)))
    }

    func testCleansValidOutput() throws {
        let result = try ScanResultValidator.decode(Data(#"{"merchant":"  Cafe  ","currency":"usd","items":[{"name":"","amount_minor":550,"confidence":3}],"subtotal_minor":550,"total_minor":550,"confidence":0.9,"purchased_at":"2099-01-01T00:00:00Z"}"#.utf8))
        XCTAssertEqual(result.merchant, "Cafe")
        XCTAssertEqual(result.currency, .usd)
        XCTAssertEqual(result.items.first?.confidence, 1)
        XCTAssertFalse(result.items.first?.name.isEmpty ?? true)
        XCTAssertNil(result.purchasedAt, "future dates are discarded")
    }
}

final class OutboxCoalescerTests: XCTestCase {
    private func op(_ kind: OutboxKind, entity: UUID, payload: String? = nil, revision: Int? = nil) -> OutboxOperation {
        OutboxOperation(tripID: UUID(), entityID: entity, kind: kind, payload: payload.map { Data($0.utf8) }, expectedRevision: revision, createdAt: .now, nextAttemptAt: .now)
    }

    func testMergeRules() {
        let entity = UUID()
        let create = op(.createExpense, entity: entity, payload: "v1")
        guard case .replace(_, let merged) = OutboxCoalescer.merge(existing: create, new: op(.updateExpense, entity: entity, payload: "v2", revision: 1)) else { return XCTFail() }
        XCTAssertEqual(merged.kind, .createExpense)
        XCTAssertEqual(merged.payload, Data("v2".utf8))

        XCTAssertEqual(OutboxCoalescer.merge(existing: create, new: op(.deleteExpense, entity: entity, revision: 1)), .cancel(existingID: create.id))

        let update = op(.updateExpense, entity: entity, payload: "a", revision: 4)
        guard case .replace(_, let updated) = OutboxCoalescer.merge(existing: update, new: op(.updateExpense, entity: entity, payload: "b", revision: 5)) else { return XCTFail() }
        XCTAssertEqual(updated.expectedRevision, 4, "keeps the revision the user started from")
        guard case .replace(_, let deleted) = OutboxCoalescer.merge(existing: update, new: op(.deleteExpense, entity: entity, revision: 5)) else { return XCTFail() }
        XCTAssertEqual(deleted.kind, .deleteExpense)
        XCTAssertEqual(deleted.expectedRevision, 4)

        let new = op(.createExpense, entity: UUID())
        XCTAssertEqual(OutboxCoalescer.merge(existing: nil, new: new), .append(new))
    }

    func testBackoffGrowsAndCaps() {
        XCTAssertLessThan(OutboxCoalescer.backoff(attempt: 1, jitter: 1), OutboxCoalescer.backoff(attempt: 3, jitter: 1))
        XCTAssertEqual(OutboxCoalescer.backoff(attempt: 30, jitter: 1), 300)
    }
}

@MainActor
final class ExpenseEditorModelTests: XCTestCase {
    func testEqualSplitPayload() throws {
        let trip = makeTrip()
        let model = ExpenseEditorModel(trip: trip, me: trip.participants[0].id)
        model.title = "Groceries"
        model.amountMinor = 1000
        XCTAssertTrue(model.canSave)
        let payload = try model.makePayload()
        XCTAssertEqual(payload.allocations.map(\.amountMinor).reduce(0, +), 1000)
        XCTAssertEqual(payload.payments.first?.participantId, trip.participants[0].id)
        XCTAssertNoThrow(try payload.validate(baseCurrency: .usd, participants: Set(trip.participants.map(\.id))))
    }

    func testValidationMessages() {
        let trip = makeTrip()
        let model = ExpenseEditorModel(trip: trip, me: trip.participants[0].id)
        XCTAssertNotNil(model.validationMessage)
        model.title = "Hotel"
        model.amountMinor = 30_000
        model.setSplitMethod(.exact)
        XCTAssertTrue(model.canSave, "switching seeds exact values from the equal split")
        model.exactValues[trip.participants[0].id] = 0
        XCTAssertFalse(model.canSave)
        XCTAssertNotNil(model.remainingExactMinor)
        model.setSplitMethod(.percentage)
        model.percentValues = [trip.participants[0].id: 50, trip.participants[1].id: 30, trip.participants[2].id: 20]
        XCTAssertTrue(model.canSave)
        model.setCurrency(.eur)
        XCTAssertFalse(model.canSave, "foreign currency needs a rate")
        model.exchangeRate = Decimal(string: "1.1")
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.baseAmount?.minorUnits, 33_000)
    }

    func testEditingPreservesIdentity() throws {
        let trip = makeTrip()
        let ids = trip.participants.map(\.id)
        let original = try ExpensePayload(title: "Taxi", category: .transport, paymentMethod: .card, spentAt: .now, splitMethod: .shares, amountMinor: 900, currency: .usd,
                                          payments: [.init(participantId: ids[1], amountMinor: 900)],
                                          allocations: [.init(participantId: ids[0], amountMinor: 600, inputValue: 2), .init(participantId: ids[1], amountMinor: 300, inputValue: 1)])
            .optimisticExpense(tripID: trip.id, baseCurrency: .usd, revision: 3, createdBy: nil)
        let model = ExpenseEditorModel(trip: trip, editing: original, me: ids[0])
        XCTAssertEqual(model.splitMethod, .shares)
        XCTAssertEqual(model.shareValues[ids[0]], 2)
        model.amountMinor = 1200
        let payload = try model.makePayload()
        XCTAssertEqual(payload.id, original.id)
        XCTAssertEqual(payload.idempotencyKey, original.idempotencyKey)
        XCTAssertEqual(payload.allocations.first { $0.participantId == ids[0] }?.amountMinor, 800)
    }
}

@MainActor
final class ScanReviewModelTests: XCTestCase {
    func testItemizedPayloadReconciles() throws {
        let trip = makeTrip()
        let ids = trip.participants.map(\.id)
        let result = ReceiptScanResult(merchant: "Cafe", currency: .usd, items: [.init(name: "Latte", amountMinor: 550), .init(name: "Toast", amountMinor: 800)],
                                       subtotalMinor: 1350, taxMinor: 121, tipMinor: 200, totalMinor: 1671, confidence: 0.9, source: .ai)
        let model = ScanReviewModel(trip: trip, result: result, receiptID: UUID(), me: ids[0])
        XCTAssertEqual(model.unassignedLines.count, 2)
        XCTAssertNotNil(model.blockingIssue)
        model.toggle(ids[0], on: model.lines[0].id)
        model.assignAll(model.lines[1].id)
        XCTAssertNil(model.blockingIssue)
        let payload = try model.makePayload()
        XCTAssertEqual(payload.amountMinor, 1671)
        XCTAssertEqual(payload.splitMethod, .itemized)
        XCTAssertEqual(payload.allocations.map(\.amountMinor).reduce(0, +), 1671)
        XCTAssertEqual(payload.receiptIds.count, 1)
        XCTAssertNoThrow(try payload.validate(baseCurrency: .usd, participants: Set(ids)))
    }

    func testDiscrepancyRequiresConfirmation() {
        let trip = makeTrip()
        let result = ReceiptScanResult(items: [.init(name: "A", amountMinor: 500)], totalMinor: 999, confidence: 0.5, source: .onDevice)
        let model = ScanReviewModel(trip: trip, result: result, receiptID: nil, me: trip.participants[0].id)
        model.assignAll(model.lines[0].id)
        XCTAssertNotNil(model.blockingIssue)
        model.acceptDiscrepancy = true
        XCTAssertNil(model.blockingIssue)
    }
}

