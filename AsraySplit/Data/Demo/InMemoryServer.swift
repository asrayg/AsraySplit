import Foundation

/// An in-process stand-in for the Supabase project used by demo mode, SwiftUI previews and tests.
/// It enforces the same invariants as the SQL RPCs (membership, exact totals, idempotency keys,
/// optimistic revisions, soft deletes) so client logic is exercised against realistic behavior.
/// Demo data lives only here and can never reach a real project.
actor InMemoryServer {
    struct InviteRecord { var invite: TripInvite; var useCount: Int; var revoked: Bool; var participantID: ParticipantID? }

    private(set) var profiles: [UserID: Profile] = [:]
    private(set) var trips: [TripID: Trip] = [:]
    private(set) var expenses: [ExpenseID: Expense] = [:]
    private var expensePayloads: [ExpenseID: Data] = [:]
    private(set) var settlements: [UUID: Settlement] = [:]
    private var settlementPayloads: [UUID: Data] = [:]
    private(set) var activity: [ActivityEvent] = []
    private var invites: [String: InviteRecord] = [:]
    private(set) var receipts: [UUID: Receipt] = [:]
    private var receiptData: [UUID: Data] = [:]
    private var preferences: [UserID: NotificationPreferences] = [:]
    private var devices: [String: UserID] = [:]
    private var nextActivityID: Int64 = 1
    private var clock: () -> Date
    private var listeners: [TripID: [UUID: AsyncStream<Void>.Continuation]] = [:]

    /// Test hooks.
    var isReachable = true
    var injectedFailure: AppError?
    private(set) var requestCount = 0

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    func setReachable(_ reachable: Bool) { isReachable = reachable }
    func injectFailure(_ error: AppError?) { injectedFailure = error }

    private func gate() throws {
        requestCount += 1
        guard isReachable else { throw AppError.offline }
        if let failure = injectedFailure { injectedFailure = nil; throw failure }
    }

    // MARK: Users

    func ensureProfile(_ userID: UserID, name: String, currency: CurrencyCode = .usd) {
        if profiles[userID] == nil {
            profiles[userID] = Profile(id: userID, displayName: name, avatarEmoji: nil, defaultCurrency: currency, onboardedAt: nil)
        }
    }

    func profile(_ userID: UserID) throws -> Profile {
        try gate()
        guard let profile = profiles[userID] else { throw AppError.notFound }
        return profile
    }

    func updateProfile(_ userID: UserID, name: String, emoji: String?, currency: CurrencyCode) throws -> Profile {
        try gate()
        guard var profile = profiles[userID] else { throw AppError.notFound }
        profile.displayName = name
        profile.avatarEmoji = emoji
        profile.defaultCurrency = currency
        profile.onboardedAt = profile.onboardedAt ?? clock()
        profiles[userID] = profile
        return profile
    }

    // MARK: Membership helpers

    private func role(of user: UserID, in tripID: TripID) -> TripRole? {
        trips[tripID]?.members.first { $0.userId == user && $0.status == .active }?.role
    }

    @discardableResult
    private func require(_ user: UserID, _ tripID: TripID, _ minimum: TripRole = .member, allowArchived: Bool = true) throws -> TripRole {
        guard let role = role(of: user, in: tripID) else { throw AppError.notAuthorized(code: "not_trip_member") }
        if role < minimum { throw AppError.notAuthorized(code: minimum == .owner ? "owner_required" : "admin_required") }
        if !allowArchived, trips[tripID]?.archivedAt != nil { throw AppError.conflict(code: "trip_archived", currentRevision: nil) }
        return role
    }

    private func view(_ trip: Trip, for user: UserID) -> Trip {
        var copy = trip
        copy.myRole = role(of: user, in: trip.id)
        return copy
    }

    private func log(_ tripID: TripID, _ kind: String, actor: UserID?, entity: UUID?, data: [String: JSONValue] = [:]) {
        activity.append(ActivityEvent(id: nextActivityID, tripId: tripID, actorId: actor, kind: kind, entityId: entity, data: data, createdAt: clock()))
        nextActivityID += 1
        notify(tripID)
    }

    private func notify(_ tripID: TripID) {
        listeners[tripID]?.values.forEach { $0.yield(()) }
    }

    func subscribe(_ tripID: TripID) -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[tripID, default: [:]][id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(tripID, id) } }
        return stream
    }

    private func unsubscribe(_ tripID: TripID, _ id: UUID) { listeners[tripID]?[id] = nil }

    // MARK: Trips

    func trips(for user: UserID) throws -> [Trip] {
        try gate()
        return trips.values.filter { role(of: user, in: $0.id) != nil }.sorted { $0.createdAt > $1.createdAt }.map { view($0, for: user) }
    }

    func trip(_ id: TripID, for user: UserID) throws -> Trip {
        try gate()
        try require(user, id)
        return view(trips[id]!, for: user)
    }

    func createTrip(_ draft: TripDraft, by user: UserID) throws -> Trip {
        try gate()
        if let existing = trips[draft.id] {
            guard existing.ownerId == user else { throw AppError.conflict(code: "id_conflict", currentRevision: nil) }
            return view(existing, for: user)
        }
        guard draft.isValid else { throw AppError.validation(code: "invalid_trip", message: nil) }
        let now = clock()
        let me = Participant(id: UUID(), tripId: draft.id, displayName: profiles[user]?.displayName ?? "Me", userId: user)
        let guests = draft.guestNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { Participant(id: UUID(), tripId: draft.id, displayName: $0) }
        let trip = Trip(id: draft.id, ownerId: user, name: draft.trimmedName, emoji: draft.emoji, colorHex: draft.colorHex,
                        startDate: draft.startDate, endDate: draft.endDate, timezone: draft.timezone, baseCurrency: draft.baseCurrency,
                        budgetMinor: draft.budgetMinor, revision: 1, archivedAt: nil, createdAt: now, updatedAt: now, myRole: .owner,
                        participants: [me] + guests,
                        members: [TripMember(tripId: draft.id, userId: user, participantId: me.id, role: .owner, status: .active, joinedAt: now)])
        trips[trip.id] = trip
        log(trip.id, "trip_created", actor: user, entity: trip.id, data: ["name": .string(trip.name)])
        return view(trip, for: user)
    }

    func updateTrip(_ draft: TripDraft, expectedRevision: Int, by user: UserID) throws -> Trip {
        try gate()
        try require(user, draft.id, .admin)
        guard var trip = trips[draft.id] else { throw AppError.notFound }
        guard trip.revision == expectedRevision else { throw AppError.conflict(code: "revision_conflict", currentRevision: trip.revision) }
        if draft.baseCurrency != trip.baseCurrency, expenses.values.contains(where: { $0.tripId == trip.id }) {
            throw AppError.conflict(code: "base_currency_locked", currentRevision: nil)
        }
        trip.name = draft.trimmedName; trip.emoji = draft.emoji; trip.colorHex = draft.colorHex
        trip.startDate = draft.startDate; trip.endDate = draft.endDate; trip.timezone = draft.timezone
        trip.baseCurrency = draft.baseCurrency; trip.budgetMinor = draft.budgetMinor
        trip.revision += 1; trip.updatedAt = clock()
        trips[trip.id] = trip
        log(trip.id, "trip_updated", actor: user, entity: trip.id)
        return view(trip, for: user)
    }

    func setArchived(_ tripID: TripID, _ archived: Bool, by user: UserID) throws -> Trip {
        try gate()
        try require(user, tripID, .admin)
        trips[tripID]!.archivedAt = archived ? (trips[tripID]!.archivedAt ?? clock()) : nil
        trips[tripID]!.revision += 1
        log(tripID, archived ? "trip_archived" : "trip_unarchived", actor: user, entity: tripID)
        return view(trips[tripID]!, for: user)
    }

    func deleteTrip(_ tripID: TripID, by user: UserID) throws {
        try gate()
        try require(user, tripID, .owner)
        trips[tripID] = nil
        expenses = expenses.filter { $0.value.tripId != tripID }
        settlements = settlements.filter { $0.value.tripId != tripID }
        activity.removeAll { $0.tripId == tripID }
        receipts = receipts.filter { $0.value.tripId != tripID }
        notify(tripID)
    }

    func addParticipant(_ tripID: TripID, id: ParticipantID, name: String, by user: UserID) throws -> Trip {
        try gate()
        try require(user, tripID, allowArchived: false)
        if trips[tripID]!.participants.contains(where: { $0.id == id }) { return view(trips[tripID]!, for: user) }
        trips[tripID]!.participants.append(Participant(id: id, tripId: tripID, displayName: name.trimmingCharacters(in: .whitespaces)))
        log(tripID, "participant_added", actor: user, entity: id, data: ["name": .string(name)])
        return view(trips[tripID]!, for: user)
    }

    func renameParticipant(_ id: ParticipantID, name: String, by user: UserID) throws -> Trip {
        try gate()
        guard let trip = trips.values.first(where: { $0.participants.contains { $0.id == id } }) else { throw AppError.notFound }
        let participant = trip.participant(id)!
        try require(user, trip.id, participant.userId == nil || participant.userId == user ? .member : .admin, allowArchived: false)
        let index = trip.participants.firstIndex { $0.id == id }!
        trips[trip.id]!.participants[index].displayName = name
        log(trip.id, "participant_renamed", actor: user, entity: id)
        return view(trips[trip.id]!, for: user)
    }

    // MARK: Invites

    func createInvite(_ tripID: TripID, role: TripRole, hours: Int, maxUses: Int, participantID: ParticipantID?, by user: UserID) throws -> TripInvite {
        try gate()
        try require(user, tripID, .admin, allowArchived: false)
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<8).map { _ in alphabet.randomElement()! })
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.prefix(8).lowercased()
        let invite = TripInvite(id: UUID(), tripId: tripID, token: token, code: code, role: role, expiresAt: clock().addingTimeInterval(Double(hours) * 3600), maxUses: maxUses)
        let record = InviteRecord(invite: invite, useCount: 0, revoked: false, participantID: participantID)
        invites[token] = record
        invites[code] = record
        return invite
    }

    func revokeInvite(_ id: UUID, by user: UserID) throws {
        try gate()
        guard let record = invites.values.first(where: { $0.invite.id == id }) else { throw AppError.notFound }
        try require(user, record.invite.tripId, .admin)
        for key in invites.keys where invites[key]?.invite.id == id { invites[key]?.revoked = true }
    }

    private func lookup(_ secret: String) throws -> InviteRecord {
        let normalized = secret.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let key = normalized.count == 8 ? normalized.uppercased() : secret.trimmingCharacters(in: .whitespaces)
        guard let record = invites[key] else { throw AppError.invite(.invalid) }
        if record.revoked { throw AppError.invite(.revoked) }
        if record.invite.expiresAt <= clock() { throw AppError.invite(.expired) }
        return record
    }

    func previewInvite(_ secret: String, for user: UserID) throws -> InvitePreview {
        try gate()
        let record = try lookup(secret)
        guard let trip = trips[record.invite.tripId] else { throw AppError.invite(.invalid) }
        let claimable = trip.participants.filter { $0.userId == nil && $0.archivedAt == nil && (record.participantID == nil || $0.id == record.participantID) }
        return InvitePreview(tripId: trip.id, name: trip.name, emoji: trip.emoji, startDate: trip.startDate, endDate: trip.endDate,
                             baseCurrency: trip.baseCurrency, role: record.invite.role, expiresAt: record.invite.expiresAt,
                             invitedBy: nil, memberCount: trip.activeMembers.count, alreadyMember: role(of: user, in: trip.id) != nil,
                             exhausted: record.useCount >= record.invite.maxUses, reservedParticipantId: record.participantID,
                             claimableParticipants: claimable.map { .init(id: $0.id, displayName: $0.displayName) })
    }

    func acceptInvite(_ secret: String, claim: ParticipantID?, by user: UserID) throws -> Trip {
        try gate()
        let record = try lookup(secret)
        let tripID = record.invite.tripId
        guard var trip = trips[tripID] else { throw AppError.invite(.invalid) }
        if role(of: user, in: tripID) != nil { return view(trip, for: user) }
        guard record.useCount < record.invite.maxUses else { throw AppError.invite(.exhausted) }
        let target = record.participantID ?? claim
        var participantID: ParticipantID
        if let target {
            guard let index = trip.participants.firstIndex(where: { $0.id == target && ($0.userId == nil || $0.userId == user) }) else {
                throw AppError.invite(.participantUnavailable)
            }
            trip.participants.indices.forEach { if trip.participants[$0].userId == user { trip.participants[$0].userId = nil } }
            trip.participants[index].userId = user
            participantID = target
        } else if let existing = trip.participant(forUser: user) {
            participantID = existing.id
        } else {
            participantID = UUID()
            trip.participants.append(Participant(id: participantID, tripId: tripID, displayName: profiles[user]?.displayName ?? "Traveler", userId: user))
        }
        trip.members.removeAll { $0.userId == user }
        trip.members.append(TripMember(tripId: tripID, userId: user, participantId: participantID, role: record.invite.role, status: .active, joinedAt: clock()))
        trips[tripID] = trip
        for key in invites.keys where invites[key]?.invite.id == record.invite.id { invites[key]?.useCount += 1 }
        log(tripID, "member_joined", actor: user, entity: participantID)
        return view(trip, for: user)
    }

    func setRole(_ tripID: TripID, member: UserID, role newRole: TripRole, by user: UserID) throws -> Trip {
        try gate()
        try require(user, tripID, .owner)
        guard newRole != .owner, member != user else { throw AppError.validation(code: "invalid_role", message: nil) }
        guard let index = trips[tripID]!.members.firstIndex(where: { $0.userId == member && $0.status == .active }) else { throw AppError.notFound }
        trips[tripID]!.members[index].role = newRole
        log(tripID, "member_role_changed", actor: user, entity: nil)
        return view(trips[tripID]!, for: user)
    }

    func removeMember(_ tripID: TripID, member: UserID, by user: UserID) throws -> Trip {
        try gate()
        let myRole = try require(user, tripID, .admin)
        guard let index = trips[tripID]!.members.firstIndex(where: { $0.userId == member && $0.status == .active }) else { throw AppError.notFound }
        let target = trips[tripID]!.members[index].role
        if target == .owner || (target == .admin && myRole != .owner) { throw AppError.notAuthorized(code: "owner_required") }
        trips[tripID]!.members[index].status = .removed
        log(tripID, "member_removed", actor: user, entity: nil)
        return view(trips[tripID]!, for: user)
    }

    func transferOwnership(_ tripID: TripID, to newOwner: UserID, by user: UserID) throws -> Trip {
        try gate()
        try require(user, tripID, .owner)
        guard let newIndex = trips[tripID]!.members.firstIndex(where: { $0.userId == newOwner && $0.status == .active }),
              let myIndex = trips[tripID]!.members.firstIndex(where: { $0.userId == user }) else { throw AppError.notFound }
        trips[tripID]!.members[myIndex].role = .admin
        trips[tripID]!.members[newIndex].role = .owner
        trips[tripID]!.ownerId = newOwner
        trips[tripID]!.revision += 1
        log(tripID, "ownership_transferred", actor: user, entity: nil)
        return view(trips[tripID]!, for: user)
    }

    func leaveTrip(_ tripID: TripID, acknowledge: Bool, by user: UserID) throws {
        try gate()
        let myRole = try require(user, tripID)
        if myRole == .owner { throw AppError.conflict(code: "owner_must_transfer", currentRevision: nil) }
        let participant = trips[tripID]!.participant(forUser: user)!.id
        let net = try serverBalances(tripID).first { $0.participantId == participant }?.netMinor ?? 0
        if net != 0 && !acknowledge { throw AppError.conflict(code: "unsettled_balance", currentRevision: nil) }
        let index = trips[tripID]!.members.firstIndex { $0.userId == user }!
        trips[tripID]!.members[index].status = .left
        log(tripID, "member_left", actor: user, entity: participant)
    }

    // MARK: Expenses

    func expenses(_ tripID: TripID, updatedAfter: Date?, afterID: ExpenseID?, limit: Int, for user: UserID) throws -> ExpensePage {
        try gate()
        try require(user, tripID)
        let sorted = expenses.values.filter { $0.tripId == tripID }.sorted {
            ($0.updatedAt ?? .distantPast, $0.id.sortKey) < ($1.updatedAt ?? .distantPast, $1.id.sortKey)
        }
        let filtered = sorted.filter { expense in
            guard let updatedAfter else { return true }
            let stamp = expense.updatedAt ?? .distantPast
            return stamp > updatedAfter || (stamp == updatedAfter && expense.id.sortKey > (afterID?.sortKey ?? ""))
        }
        return ExpensePage(expenses: Array(filtered.prefix(limit)), hasMore: filtered.count > limit)
    }

    private func decodeExpense(_ data: Data) throws -> ExpensePayload {
        do { return try JSONCoding.decoder.decode(ExpensePayload.self, from: data) }
        catch { throw AppError.validation(code: "malformed_payload", message: nil) }
    }

    private func write(_ payload: ExpensePayload, tripID: TripID, revision: Int, by user: UserID, createdAt: Date?) throws -> Expense {
        let trip = trips[tripID]!
        try payload.validate(baseCurrency: trip.baseCurrency, participants: Set(trip.participants.map(\.id)))
        var expense = try payload.optimisticExpense(tripID: tripID, baseCurrency: trip.baseCurrency, revision: revision, createdBy: user, now: clock())
        expense.createdAt = createdAt ?? clock()
        expense.receiptIds = payload.receiptIds.filter { receipts[$0]?.tripId == tripID }
        for id in expense.receiptIds { receipts[id]?.expenseId = expense.id }
        return expense
    }

    func createExpense(_ tripID: TripID, payload data: Data, by user: UserID) throws -> Expense {
        try gate()
        try require(user, tripID, allowArchived: false)
        let payload = try decodeExpense(data)
        if let existing = expenses.values.first(where: { $0.tripId == tripID && $0.idempotencyKey == payload.idempotencyKey }) {
            guard try decodeExpense(expensePayloads[existing.id] ?? Data()) == payload else {
                throw AppError.conflict(code: "idempotency_key_reused", currentRevision: nil)
            }
            return existing
        }
        guard expenses[payload.id] == nil else { throw AppError.conflict(code: "id_conflict", currentRevision: nil) }
        let expense = try write(payload, tripID: tripID, revision: 1, by: user, createdAt: nil)
        expenses[expense.id] = expense
        expensePayloads[expense.id] = data
        log(tripID, "expense_created", actor: user, entity: expense.id, data: ["description": .string(expense.title), "amount_minor": .integer(expense.originalMinor), "currency": .string(expense.originalCurrency.rawValue)])
        return expense
    }

    func updateExpense(_ id: ExpenseID, expectedRevision: Int, payload data: Data, by user: UserID) throws -> Expense {
        try gate()
        guard let current = expenses[id] else { throw AppError.notFound }
        try require(user, current.tripId, allowArchived: false)
        guard current.deletedAt == nil else { throw AppError.conflict(code: "expense_deleted", currentRevision: current.revision) }
        guard current.revision == expectedRevision else { throw AppError.conflict(code: "revision_conflict", currentRevision: current.revision) }
        var payload = try decodeExpense(data)
        payload.idempotencyKey = current.idempotencyKey
        var updated = try write(payload, tripID: current.tripId, revision: current.revision + 1, by: user, createdAt: current.createdAt)
        updated.createdBy = current.createdBy
        expenses[id] = updated
        log(current.tripId, "expense_updated", actor: user, entity: id, data: ["description": .string(updated.title), "amount_minor": .integer(updated.originalMinor), "currency": .string(updated.originalCurrency.rawValue)])
        return updated
    }

    func setExpenseDeleted(_ id: ExpenseID, deleted: Bool, expectedRevision: Int, by user: UserID) throws -> Expense {
        try gate()
        guard var expense = expenses[id] else { throw AppError.notFound }
        try require(user, expense.tripId, allowArchived: false)
        if (expense.deletedAt != nil) == deleted { return expense }
        guard expense.revision == expectedRevision else { throw AppError.conflict(code: "revision_conflict", currentRevision: expense.revision) }
        expense.deletedAt = deleted ? clock() : nil
        expense.revision += 1
        expense.updatedAt = clock()
        expense.updatedBy = user
        expenses[id] = expense
        log(expense.tripId, deleted ? "expense_deleted" : "expense_restored", actor: user, entity: id, data: ["description": .string(expense.title), "amount_minor": .integer(expense.originalMinor), "currency": .string(expense.originalCurrency.rawValue)])
        return expense
    }

    // MARK: Settlements & balances

    func settlements(_ tripID: TripID, for user: UserID) throws -> [Settlement] {
        try gate()
        try require(user, tripID)
        return settlements.values.filter { $0.tripId == tripID }.sorted { $0.settledAt < $1.settledAt }
    }

    func recordSettlement(_ tripID: TripID, payload data: Data, by user: UserID) throws -> Settlement {
        try gate()
        try require(user, tripID, allowArchived: false)
        let payload: SettlementPayload
        do { payload = try JSONCoding.decoder.decode(SettlementPayload.self, from: data) } catch { throw AppError.validation(code: "malformed_payload", message: nil) }
        if let existing = settlements.values.first(where: { $0.tripId == tripID && $0.idempotencyKey == payload.idempotencyKey }) {
            guard settlementPayloads[existing.id] == data else { throw AppError.conflict(code: "idempotency_key_reused", currentRevision: nil) }
            return existing
        }
        let trip = trips[tripID]!
        guard payload.amountMinor > 0 else { throw AppError.validation(code: "invalid_amount", message: nil) }
        guard payload.fromParticipantId != payload.toParticipantId else { throw AppError.validation(code: "invalid_parties", message: nil) }
        guard trip.participant(payload.fromParticipantId) != nil, trip.participant(payload.toParticipantId) != nil else {
            throw AppError.validation(code: "unknown_participant", message: nil)
        }
        if payload.currency != trip.baseCurrency, (payload.exchangeRate ?? 0) <= 0 { throw AppError.validation(code: "exchange_rate_required", message: nil) }
        let settlement = try payload.optimisticSettlement(tripID: tripID, baseCurrency: trip.baseCurrency, createdBy: user)
        settlements[settlement.id] = settlement
        settlementPayloads[settlement.id] = data
        log(tripID, "settlement_recorded", actor: user, entity: settlement.id, data: ["from_participant_id": .string(payload.fromParticipantId.uuidString), "to_participant_id": .string(payload.toParticipantId.uuidString), "amount_minor": .integer(payload.amountMinor), "currency": .string(payload.currency.rawValue)])
        return settlement
    }

    func deleteSettlement(_ id: UUID, expectedRevision: Int, by user: UserID) throws -> Settlement {
        try gate()
        guard var settlement = settlements[id] else { throw AppError.notFound }
        try require(user, settlement.tripId, allowArchived: false)
        if settlement.deletedAt != nil { return settlement }
        guard settlement.revision == expectedRevision else { throw AppError.conflict(code: "revision_conflict", currentRevision: settlement.revision) }
        settlement.deletedAt = clock()
        settlement.revision += 1
        settlements[id] = settlement
        log(settlement.tripId, "settlement_deleted", actor: user, entity: id)
        return settlement
    }

    private func serverBalances(_ tripID: TripID) throws -> [ServerBalance] {
        let trip = trips[tripID]!
        let balances = try Ledger.balances(
            participants: trip.participants.map(\.id),
            expenses: expenses.values.filter { $0.tripId == tripID && $0.deletedAt == nil }.map(\.ledgerFact),
            settlements: settlements.values.filter { $0.tripId == tripID && $0.deletedAt == nil }.map(\.ledgerFact))
        return balances.map { ServerBalance(participantId: $0.participantID, paidMinor: $0.paidMinor, owedMinor: $0.owedMinor,
                                            sentMinor: $0.settlementsSentMinor, receivedMinor: $0.settlementsReceivedMinor, netMinor: $0.netMinor) }
    }

    func balances(_ tripID: TripID, for user: UserID) throws -> [ServerBalance] {
        try gate()
        try require(user, tripID)
        return try serverBalances(tripID)
    }

    func suggestions(_ tripID: TripID, for user: UserID) throws -> [SuggestedTransfer] {
        try gate()
        try require(user, tripID)
        return Ledger.simplify(try serverBalances(tripID).map(\.participantBalance))
    }

    func summary(_ tripID: TripID, for user: UserID) throws -> TripSummary? {
        try gate()
        try require(user, tripID)
        let trip = trips[tripID]!
        let live = expenses.values.filter { $0.tripId == tripID && $0.deletedAt == nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: trip.timezone) ?? .gmt
        let byCategory = Dictionary(grouping: live, by: \.category).map { TripSummary.CategoryTotal(category: $0.key, totalMinor: $0.value.reduce(0) { $0 + $1.baseMinor }, count: $0.value.count) }
            .sorted { ($0.totalMinor, $1.category.rawValue) > ($1.totalMinor, $0.category.rawValue) }
        let byDay = Dictionary(grouping: live) { calendar.startOfDay(for: $0.spentAt) }.map { TripSummary.DayTotal(day: $0.key, totalMinor: $0.value.reduce(0) { $0 + $1.baseMinor }) }
            .sorted { $0.day < $1.day }
        let balances = try serverBalances(tripID)
        return TripSummary(tripId: tripID, baseCurrency: trip.baseCurrency, budgetMinor: trip.budgetMinor,
                           totalSpentMinor: live.reduce(0) { $0 + $1.baseMinor }, expenseCount: live.count,
                           byCategory: byCategory, byDay: byDay,
                           byParticipant: balances.map { .init(participantId: $0.participantId, consumedMinor: $0.owedMinor, paidMinor: $0.paidMinor) })
    }

    func activity(_ tripID: TripID, beforeID: Int64?, limit: Int, for user: UserID) throws -> [ActivityEvent] {
        try gate()
        try require(user, tripID)
        return Array(activity.filter { $0.tripId == tripID && (beforeID == nil || $0.id < beforeID!) }.sorted { $0.id > $1.id }.prefix(limit))
    }

    // MARK: Receipts

    func registerReceipt(_ prepared: PreparedReceipt, tripID: TripID, by user: UserID) throws -> ReceiptRegistration {
        try gate()
        try require(user, tripID, allowArchived: false)
        let receipt = Receipt(id: prepared.id, tripId: tripID, expenseId: nil, settlementId: nil, uploadedBy: user,
                              objectPath: "\(tripID.sortKey)/\(prepared.id.sortKey).\(prepared.fileExtension)", mimeType: prepared.mimeType,
                              byteSize: prepared.data.count, scanStatus: .none, scanResult: nil, scanError: nil, createdAt: clock())
        let duplicates = receipts.values.filter { $0.tripId == tripID && $0.id != prepared.id && receiptHashes[$0.id] == prepared.sha256 }
            .map { ReceiptDuplicate(receiptId: $0.id, expenseId: $0.expenseId, createdAt: $0.createdAt, exact: true) }
        receipts[receipt.id] = receipt
        receiptData[receipt.id] = prepared.data
        receiptHashes[receipt.id] = prepared.sha256
        return ReceiptRegistration(receipt: receipt, duplicates: duplicates)
    }
    private var receiptHashes: [UUID: String] = [:]

    func attachReceipt(_ receiptID: UUID, to expenseID: ExpenseID, by user: UserID) throws -> Expense {
        try gate()
        guard let receipt = receipts[receiptID], var expense = expenses[expenseID], receipt.tripId == expense.tripId else { throw AppError.notFound }
        try require(user, receipt.tripId, allowArchived: false)
        receipts[receiptID]?.expenseId = expenseID
        if !expense.receiptIds.contains(receiptID) { expense.receiptIds.append(receiptID) }
        expense.updatedAt = clock()
        expenses[expenseID] = expense
        notify(expense.tripId)
        return expense
    }

    func receipts(_ tripID: TripID, for user: UserID) throws -> [Receipt] {
        try gate()
        try require(user, tripID)
        return receipts.values.filter { $0.tripId == tripID }.sorted { $0.createdAt > $1.createdAt }
    }

    func receiptBytes(_ id: UUID, for user: UserID) throws -> Data {
        try gate()
        guard let receipt = receipts[id] else { throw AppError.notFound }
        try require(user, receipt.tripId)
        return receiptData[id] ?? Data()
    }

    func deleteReceipt(_ id: UUID, by user: UserID) throws {
        try gate()
        guard let receipt = receipts[id] else { return }
        let role = try require(user, receipt.tripId)
        guard receipt.uploadedBy == user || role >= .admin else { throw AppError.notAuthorized(code: "admin_required") }
        receipts[id] = nil
        receiptData[id] = nil
        for key in expenses.keys { expenses[key]?.receiptIds.removeAll { $0 == id } }
    }

    // MARK: Account

    func preferences(_ user: UserID) throws -> NotificationPreferences { try gate(); return preferences[user] ?? NotificationPreferences() }
    func savePreferences(_ value: NotificationPreferences, _ user: UserID) throws { try gate(); preferences[user] = value }
    func registerDevice(_ token: String, _ user: UserID) throws { try gate(); devices[token] = user }
    func unregisterDevice(_ token: String, _ user: UserID) throws { try gate(); if devices[token] == user { devices[token] = nil } }

    func export(for user: UserID) throws -> Data {
        try gate()
        struct Export: Encodable { var profile: Profile?; var trips: [Trip]; var expenses: [Expense]; var settlements: [Settlement] }
        let mine = trips.values.filter { role(of: user, in: $0.id) != nil }
        let ids = Set(mine.map(\.id))
        let export = Export(profile: profiles[user], trips: mine, expenses: expenses.values.filter { ids.contains($0.tripId) },
                            settlements: settlements.values.filter { ids.contains($0.tripId) })
        return try JSONCoding.prettyEncoder.encode(export)
    }

    func deleteAccount(_ user: UserID) throws {
        try gate()
        for trip in trips.values where role(of: user, in: trip.id) != nil {
            if trip.ownerId == user {
                if let successor = trip.activeMembers.first(where: { $0.userId != user }) {
                    _ = try? transferOwnership(trip.id, to: successor.userId, by: user)
                } else {
                    try deleteTrip(trip.id, by: user)
                    continue
                }
            }
            if let index = trips[trip.id]?.members.firstIndex(where: { $0.userId == user }) { trips[trip.id]!.members[index].status = .left }
            if let index = trips[trip.id]?.participants.firstIndex(where: { $0.userId == user }) {
                trips[trip.id]!.participants[index].userId = nil
                trips[trip.id]!.participants[index].displayName = "Former traveler"
            }
        }
        profiles[user] = nil
        preferences[user] = nil
        devices = devices.filter { $0.value != user }
    }
}
