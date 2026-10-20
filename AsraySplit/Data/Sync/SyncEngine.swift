import Foundation

protocol NetworkStatusProviding: Sendable {
    var isOnline: Bool { get async }
    func onlineChanges() -> AsyncStream<Bool>
}

struct SyncReport: Equatable, Sendable {
    var delivered = 0
    var failed = 0
    var conflicts = 0
    var deferred = 0
    var touchedTrips: Set<TripID> = []
}

/// Delivers queued mutations to the server and pulls canonical data back into the cache.
///
/// Contract (docs/ARCHITECTURE.md "Sync contract"):
/// - The client generates IDs and idempotency keys before the local write; retries resend identical bytes.
/// - Transient failures back off exponentially and stop the drain (preserving order).
/// - Validation/permission failures are kept as `failed` for the user to retry or discard — never dropped.
/// - Revision conflicts are kept as `conflict` until the user chooses theirs or mine.
actor SyncEngine {
    private let local: LocalStore
    private let trips: any TripService
    private let ledger: any LedgerService
    private let network: any NetworkStatusProviding
    private let now: @Sendable () -> Date
    private var drainTask: Task<SyncReport, Never>?
    private var refreshing: Set<TripID> = []
    private var changeHandlers: [UUID: @Sendable (Set<TripID>) async -> Void] = [:]

    /// Re-fetch overlap to tolerate transactions that commit with slightly older `updated_at` values.
    static let cursorOverlap: TimeInterval = 120
    static let pageSize = 500

    init(local: LocalStore, trips: any TripService, ledger: any LedgerService, network: any NetworkStatusProviding,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.local = local
        self.trips = trips
        self.ledger = ledger
        self.network = network
        self.now = now
    }

    @discardableResult
    func observeChanges(_ handler: @escaping @Sendable (Set<TripID>) async -> Void) -> UUID {
        let id = UUID()
        changeHandlers[id] = handler
        return id
    }

    private func announce(_ trips: Set<TripID>) async {
        guard !trips.isEmpty else { return }
        for handler in changeHandlers.values { await handler(trips) }
    }

    // MARK: Outbox

    func enqueue(_ operation: OutboxOperation) async throws -> OutboxCoalescer.Resolution {
        try await local.enqueue(operation)
    }

    /// Sends every due operation in order. Safe to call often: concurrent callers wait for the
    /// in-flight drain and then run their own pass, so no caller returns before its work was attempted.
    @discardableResult
    func drain(force: Bool = false) async -> SyncReport {
        // Chain onto the previous drain so passes run one at a time, in call order.
        let previous = drainTask
        let task = Task { [previous] in
            _ = await previous?.value
            return await self.performDrain(force: force)
        }
        drainTask = task
        return await task.value
    }

    private func performDrain(force: Bool) async -> SyncReport {
        var report = SyncReport()

        guard await network.isOnline else {
            report.deferred = (try? await local.unsyncedOperationCount()) ?? 0
            return report
        }
        let operations = (try? await local.operations()) ?? []
        for operation in operations where operation.state == .pending {
            if !force && operation.nextAttemptAt > now() { report.deferred += 1; continue }
            do {
                try await deliver(operation)
                try await local.removeOperation(operation.id)
                report.delivered += 1
                report.touchedTrips.insert(operation.tripID)
            } catch {
                let appError = error.asAppError
                var updated = operation
                updated.attempts += 1
                updated.errorCode = Self.code(of: appError)
                updated.errorMessage = appError.message
                if appError.isTransient {
                    updated.nextAttemptAt = now().addingTimeInterval(OutboxCoalescer.backoff(attempt: updated.attempts))
                    try? await local.updateOperation(updated)
                    report.deferred += 1
                    Log.sync.info("Deferred \(operation.kind.rawValue, privacy: .public) after attempt \(updated.attempts)")
                    break // Preserve ordering: later operations may depend on this one.
                }
                if appError == .notAuthenticated {
                    try? await local.updateOperation(updated)
                    break
                }
                if case .conflict(let code, let revision) = appError, code == "revision_conflict" {
                    updated.state = .conflict
                    updated.serverRevision = revision
                    report.conflicts += 1
                } else if case .notAuthorized(code: "not_trip_member") = appError {
                    updated.state = .failed
                    report.failed += 1
                } else {
                    updated.state = .failed
                    report.failed += 1
                }
                try? await local.updateOperation(updated)
                try? await markEntity(operation, state: updated.state)
                report.touchedTrips.insert(operation.tripID)
                Log.sync.error("Operation \(operation.kind.rawValue, privacy: .public) failed: \(updated.errorCode ?? "unknown", privacy: .public)")
            }
        }

        for tripID in report.touchedTrips { try? await refresh(tripID: tripID) }
        await announce(report.touchedTrips)
        return report
    }

    private static func code(of error: AppError) -> String {
        switch error {
        case .validation(let code, _), .conflict(let code, _), .notAuthorized(let code): code
        case .offline: "offline"
        case .notFound: "not_found"
        case .rateLimited: "rate_limited"
        case .server: "server_error"
        case .notAuthenticated: "not_authenticated"
        default: "unexpected"
        }
    }

    private func deliver(_ operation: OutboxOperation) async throws {
        switch operation.kind {
        case .createExpense:
            let expense = try await ledger.createExpense(tripID: operation.tripID, payload: operation.payload ?? Data())
            try await local.saveExpense(expense, state: .synced)
        case .updateExpense:
            let expense = try await ledger.updateExpense(id: operation.entityID, expectedRevision: operation.expectedRevision ?? 0, payload: operation.payload ?? Data())
            try await local.saveExpense(expense, state: .synced)
        case .deleteExpense:
            let expense = try await ledger.deleteExpense(id: operation.entityID, expectedRevision: operation.expectedRevision ?? 0)
            try await local.saveExpense(expense, state: .synced)
        case .restoreExpense:
            let expense = try await ledger.restoreExpense(id: operation.entityID, expectedRevision: operation.expectedRevision ?? 0)
            try await local.saveExpense(expense, state: .synced)
        case .recordSettlement:
            let settlement = try await ledger.recordSettlement(tripID: operation.tripID, payload: operation.payload ?? Data())
            try await local.saveSettlement(settlement, state: .synced)
        case .deleteSettlement:
            let settlement = try await ledger.deleteSettlement(id: operation.entityID, expectedRevision: operation.expectedRevision ?? 0)
            try await local.saveSettlement(settlement, state: .synced)
        }
    }

    private func markEntity(_ operation: OutboxOperation, state: SyncState) async throws {
        if operation.kind.isExpense { try await local.setExpenseState(operation.entityID, state) }
        else { try await local.setSettlementState(operation.entityID, state) }
    }

    // MARK: Failure / conflict resolution (user-driven)

    /// Retries a failed operation as-is.
    func retry(_ operationID: UUID) async throws {
        guard var operation = try await local.operations().first(where: { $0.id == operationID }) else { return }
        operation.state = .pending
        operation.nextAttemptAt = now()
        try await local.updateOperation(operation)
        try await markEntity(operation, state: .pending)
        await drain(force: true)
    }

    /// "Keep mine": resend the local version on top of the server's latest revision.
    func overwriteWithLocal(_ operationID: UUID) async throws {
        guard var operation = try await local.operations().first(where: { $0.id == operationID }), let revision = operation.serverRevision else { return }
        operation.expectedRevision = revision
        operation.state = .pending
        operation.nextAttemptAt = now()
        try await local.updateOperation(operation)
        try await markEntity(operation, state: .pending)
        await drain(force: true)
    }

    /// "Keep theirs" / discard: drop the local change and restore the canonical server version.
    func discard(_ operationID: UUID) async throws {
        guard let operation = try await local.operations().first(where: { $0.id == operationID }) else { return }
        try await local.removeOperation(operationID)
        if operation.kind == .createExpense { try await local.deleteExpenseRecord(operation.entityID) }
        if operation.kind == .recordSettlement { try await local.deleteSettlementRecord(operation.entityID) }
        // Force a full expense refetch so the canonical version replaces the discarded local edit.
        try await local.setExpenseCursor(operation.tripID, date: nil, id: nil)
        try await refresh(tripID: operation.tripID)
        await announce([operation.tripID])
    }

    // MARK: Canonical refresh

    func refreshAll() async throws {
        let remote = try await trips.fetchTrips()
        try await local.saveTrips(remote, replacingAll: true)
        for trip in remote { try? await refresh(tripID: trip.id, includeTrip: false) }
        await announce(Set(remote.map(\.id)))
    }

    func refresh(tripID: TripID, includeTrip: Bool = true) async throws {
        guard !refreshing.contains(tripID) else { return }
        refreshing.insert(tripID)
        defer { refreshing.remove(tripID) }
        do {
            if includeTrip { try await local.saveTrip(try await trips.fetchTrip(tripID)) }

            var (cursor, cursorID) = try await local.expenseCursor(tripID)
            if let current = cursor { cursor = current.addingTimeInterval(-Self.cursorOverlap); cursorID = nil }
            var latest: (Date, UUID)?
            while true {
                let page = try await ledger.fetchExpenses(tripID: tripID, updatedAfter: cursor, afterID: cursorID, limit: Self.pageSize)
                try await local.applyCanonicalExpenses(page.expenses)
                if let last = page.expenses.last, let stamp = last.updatedAt {
                    latest = (stamp, last.id)
                    cursor = stamp
                    cursorID = last.id
                }
                if !page.hasMore { break }
            }
            if let latest { try await local.setExpenseCursor(tripID, date: latest.0, id: latest.1) }

            try await local.applyCanonicalSettlements(try await ledger.fetchSettlements(tripID: tripID), tripID: tripID)
            async let balances = ledger.fetchBalances(tripID: tripID)
            async let suggestions = ledger.fetchSuggestedSettlements(tripID: tripID)
            async let summary = ledger.fetchSummary(tripID: tripID)
            async let activity = ledger.fetchActivity(tripID: tripID, beforeID: nil, limit: 50)
            try await local.saveDerived(tripID: tripID, balances: try await balances, suggestions: try await suggestions,
                                        summary: try await summary, refreshedAt: now())
            try await local.saveActivity(try await activity)
        } catch let error as AppError where error == .notFound || error == .notAuthorized(code: "not_trip_member") {
            // Access revoked or trip deleted: remove local copies immediately.
            try await local.removeTrip(tripID)
            await announce([tripID])
            throw error
        }
    }
}
