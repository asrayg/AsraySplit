import Foundation
import Observation

struct BalanceSnapshot: Equatable, Sendable {
    var balances: [ParticipantBalance]
    var suggestions: [SuggestedTransfer]
    /// True when the numbers include local changes the server hasn't confirmed yet.
    var isProjected: Bool

    static let empty = BalanceSnapshot(balances: [], suggestions: [], isProjected: false)

    func net(for participant: ParticipantID?) -> Int64 {
        balances.first { $0.participantID == participant }?.netMinor ?? 0
    }
}

/// App-wide, observable view of cached trips and sync status. Features read from here and call its
/// mutation methods; it performs optimistic local writes, queues outbox operations and triggers sync.
@MainActor
@Observable
final class TripStore {
    private(set) var trips: [CachedTrip] = []
    private(set) var operations: [OutboxOperation] = []
    private(set) var isOnline = true
    private(set) var isRefreshing = false
    private(set) var lastSyncError: AppError?
    /// Bumped on every reload so views can re-query paged data.
    private(set) var version = 0
    var currentUserID: UserID?

    let local: LocalStore
    let sync: SyncEngine
    let backend: Backend
    private let network: any NetworkStatusProviding
    private let now: @Sendable () -> Date
    private var realtimeTasks: [TripID: Task<Void, Never>] = [:]
    private var backgroundTasks: [Task<Void, Never>] = []

    init(local: LocalStore, backend: Backend, network: any NetworkStatusProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.local = local
        self.backend = backend
        self.network = network
        self.now = now
        sync = SyncEngine(local: local, trips: backend.trips, ledger: backend.ledger, network: network, now: now)
    }

    // MARK: Lifecycle

    func start() async {
        await sync.observeChanges { [weak self] _ in await self?.reload() }
        isOnline = await network.isOnline
        let networkTask = Task { [weak self, network] in
            for await online in network.onlineChanges() {
                guard let self else { return }
                self.isOnline = online
                if online { await self.syncNow() }
            }
        }
        backgroundTasks.append(networkTask)
        await reload()
        await syncNow()
    }

    func stop() {
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks.removeAll()
        realtimeTasks.values.forEach { $0.cancel() }
        realtimeTasks.removeAll()
    }

    func reload() async {
        trips = (try? await local.trips()) ?? []
        operations = (try? await local.operations()) ?? []
        version &+= 1
        updateRealtimeSubscriptions()
    }

    /// Delivers pending work, then pulls canonical data for every trip.
    func syncNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await sync.drain()
        await uploadPendingReceipts()
        do {
            try await sync.refreshAll()
            lastSyncError = nil
        } catch {
            let appError = error.asAppError
            if appError != .cancelled { lastSyncError = appError }
        }
        await reload()
    }

    func refresh(tripID: TripID) async {
        do { try await sync.refresh(tripID: tripID) } catch { lastSyncError = error.asAppError }
        await reload()
    }

    private func updateRealtimeSubscriptions() {
        let ids = Set(trips.map(\.trip.id))
        for (id, task) in realtimeTasks where !ids.contains(id) { task.cancel(); realtimeTasks[id] = nil }
        for id in ids where realtimeTasks[id] == nil {
            let stream = backend.realtime.changes(tripID: id)
            realtimeTasks[id] = Task { [weak self] in
                for await _ in stream {
                    // Debounce bursts (one RPC touches several tables).
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh(tripID: id)
                }
            }
        }
    }

    // MARK: Queries

    func trip(_ id: TripID?) -> Trip? { trips.first { $0.trip.id == id }?.trip }
    func cachedTrip(_ id: TripID?) -> CachedTrip? { trips.first { $0.trip.id == id } }

    var activeTrips: [Trip] { trips.map(\.trip).filter { !$0.isArchived } }
    var archivedTrips: [Trip] { trips.map(\.trip).filter(\.isArchived) }

    func operations(for tripID: TripID) -> [OutboxOperation] { operations.filter { $0.tripID == tripID } }
    func operation(for entityID: UUID) -> OutboxOperation? { operations.first { $0.entityID == entityID } }
    var problemOperations: [OutboxOperation] { operations.filter { $0.state == .failed || $0.state == .conflict } }

    func me(in trip: Trip) -> Participant? { trip.participant(forUser: currentUserID) }

    func expenses(tripID: TripID, query: ExpenseQuery = ExpenseQuery()) async -> [CachedExpense] {
        (try? await local.expenses(tripID: tripID, query: query)) ?? []
    }

    func allExpenses(tripID: TripID) async -> [CachedExpense] {
        (try? await local.allExpenses(tripID: tripID)) ?? []
    }

    func expense(_ id: ExpenseID) async -> CachedExpense? { try? await local.expense(id) }

    func settlements(tripID: TripID) async -> [CachedSettlement] {
        (try? await local.settlements(tripID: tripID)) ?? []
    }

    func activity(tripID: TripID) async -> [ActivityEvent] {
        (try? await local.activity(tripID: tripID)) ?? []
    }

    /// Server-authoritative balances when fully synced; otherwise a deterministic local projection
    /// (same algorithm and rounding as the server) labelled as unconfirmed.
    func balances(for trip: Trip) async -> BalanceSnapshot {
        let cached = cachedTrip(trip.id)
        let hasPending = !operations(for: trip.id).isEmpty
        let expenses = await allExpenses(tripID: trip.id).map(\.expense.ledgerFact)
        let settlements = await settlements(tripID: trip.id).map(\.settlement.ledgerFact)
        let projected = (try? Ledger.balances(participants: trip.participants.map(\.id), expenses: expenses, settlements: settlements)) ?? []

        if !hasPending, let server = cached?.serverBalances {
            let serverBalances = server.map(\.participantBalance).sorted { $0.participantID.sortKey < $1.participantID.sortKey }
            if serverBalances.map(\.netMinor) != projected.map(\.netMinor) {
                // Cache drifted from the server (e.g. missed realtime event). Trust the server and resync.
                Log.sync.notice("Local projection differs from server balances; scheduling refresh")
                Task { try? await local.setExpenseCursor(trip.id, date: nil, id: nil); await refresh(tripID: trip.id) }
            }
            return BalanceSnapshot(balances: serverBalances, suggestions: cached?.suggestions ?? Ledger.simplify(serverBalances), isProjected: false)
        }
        return BalanceSnapshot(balances: projected, suggestions: Ledger.simplify(projected), isProjected: hasPending)
    }

    // MARK: Trip mutations (online)

    func createTrip(_ draft: TripDraft) async throws -> Trip {
        let trip = try await backend.trips.createTrip(draft)
        try await local.saveTrip(trip)
        await reload()
        return trip
    }

    func updateTrip(_ draft: TripDraft, expectedRevision: Int) async throws {
        try await apply(try await backend.trips.updateTrip(draft, expectedRevision: expectedRevision))
    }

    func setArchived(_ trip: Trip, archived: Bool) async throws {
        try await apply(try await backend.trips.setArchived(trip.id, archived: archived))
    }

    func deleteTrip(_ trip: Trip) async throws {
        try await backend.trips.deleteTrip(trip.id)
        try await local.removeTrip(trip.id)
        await reload()
    }

    func leaveTrip(_ trip: Trip, acknowledgeUnsettled: Bool) async throws {
        try await backend.trips.leaveTrip(trip.id, acknowledgeUnsettled: acknowledgeUnsettled)
        try await local.removeTrip(trip.id)
        await reload()
    }

    func addParticipant(to trip: Trip, name: String) async throws {
        try await apply(try await backend.trips.addParticipant(tripID: trip.id, participantID: UUID(), name: name))
    }

    func renameParticipant(_ participant: Participant, name: String) async throws {
        try await apply(try await backend.trips.renameParticipant(participant.id, name: name))
    }

    func setRole(_ role: TripRole, for member: TripMember, in trip: Trip) async throws {
        try await apply(try await backend.trips.setMemberRole(tripID: trip.id, userID: member.userId, role: role))
    }

    func removeMember(_ member: TripMember, from trip: Trip) async throws {
        try await apply(try await backend.trips.removeMember(tripID: trip.id, userID: member.userId))
    }

    func transferOwnership(of trip: Trip, to member: TripMember) async throws {
        try await apply(try await backend.trips.transferOwnership(tripID: trip.id, to: member.userId))
    }

    func acceptInvite(secret: String, claim: ParticipantID?) async throws -> Trip {
        let trip = try await backend.trips.acceptInvite(secret: secret, claimParticipantID: claim)
        try await local.saveTrip(trip)
        await refresh(tripID: trip.id)
        return trip
    }

    private func apply(_ trip: Trip) async throws {
        try await local.saveTrip(trip)
        await reload()
    }

    // MARK: Ledger mutations (offline-first)

    /// Saves a new or edited expense locally, queues it, and attempts delivery.
    func saveExpense(_ payload: ExpensePayload, in trip: Trip, editing existing: Expense? = nil) async throws {
        try payload.validate(baseCurrency: trip.baseCurrency, participants: Set(trip.participants.map(\.id)))
        if trip.isArchived { throw AppError.conflict(code: "trip_archived", currentRevision: nil) }
        let body = try JSONCoding.encoder.encode(payload)
        let revision = existing.map { $0.revision + 1 } ?? 1
        var optimistic = try payload.optimisticExpense(tripID: trip.id, baseCurrency: trip.baseCurrency, revision: revision,
                                                       createdBy: existing?.createdBy ?? currentUserID, now: now())
        optimistic.createdAt = existing?.createdAt ?? now()
        let operation = OutboxOperation(tripID: trip.id, entityID: payload.id, kind: existing == nil ? .createExpense : .updateExpense,
                                        payload: body, expectedRevision: existing?.revision, createdAt: now(), nextAttemptAt: now())
        try await local.saveExpense(optimistic, state: .pending)
        try await sync.enqueue(operation)
        await afterLocalWrite()
    }

    func deleteExpense(_ expense: Expense) async throws {
        var tombstone = expense
        tombstone.deletedAt = now()
        tombstone.revision += 1
        let operation = OutboxOperation(tripID: expense.tripId, entityID: expense.id, kind: .deleteExpense, payload: nil,
                                        expectedRevision: expense.revision, createdAt: now(), nextAttemptAt: now())
        let resolution = try await sync.enqueue(operation)
        if case .cancel = resolution {
            try await local.deleteExpenseRecord(expense.id) // Never reached the server.
        } else {
            try await local.saveExpense(tombstone, state: .pending)
        }
        await afterLocalWrite()
    }

    func restoreExpense(_ expense: Expense) async throws {
        var restored = expense
        restored.deletedAt = nil
        restored.revision += 1
        let operation = OutboxOperation(tripID: expense.tripId, entityID: expense.id, kind: .restoreExpense, payload: nil,
                                        expectedRevision: expense.revision, createdAt: now(), nextAttemptAt: now())
        let resolution = try await sync.enqueue(operation)
        if case .cancel = resolution { restored.revision -= 2 }
        try await local.saveExpense(restored, state: resolutionState(resolution))
        await afterLocalWrite()
    }

    func recordSettlement(_ payload: SettlementPayload, in trip: Trip) async throws {
        guard payload.amountMinor > 0 else { throw AppError.validation(code: "invalid_amount", message: nil) }
        guard payload.fromParticipantId != payload.toParticipantId else { throw AppError.validation(code: "invalid_parties", message: nil) }
        let body = try JSONCoding.encoder.encode(payload)
        let optimistic = try payload.optimisticSettlement(tripID: trip.id, baseCurrency: trip.baseCurrency, createdBy: currentUserID)
        try await local.saveSettlement(optimistic, state: .pending)
        try await sync.enqueue(OutboxOperation(tripID: trip.id, entityID: payload.id, kind: .recordSettlement, payload: body,
                                               expectedRevision: nil, createdAt: now(), nextAttemptAt: now()))
        await afterLocalWrite()
    }

    func deleteSettlement(_ settlement: Settlement) async throws {
        let resolution = try await sync.enqueue(OutboxOperation(tripID: settlement.tripId, entityID: settlement.id, kind: .deleteSettlement,
                                                                payload: nil, expectedRevision: settlement.revision, createdAt: now(), nextAttemptAt: now()))
        if case .cancel = resolution {
            try await local.deleteSettlementRecord(settlement.id)
        } else {
            var tombstone = settlement
            tombstone.deletedAt = now()
            try await local.saveSettlement(tombstone, state: .pending)
        }
        await afterLocalWrite()
    }

    private func resolutionState(_ resolution: OutboxCoalescer.Resolution) -> SyncState {
        if case .cancel = resolution { return .synced }
        return .pending
    }

    private func afterLocalWrite() async {
        await reload()
        Task { [sync] in await sync.drain() }
    }

    // MARK: Receipts captured offline

    /// Keeps a receipt image to upload and attach once `expenseID` reaches the server.
    func queueReceiptUpload(_ prepared: PreparedReceipt, tripID: TripID, expenseID: ExpenseID) async throws {
        let pending = PendingReceiptUpload(prepared: prepared, tripId: tripID, expenseId: expenseID)
        try FileManager.default.createDirectory(at: PendingReceiptUpload.directory, withIntermediateDirectories: true)
        try prepared.data.write(to: pending.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var queue = (try? await local.value([PendingReceiptUpload].self, forKey: PendingReceiptUpload.storeKey)) ?? []
        queue.removeAll { $0.receiptId == pending.receiptId }
        queue.append(pending)
        try await local.setValue(queue, forKey: PendingReceiptUpload.storeKey)
    }

    private(set) var pendingReceiptCount = 0

    /// Uploads queued offline receipts whose expenses have synced, then attaches them.
    func uploadPendingReceipts() async {
        let queue = (try? await local.value([PendingReceiptUpload].self, forKey: PendingReceiptUpload.storeKey)) ?? []
        guard !queue.isEmpty, await network.isOnline else { pendingReceiptCount = queue.count; return }
        var remaining: [PendingReceiptUpload] = []
        for (index, original) in queue.enumerated() {
            var item = original
            // The expense must reach the server first.
            if ((try? await local.operation(forEntity: item.expenseId)) ?? nil) != nil {
                remaining.append(item)
                continue
            }
            do {
                _ = try await backend.receipts.uploadReceipt(try item.prepared(), tripID: item.tripId)
                let expense = try await backend.receipts.attachReceipt(item.receiptId, to: item.expenseId)
                try await local.saveExpense(expense, state: .synced)
                try? FileManager.default.removeItem(at: item.fileURL)
            } catch {
                let appError = error.asAppError
                item.attempts += 1
                if appError == .offline {
                    remaining.append(item)
                    remaining.append(contentsOf: queue[(index + 1)...])
                    break
                }
                // Permanent failures (trip deleted, file missing) are dropped after a few attempts.
                if appError.isTransient || item.attempts < 5 { remaining.append(item) }
                else { try? FileManager.default.removeItem(at: item.fileURL) }
            }
        }
        pendingReceiptCount = remaining.count
        try? await local.setValue(remaining, forKey: PendingReceiptUpload.storeKey)
    }

    // MARK: Problem resolution

    func retry(_ operation: OutboxOperation) async {
        try? await sync.retry(operation.id)
        await reload()
    }

    func keepMine(_ operation: OutboxOperation) async {
        try? await sync.overwriteWithLocal(operation.id)
        await reload()
    }

    func discard(_ operation: OutboxOperation) async {
        try? await sync.discard(operation.id)
        await reload()
    }

    // MARK: Session

    func unsyncedCount() async -> Int { (try? await local.unsyncedOperationCount()) ?? 0 }

    func wipeLocalData() async {
        stop()
        try? await local.wipe()
        trips = []
        operations = []
        version &+= 1
    }
}
