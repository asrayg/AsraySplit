import Foundation
import SwiftData

// MARK: - Persistent records (normalized per entity; canonical JSON payloads)

@Model final class TripRecord {
    var scope: String = "default"
    var id: UUID
    var json: Data
    var createdAt: Date
    var expenseCursor: Date?
    var expenseCursorID: UUID?
    var balancesJSON: Data?
    var suggestionsJSON: Data?
    var summaryJSON: Data?
    var lastRefreshedAt: Date?

    init(id: UUID, json: Data, createdAt: Date) {
        self.id = id
        self.json = json
        self.createdAt = createdAt
    }
}

@Model final class ExpenseRecord {
    var scope: String = "default"
    var id: UUID
    var tripID: UUID
    var spentAt: Date
    var isTombstone: Bool
    var hasReceipt: Bool
    var json: Data
    var syncState: String

    init(id: UUID, tripID: UUID, spentAt: Date, isTombstone: Bool, hasReceipt: Bool, json: Data, syncState: String) {
        self.id = id
        self.tripID = tripID
        self.spentAt = spentAt
        self.isTombstone = isTombstone
        self.hasReceipt = hasReceipt
        self.json = json
        self.syncState = syncState
    }
}

@Model final class SettlementRecord {
    var scope: String = "default"
    var id: UUID
    var tripID: UUID
    var settledAt: Date
    var isTombstone: Bool
    var json: Data
    var syncState: String

    init(id: UUID, tripID: UUID, settledAt: Date, isTombstone: Bool, json: Data, syncState: String) {
        self.id = id
        self.tripID = tripID
        self.settledAt = settledAt
        self.isTombstone = isTombstone
        self.json = json
        self.syncState = syncState
    }
}

@Model final class ActivityRecord {
    var scope: String = "default"
    var id: Int64
    var tripID: UUID
    var json: Data

    init(id: Int64, tripID: UUID, json: Data) {
        self.id = id
        self.tripID = tripID
        self.json = json
    }
}

@Model final class OutboxRecord {
    var scope: String = "default"
    var id: UUID
    var tripID: UUID
    var entityID: UUID
    var kind: String
    var payload: Data?
    var expectedRevision: Int?
    var createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
    var state: String
    var errorCode: String?
    var errorMessage: String?
    var serverRevision: Int?

    init(_ op: OutboxOperation) {
        id = op.id
        tripID = op.tripID
        entityID = op.entityID
        kind = op.kind.rawValue
        payload = op.payload
        expectedRevision = op.expectedRevision
        createdAt = op.createdAt
        attempts = op.attempts
        nextAttemptAt = op.nextAttemptAt
        state = op.state.rawValue
        errorCode = op.errorCode
        errorMessage = op.errorMessage
        serverRevision = op.serverRevision
    }

    func apply(_ op: OutboxOperation) {
        kind = op.kind.rawValue
        payload = op.payload
        expectedRevision = op.expectedRevision
        attempts = op.attempts
        nextAttemptAt = op.nextAttemptAt
        state = op.state.rawValue
        errorCode = op.errorCode
        errorMessage = op.errorMessage
        serverRevision = op.serverRevision
    }

    var operation: OutboxOperation? {
        guard let kind = OutboxKind(rawValue: kind) else { return nil }
        return OutboxOperation(id: id, tripID: tripID, entityID: entityID, kind: kind, payload: payload, expectedRevision: expectedRevision,
                               createdAt: createdAt, attempts: attempts, nextAttemptAt: nextAttemptAt, state: SyncState(rawValue: state) ?? .pending,
                               errorCode: errorCode, errorMessage: errorMessage, serverRevision: serverRevision)
    }
}

@Model final class ValueRecord {
    var scope: String = "default"
    var key: String
    var data: Data

    init(key: String, data: Data) {
        self.key = key
        self.data = data
    }
}

// MARK: - Value types handed to the rest of the app

struct CachedTrip: Sendable, Equatable {
    var trip: Trip
    var serverBalances: [ServerBalance]?
    var suggestions: [SuggestedTransfer]?
    var summary: TripSummary?
    var lastRefreshedAt: Date?
}

struct CachedExpense: Sendable, Equatable, Identifiable {
    var expense: Expense
    var syncState: SyncState
    var id: ExpenseID { expense.id }
}

struct CachedSettlement: Sendable, Equatable, Identifiable {
    var settlement: Settlement
    var syncState: SyncState
    var id: UUID { settlement.id }
}

struct ExpenseQuery: Sendable, Equatable {
    var includeDeleted = false
    var limit = 50
    var offset = 0
}

// MARK: - Store

/// The on-device cache. Supabase stays the source of truth: canonical server records overwrite local
/// copies unless a local mutation for that entity is still waiting in the outbox.
actor LocalStore: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    /// Partitions one container into independent caches (tests and previews simulate several devices).
    private let storeScope: String

    init(modelContainer: ModelContainer, scope: String = "default") {
        self.modelContainer = modelContainer
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        storeScope = scope
    }

    /// One ephemeral container per process: SwiftData on iOS 17 breaks earlier containers when another
    /// container with the same schema is created, so ephemeral caches share this one and use scopes.
    static let ephemeralContainer: ModelContainer = try! makeContainer(inMemory: true)

    static func ephemeral() -> LocalStore { LocalStore(modelContainer: ephemeralContainer, scope: UUID().uuidString) }

    private func insert<T: PersistentModel>(_ record: T) {
        if let record = record as? TripRecord { record.scope = storeScope }
        if let record = record as? ExpenseRecord { record.scope = storeScope }
        if let record = record as? SettlementRecord { record.scope = storeScope }
        if let record = record as? ActivityRecord { record.scope = storeScope }
        if let record = record as? OutboxRecord { record.scope = storeScope }
        if let record = record as? ValueRecord { record.scope = storeScope }
        modelContext.insert(record)
    }
    /// One configuration name for every container: SwiftData maps entities to configurations by name
    /// process-wide, so differing names break all but the most recently created container.
    static let configurationName = "AsraySplitCache"

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([TripRecord.self, ExpenseRecord.self, SettlementRecord.self, ActivityRecord.self, OutboxRecord.self, ValueRecord.self])
        if inMemory {
            // SwiftData on iOS 17 mis-routes inserts when several *in-memory* containers share a schema in
            // one process, so ephemeral stores (tests, previews, UI tests) use unique temporary files instead.
            let url = FileManager.default.temporaryDirectory.appending(path: "ephemeral-\(UUID().uuidString).store")
            return try ModelContainer(for: schema, configurations: ModelConfiguration(configurationName, schema: schema, url: url))
        }
        let directory = URL.applicationSupportDirectory.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable only after first unlock; excluded from backups (it can be rebuilt from the server).
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(configurationName, schema: schema, url: directory.appending(path: "asray-split.store")))
    }

    private var encoder: JSONEncoder { JSONCoding.encoder }
    private var decoder: JSONDecoder { JSONCoding.decoder }

    // MARK: Trips

    func trips() throws -> [CachedTrip] {
        let scope = storeScope
        let records = try modelContext.fetch(FetchDescriptor<TripRecord>(predicate: #Predicate { $0.scope == scope }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        return records.compactMap(cached)
    }

    func trip(_ id: TripID) throws -> CachedTrip? {
        try tripRecord(id).flatMap(cached)
    }

    private func cached(_ record: TripRecord) -> CachedTrip? {
        guard let trip = try? decoder.decode(Trip.self, from: record.json) else { return nil }
        return CachedTrip(trip: trip,
                          serverBalances: record.balancesJSON.flatMap { try? decoder.decode([ServerBalance].self, from: $0) },
                          suggestions: record.suggestionsJSON.flatMap { try? decoder.decode([SuggestedTransfer].self, from: $0) },
                          summary: record.summaryJSON.flatMap { try? decoder.decode(TripSummary.self, from: $0) },
                          lastRefreshedAt: record.lastRefreshedAt)
    }

    private func tripRecord(_ id: TripID) throws -> TripRecord? {
        let scope = storeScope
        var descriptor = FetchDescriptor<TripRecord>(predicate: #Predicate { $0.scope == scope && $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func saveTrips(_ trips: [Trip], replacingAll: Bool) throws {
        let scope = storeScope
        let keep = Set(trips.map(\.id))
        if replacingAll {
            for record in try modelContext.fetch(FetchDescriptor<TripRecord>(predicate: #Predicate { $0.scope == scope })) where !keep.contains(record.id) {
                try removeTripData(record.id)
            }
        }
        for trip in trips { try upsert(trip) }
        try modelContext.save()
    }

    func saveTrip(_ trip: Trip) throws {
        try upsert(trip)
        try modelContext.save()
    }

    private func upsert(_ trip: Trip) throws {
        let json = try encoder.encode(trip)
        if let record = try tripRecord(trip.id) {
            record.json = json
        } else {
            insert(TripRecord(id: trip.id, json: json, createdAt: trip.createdAt))
        }
    }

    func saveDerived(tripID: TripID, balances: [ServerBalance]?, suggestions: [SuggestedTransfer]?, summary: TripSummary?, refreshedAt: Date) throws {
        guard let record = try tripRecord(tripID) else { return }
        if let balances { record.balancesJSON = try encoder.encode(balances) }
        if let suggestions { record.suggestionsJSON = try encoder.encode(suggestions) }
        if let summary { record.summaryJSON = try encoder.encode(summary) }
        record.lastRefreshedAt = refreshedAt
        try modelContext.save()
    }

    func expenseCursor(_ tripID: TripID) throws -> (Date?, UUID?) {
        let record = try tripRecord(tripID)
        return (record?.expenseCursor, record?.expenseCursorID)
    }

    func setExpenseCursor(_ tripID: TripID, date: Date?, id: UUID?) throws {
        guard let record = try tripRecord(tripID) else { return }
        record.expenseCursor = date
        record.expenseCursorID = id
        try modelContext.save()
    }

    /// Removes a trip and everything cached for it (used when access is revoked or the trip is deleted).
    func removeTrip(_ id: TripID) throws {
        try removeTripData(id)
        try modelContext.save()
    }

    private func removeTripData(_ id: TripID) throws {
        let scope = storeScope
        try modelContext.delete(model: ExpenseRecord.self, where: #Predicate { $0.scope == scope && $0.tripID == id })
        try modelContext.delete(model: SettlementRecord.self, where: #Predicate { $0.scope == scope && $0.tripID == id })
        try modelContext.delete(model: ActivityRecord.self, where: #Predicate { $0.scope == scope && $0.tripID == id })
        try modelContext.delete(model: OutboxRecord.self, where: #Predicate { $0.scope == scope && $0.tripID == id })
        try modelContext.delete(model: TripRecord.self, where: #Predicate { $0.scope == scope && $0.id == id })
    }

    // MARK: Expenses

    func expenses(tripID: TripID, query: ExpenseQuery = ExpenseQuery()) throws -> [CachedExpense] {
        let scope = storeScope
        var descriptor: FetchDescriptor<ExpenseRecord>
        if query.includeDeleted {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID }, sortBy: [SortDescriptor(\.spentAt, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID && !$0.isTombstone }, sortBy: [SortDescriptor(\.spentAt, order: .reverse)])
        }
        descriptor.fetchLimit = query.limit
        descriptor.fetchOffset = query.offset
        return try modelContext.fetch(descriptor).compactMap(cachedExpense)
    }

    /// Every live expense of a trip (for balance projection and export).
    func allExpenses(tripID: TripID) throws -> [CachedExpense] {
        let scope = storeScope
        let descriptor = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID && !$0.isTombstone }, sortBy: [SortDescriptor(\.spentAt)])
        return try modelContext.fetch(descriptor).compactMap(cachedExpense)
    }

    func expenseCount(tripID: TripID) throws -> Int {
        let scope = storeScope
        return try modelContext.fetchCount(FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID && !$0.isTombstone }))
    }

    func expense(_ id: ExpenseID) throws -> CachedExpense? {
        try expenseRecord(id).flatMap(cachedExpense)
    }

    private func cachedExpense(_ record: ExpenseRecord) -> CachedExpense? {
        guard let expense = try? decoder.decode(Expense.self, from: record.json) else { return nil }
        return CachedExpense(expense: expense, syncState: SyncState(rawValue: record.syncState) ?? .synced)
    }

    private func expenseRecord(_ id: ExpenseID) throws -> ExpenseRecord? {
        let scope = storeScope
        var descriptor = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.scope == scope && $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func saveExpense(_ expense: Expense, state: SyncState) throws {
        try upsert(expense, state: state)
        try modelContext.save()
    }

    private func upsert(_ expense: Expense, state: SyncState) throws {
        let json = try encoder.encode(expense)
        if let record = try expenseRecord(expense.id) {
            record.json = json
            record.spentAt = expense.spentAt
            record.isTombstone = expense.isDeleted
            record.hasReceipt = !expense.receiptIds.isEmpty
            record.syncState = state.rawValue
        } else {
            insert(ExpenseRecord(id: expense.id, tripID: expense.tripId, spentAt: expense.spentAt, isTombstone: expense.isDeleted,
                                              hasReceipt: !expense.receiptIds.isEmpty, json: json, syncState: state.rawValue))
        }
    }

    func deleteExpenseRecord(_ id: ExpenseID) throws {
        let scope = storeScope
        try modelContext.delete(model: ExpenseRecord.self, where: #Predicate { $0.scope == scope && $0.id == id })
        try modelContext.save()
    }

    func setExpenseState(_ id: ExpenseID, _ state: SyncState) throws {
        try expenseRecord(id)?.syncState = state.rawValue
        try modelContext.save()
    }

    /// Applies canonical server rows, skipping entities with local mutations still queued.
    func applyCanonicalExpenses(_ expenses: [Expense]) throws {
        let scope = storeScope
        let pending = Set(try modelContext.fetch(FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope })).map(\.entityID))
        for expense in expenses where !pending.contains(expense.id) {
            try upsert(expense, state: .synced)
        }
        try modelContext.save()
    }

    // MARK: Settlements

    func settlements(tripID: TripID, includeDeleted: Bool = false) throws -> [CachedSettlement] {
        let scope = storeScope
        let descriptor = FetchDescriptor<SettlementRecord>(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID }, sortBy: [SortDescriptor(\.settledAt, order: .reverse)])
        return try modelContext.fetch(descriptor).filter { includeDeleted || !$0.isTombstone }.compactMap { record in
            guard let settlement = try? decoder.decode(Settlement.self, from: record.json) else { return nil }
            return CachedSettlement(settlement: settlement, syncState: SyncState(rawValue: record.syncState) ?? .synced)
        }
    }

    private func settlementRecord(_ id: UUID) throws -> SettlementRecord? {
        let scope = storeScope
        var descriptor = FetchDescriptor<SettlementRecord>(predicate: #Predicate { $0.scope == scope && $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func saveSettlement(_ settlement: Settlement, state: SyncState) throws {
        try upsert(settlement, state: state)
        try modelContext.save()
    }

    private func upsert(_ settlement: Settlement, state: SyncState) throws {
        let json = try encoder.encode(settlement)
        if let record = try settlementRecord(settlement.id) {
            record.json = json
            record.settledAt = settlement.settledAt
            record.isTombstone = settlement.isDeleted
            record.syncState = state.rawValue
        } else {
            insert(SettlementRecord(id: settlement.id, tripID: settlement.tripId, settledAt: settlement.settledAt,
                                                 isTombstone: settlement.isDeleted, json: json, syncState: state.rawValue))
        }
    }

    func deleteSettlementRecord(_ id: UUID) throws {
        let scope = storeScope
        try modelContext.delete(model: SettlementRecord.self, where: #Predicate { $0.scope == scope && $0.id == id })
        try modelContext.save()
    }

    func setSettlementState(_ id: UUID, _ state: SyncState) throws {
        try settlementRecord(id)?.syncState = state.rawValue
        try modelContext.save()
    }

    func applyCanonicalSettlements(_ settlements: [Settlement], tripID: TripID) throws {
        let scope = storeScope
        let pending = Set(try modelContext.fetch(FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope })).map(\.entityID))
        let serverIDs = Set(settlements.map(\.id))
        // Settlements are fetched in full, so local synced rows missing from the server were hard-deleted.
        for record in try modelContext.fetch(FetchDescriptor<SettlementRecord>(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID }))
        where !serverIDs.contains(record.id) && !pending.contains(record.id) && record.syncState == SyncState.synced.rawValue {
            modelContext.delete(record)
        }
        for settlement in settlements where !pending.contains(settlement.id) { try upsert(settlement, state: .synced) }
        try modelContext.save()
    }

    // MARK: Activity

    func activity(tripID: TripID, limit: Int = 100) throws -> [ActivityEvent] {
        let scope = storeScope
        var descriptor = FetchDescriptor<ActivityRecord>(predicate: #Predicate { $0.scope == scope && $0.tripID == tripID }, sortBy: [SortDescriptor(\.id, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { try? decoder.decode(ActivityEvent.self, from: $0.json) }
    }

    func saveActivity(_ events: [ActivityEvent]) throws {
        let scope = storeScope
        for event in events {
            let id = event.id
            var descriptor = FetchDescriptor<ActivityRecord>(predicate: #Predicate { $0.scope == scope && $0.id == id })
            descriptor.fetchLimit = 1
            let json = try encoder.encode(event)
            if let record = try modelContext.fetch(descriptor).first { record.json = json }
            else { insert(ActivityRecord(id: event.id, tripID: event.tripId, json: json)) }
        }
        try modelContext.save()
    }

    // MARK: Outbox

    func operations() throws -> [OutboxOperation] {
        let scope = storeScope
        return try modelContext.fetch(FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope }, sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.operation)
    }

    func operation(forEntity id: UUID) throws -> OutboxOperation? {
        let scope = storeScope
        var descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope && $0.entityID == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.operation
    }

    /// Records a mutation for later delivery, merged with any pending one for the same entity.
    /// Returns the resolution so the caller can update the optimistic local record accordingly.
    @discardableResult
    func enqueue(_ operation: OutboxOperation) throws -> OutboxCoalescer.Resolution {
        let scope = storeScope
        let entity = operation.entityID
        var descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope && $0.entityID == entity })
        descriptor.fetchLimit = 1
        let existingRecord = try modelContext.fetch(descriptor).first
        let resolution = OutboxCoalescer.merge(existing: existingRecord?.operation, new: operation)
        switch resolution {
        case .append(let op): insert(OutboxRecord(op))
        case .replace(_, let op): existingRecord?.apply(op)
        case .cancel: if let existingRecord { modelContext.delete(existingRecord) }
        }
        try modelContext.save()
        return resolution
    }

    func updateOperation(_ operation: OutboxOperation) throws {
        let scope = storeScope
        let id = operation.id
        var descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope && $0.id == id })
        descriptor.fetchLimit = 1
        try modelContext.fetch(descriptor).first?.apply(operation)
        try modelContext.save()
    }

    func removeOperation(_ id: UUID) throws {
        let scope = storeScope
        try modelContext.delete(model: OutboxRecord.self, where: #Predicate { $0.scope == scope && $0.id == id })
        try modelContext.save()
    }

    // MARK: Key-value

    func value<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        let scope = storeScope
        var descriptor = FetchDescriptor<ValueRecord>(predicate: #Predicate { $0.scope == scope && $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap { try? decoder.decode(T.self, from: $0.data) }
    }

    func setValue<T: Encodable>(_ value: T?, forKey key: String) throws {
        let scope = storeScope
        var descriptor = FetchDescriptor<ValueRecord>(predicate: #Predicate { $0.scope == scope && $0.key == key })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        if let value {
            let data = try encoder.encode(value)
            if let existing { existing.data = data } else { insert(ValueRecord(key: key, data: data)) }
        } else if let existing {
            modelContext.delete(existing)
        }
        try modelContext.save()
    }

    // MARK: Lifecycle

    func unsyncedOperationCount() throws -> Int {
        let scope = storeScope
        return try modelContext.fetchCount(FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.scope == scope }))
    }

    /// Removes all cached trip data and pending work (sign-out / account deletion).
    func wipe() throws {
        let scope = storeScope
        try modelContext.delete(model: ExpenseRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: SettlementRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: ActivityRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: OutboxRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: TripRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: ValueRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.save()
    }
}
