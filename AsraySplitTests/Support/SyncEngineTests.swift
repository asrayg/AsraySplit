import XCTest
@testable import AsraySplit

/// One simulated device: its own cache, outbox, network flag and signed-in user, sharing a server.
@MainActor
struct Device {
    let backend: InMemoryBackend
    let network: ManualNetworkStatus
    let store: TripStore
    let userID: UserID

    init(server: InMemoryServer, name: String) async throws {
        userID = UUID()
        backend = InMemoryBackend(server: server, userID: userID, displayName: name)
        await server.ensureProfile(userID, name: name)
        network = ManualNetworkStatus()
        store = TripStore(local: LocalStore.ephemeral(), backend: backend.backend, network: network)
        store.currentUserID = userID
    }

    func setOnline(_ online: Bool) async {
        network.set(online: online)
        await backend.server.setReachable(online)
    }

    func equalPayload(_ trip: Trip, title: String, amount: Int64, payer: ParticipantID? = nil) throws -> ExpensePayload {
        let ids = trip.participants.map(\.id)
        let shares = try SplitRule.equal(ids).allocate(total: amount)
        return ExpensePayload(title: title, category: .food, paymentMethod: .card, spentAt: .now, splitMethod: .equal, amountMinor: amount, currency: trip.baseCurrency,
                              payments: [.init(participantId: payer ?? store.me(in: trip)!.id, amountMinor: amount)],
                              allocations: shares.map { .init(participantId: $0.key, amountMinor: $0.value) })
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    private func sharedTrip(server: InMemoryServer) async throws -> (Device, Device, Trip) {
        let a = try await Device(server: server, name: "Ana")
        let b = try await Device(server: server, name: "Ben")
        var draft = TripDraft()
        draft.name = "Porto"
        draft.baseCurrency = .eur
        let created = try await a.store.createTrip(draft)
        let invite = try await a.backend.createInvite(tripID: created.id, role: .member, expiresInHours: 24, maxUses: 5, participantID: nil)
        _ = try await b.store.acceptInvite(secret: invite.code, claim: nil)
        await a.store.syncNow()
        await b.store.syncNow()
        return (a, b, a.store.trip(created.id)!)
    }

    func testOfflineCreateSyncsExactlyOnceAfterReconnect() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)

        await a.setOnline(false)
        let payload = try a.equalPayload(trip, title: "Port tasting", amount: 4500)
        try await a.store.saveExpense(payload, in: trip)
        // Visible immediately on the offline device, with a projected balance.
        let offline = await a.store.allExpenses(tripID: trip.id)
        XCTAssertEqual(offline.map(\.syncState), [.pending])
        let projected = await a.store.balances(for: trip)
        XCTAssertTrue(projected.isProjected)
        XCTAssertEqual(projected.net(for: a.store.me(in: trip)?.id), 2250)

        // Retrying while still offline never reaches the server.
        await a.store.sync.drain(force: true)
        await a.store.sync.drain(force: true)
        let none = await server.expenses.count
        XCTAssertEqual(none, 0)

        await a.setOnline(true)
        await a.store.sync.drain(force: true)
        await a.store.sync.drain(force: true) // a duplicate drain is harmless
        let count = await server.expenses.count
        XCTAssertEqual(count, 1, "the offline expense reaches the server exactly once")
        let pending = await a.store.unsyncedCount()
        XCTAssertEqual(pending, 0)

        // The second device converges on identical balances.
        await a.store.syncNow()
        await b.store.syncNow()
        let left = await a.store.balances(for: trip)
        let right = await b.store.balances(for: b.store.trip(trip.id)!)
        XCTAssertFalse(left.isProjected)
        XCTAssertEqual(left.balances, right.balances)
        XCTAssertEqual(left.suggestions, right.suggestions)
    }

    func testReplayedRequestAfterLostResponseDoesNotDuplicate() async throws {
        let server = InMemoryServer()
        let (a, _, trip) = try await sharedTrip(server: server)
        let payload = try a.equalPayload(trip, title: "Dinner", amount: 3000)
        let body = try JSONCoding.encoder.encode(payload)
        // Simulates the server committing but the response being lost: the client retries the same bytes.
        _ = try await a.backend.createExpense(tripID: trip.id, payload: body)
        _ = try await a.backend.createExpense(tripID: trip.id, payload: body)
        let count = await server.expenses.count
        XCTAssertEqual(count, 1)
        var changed = payload
        changed.title = "Different"
        do {
            _ = try await a.backend.createExpense(tripID: trip.id, payload: JSONCoding.encoder.encode(changed))
            XCTFail("reusing an idempotency key with a different payload must fail")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict(code: "idempotency_key_reused", currentRevision: nil))
        }
    }

    func testEditDeleteChangesBalancesOnBothDevices() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Hotel", amount: 20_000), in: trip)
        await a.store.sync.drain(force: true)
        await b.store.syncNow()
        let bTrip = b.store.trip(trip.id)!
        let syncedList = await b.store.allExpenses(tripID: trip.id)
        let synced = try XCTUnwrap(syncedList.first?.expense)

        var edit = ExpensePayload(expense: synced)
        edit.amountMinor = 30_000
        edit.payments = [.init(participantId: edit.payments[0].participantId, amountMinor: 30_000)]
        edit.allocations = try SplitRule.equal(bTrip.participants.map(\.id)).allocate(total: 30_000).map { .init(participantId: $0.key, amountMinor: $0.value) }
        try await b.store.saveExpense(edit, in: bTrip, editing: synced)
        await b.store.sync.drain(force: true)
        await a.store.syncNow()
        var balances = await a.store.balances(for: trip)
        XCTAssertEqual(balances.net(for: a.store.me(in: trip)?.id), 15_000)

        let currentCached = await a.store.expense(synced.id)
        let current = try XCTUnwrap(currentCached?.expense)
        try await a.store.deleteExpense(current)
        await a.store.sync.drain(force: true)
        await b.store.syncNow()
        balances = await b.store.balances(for: bTrip)
        XCTAssertTrue(balances.balances.allSatisfy { $0.netMinor == 0 })
        let tombstone = await server.expenses[synced.id]
        XCTAssertNotNil(tombstone?.deletedAt, "deletes are soft so history stays explainable")
    }

    func testConcurrentEditsSurfaceConflictInsteadOfOverwriting() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Museum", amount: 6000), in: trip)
        await a.store.sync.drain(force: true)
        await b.store.syncNow()
        let baseList = await a.store.allExpenses(tripID: trip.id)
        let base = try XCTUnwrap(baseList.first?.expense)

        // B goes offline and edits; A edits online first.
        await b.setOnline(false)
        var bEdit = ExpensePayload(expense: base); bEdit.title = "Museum (B)"
        try await b.store.saveExpense(bEdit, in: b.store.trip(trip.id)!, editing: base)
        await server.setReachable(true)
        var aEdit = ExpensePayload(expense: base); aEdit.title = "Museum (A)"
        try await a.store.saveExpense(aEdit, in: trip, editing: base)
        await a.store.sync.drain(force: true)

        await b.setOnline(true)
        let report = await b.store.sync.drain(force: true)
        XCTAssertEqual(report.conflicts, 1)
        let serverTitle = await server.expenses[base.id]?.title
        XCTAssertEqual(serverTitle, "Museum (A)", "the stale edit did not silently overwrite")
        await b.store.reload()
        let conflict = try XCTUnwrap(b.store.problemOperations.first)
        XCTAssertEqual(conflict.state, .conflict)

        // The user chooses "keep mine": it is resent on top of the latest revision.
        await b.store.keepMine(conflict)
        let resolvedTitle = await server.expenses[base.id]?.title
        XCTAssertEqual(resolvedTitle, "Museum (B)")
        XCTAssertTrue(b.store.problemOperations.isEmpty)
    }

    func testRejectedChangeIsKeptForRetryOrDiscard() async throws {
        let server = InMemoryServer()
        let (a, _, trip) = try await sharedTrip(server: server)
        await server.injectFailure(.validation(code: "allocations_mismatch", message: nil))
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Bad", amount: 100), in: trip)
        await a.store.sync.drain(force: true)
        await a.store.reload()
        let failed = try XCTUnwrap(a.store.problemOperations.first)
        XCTAssertEqual(failed.state, .failed)
        let cached = await a.store.allExpenses(tripID: trip.id)
        XCTAssertEqual(cached.first?.syncState, .failed, "user work is never silently dropped")

        await a.store.retry(failed)
        let count = await server.expenses.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(a.store.problemOperations.isEmpty)
    }

    func testTransientFailureBacksOffAndPreservesOrder() async throws {
        let server = InMemoryServer()
        let (a, _, trip) = try await sharedTrip(server: server)
        await server.injectFailure(.server(message: nil))
        try await a.store.saveExpense(try a.equalPayload(trip, title: "One", amount: 100), in: trip)
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Two", amount: 200), in: trip)
        let report = await a.store.sync.drain(force: true)
        XCTAssertEqual(report.delivered + report.deferred >= 1, true)
        let operations = await (try? a.store.local.operations()) ?? []
        XCTAssertTrue(operations.allSatisfy { $0.state == .pending })
        await a.store.sync.drain(force: true)
        let titles = await server.expenses.values.sorted { ($0.createdAt ?? .now) < ($1.createdAt ?? .now) }.map(\.title)
        XCTAssertEqual(Set(titles), ["One", "Two"])
    }

    func testCreateThenDeleteOfflineNeverReachesServer() async throws {
        let server = InMemoryServer()
        let (a, _, trip) = try await sharedTrip(server: server)
        await a.setOnline(false)
        let payload = try a.equalPayload(trip, title: "Oops", amount: 500)
        try await a.store.saveExpense(payload, in: trip)
        let localCached = await a.store.expense(payload.id)
        let local = try XCTUnwrap(localCached?.expense)
        try await a.store.deleteExpense(local)
        let pending = await a.store.unsyncedCount()
        XCTAssertEqual(pending, 0)
        await a.setOnline(true)
        await a.store.sync.drain(force: true)
        let count = await server.expenses.count
        XCTAssertEqual(count, 0)
    }

    func testRemovedMemberLosesLocalDataOnRefresh() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Secret", amount: 900), in: trip)
        await a.store.sync.drain(force: true)
        await b.store.syncNow()
        XCTAssertNotNil(b.store.trip(trip.id))
        let member = try XCTUnwrap(a.store.trip(trip.id)?.members.first { $0.userId == b.userID })
        try await a.store.removeMember(member, from: a.store.trip(trip.id)!)
        await b.store.syncNow()
        XCTAssertNil(b.store.trip(trip.id))
        let leftovers = await b.store.allExpenses(tripID: trip.id)
        XCTAssertTrue(leftovers.isEmpty, "cached data of a revoked trip is removed")
    }

    func testPaginationHandlesManyExpenses() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)
        for index in 0..<700 {
            let payload = try a.equalPayload(trip, title: "Item \(index)", amount: Int64(100 + index))
            _ = try await a.backend.createExpense(tripID: trip.id, payload: JSONCoding.encoder.encode(payload))
        }
        await b.store.syncNow()
        let count = try await b.store.local.expenseCount(tripID: trip.id)
        XCTAssertEqual(count, 700)
        let firstPage = await b.store.expenses(tripID: trip.id, query: ExpenseQuery(limit: 50))
        XCTAssertEqual(firstPage.count, 50)
        let balances = await b.store.balances(for: b.store.trip(trip.id)!)
        XCTAssertEqual(balances.balances.map(\.netMinor).reduce(0, +), 0)
    }

    func testReceiptCapturedOfflineIsUploadedAndAttachedAfterSync() async throws {
        let server = InMemoryServer()
        let (a, _, trip) = try await sharedTrip(server: server)
        await a.setOnline(false)
        let payload = try a.equalPayload(trip, title: "Market", amount: 2400)
        try await a.store.saveExpense(payload, in: trip)
        let prepared = PreparedReceipt(id: UUID(), data: Data([0xFF, 0xD8, 0xFF, 0x00]), mimeType: "image/jpeg", fileExtension: "jpg",
                                       width: 10, height: 10, sha256: String(repeating: "a", count: 64), perceptualHash: nil)
        try await a.store.queueReceiptUpload(prepared, tripID: trip.id, expenseID: payload.id)
        await a.store.uploadPendingReceipts()
        XCTAssertEqual(a.store.pendingReceiptCount, 1, "nothing uploads while offline")

        await a.setOnline(true)
        await a.store.syncNow()
        XCTAssertEqual(a.store.pendingReceiptCount, 0)
        let attached = await server.expenses[payload.id]?.receiptIds
        XCTAssertEqual(attached, [prepared.id])
        let local = await a.store.expense(payload.id)
        XCTAssertEqual(local?.expense.receiptIds, [prepared.id])
    }

    func testPaymentReminderRules() async throws {
        let server = InMemoryServer()
        let (a, b, trip) = try await sharedTrip(server: server)
        try await a.store.saveExpense(try a.equalPayload(trip, title: "Hotel", amount: 10_000), in: trip)
        await a.store.sync.drain(force: true)
        let debtor = try XCTUnwrap(b.store.me(in: trip)?.id ?? a.store.trip(trip.id)?.participant(forUser: b.userID)?.id)
        let first = try await a.backend.requestPaymentReminder(tripID: trip.id, debtor: debtor)
        XCTAssertEqual(first, ReminderResult(queued: true, reason: nil))
        let second = try await a.backend.requestPaymentReminder(tripID: trip.id, debtor: debtor)
        XCTAssertEqual(second.reason, "already_reminded_today")
        do {
            _ = try await b.backend.requestPaymentReminder(tripID: trip.id, debtor: try XCTUnwrap(a.store.me(in: trip)?.id))
            XCTFail("the debtor can't remind the creditor")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict(code: "nothing_owed", currentRevision: nil))
        }
    }
}
