import Foundation

/// Client-side adapter that talks to an `InMemoryServer` as one signed-in user. Two adapters over the
/// same server behave like two devices/users of one Supabase project.
final class InMemoryBackend: AuthService, TripService, LedgerService, ReceiptService, AccountService, ExchangeRateService, RealtimeService, @unchecked Sendable {
    let server: InMemoryServer
    private let lock = NSLock()
    private var state: AuthState
    private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    private let displayName: String

    init(server: InMemoryServer, userID: UserID?, displayName: String = "You") {
        self.server = server
        self.displayName = displayName
        state = userID.map { .signedIn($0, email: nil) } ?? .signedOut
        if let userID { Task { await server.ensureProfile(userID, name: displayName) } }
    }

    var backend: Backend {
        Backend(kind: .demo, auth: self, trips: self, ledger: self, receipts: self, account: self, rates: self, realtime: self)
    }

    private func user() throws -> UserID {
        lock.lock(); defer { lock.unlock() }
        guard let id = state.userID else { throw AppError.notAuthenticated }
        return id
    }

    private func setState(_ newState: AuthState) {
        lock.lock()
        state = newState
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(newState) }
    }

    // MARK: AuthService

    func currentState() async -> AuthState { lock.lock(); defer { lock.unlock() }; return state }

    func stateChanges() -> AsyncStream<AuthState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AuthState>.makeStream()
        lock.lock(); continuations[id] = continuation; let current = state; lock.unlock()
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock() }
        return stream
    }

    /// Demo sign-in: any credential signs in the local demo user.
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws { await signInDemo() }
    func sendMagicLink(to email: String) async throws { await signInDemo() }
    func handleAuthCallback(_ url: URL) async throws -> Bool { false }
    func signOut() async throws { setState(.signedOut) }

    func signInDemo(userID: UserID = DemoData.demoUserID) async {
        await server.ensureProfile(userID, name: displayName)
        setState(.signedIn(userID, email: nil))
    }

    // MARK: TripService

    func fetchTrips() async throws -> [Trip] { try await server.trips(for: user()) }
    func fetchTrip(_ id: TripID) async throws -> Trip { try await server.trip(id, for: user()) }
    func createTrip(_ draft: TripDraft) async throws -> Trip { try await server.createTrip(draft, by: user()) }
    func updateTrip(_ draft: TripDraft, expectedRevision: Int) async throws -> Trip { try await server.updateTrip(draft, expectedRevision: expectedRevision, by: user()) }
    func setArchived(_ tripID: TripID, archived: Bool) async throws -> Trip { try await server.setArchived(tripID, archived, by: user()) }
    func deleteTrip(_ tripID: TripID) async throws { try await server.deleteTrip(tripID, by: user()) }
    func addParticipant(tripID: TripID, participantID: ParticipantID, name: String) async throws -> Trip {
        try await server.addParticipant(tripID, id: participantID, name: name, by: user())
    }
    func renameParticipant(_ participantID: ParticipantID, name: String) async throws -> Trip { try await server.renameParticipant(participantID, name: name, by: user()) }
    func createInvite(tripID: TripID, role: TripRole, expiresInHours: Int, maxUses: Int, participantID: ParticipantID?) async throws -> TripInvite {
        try await server.createInvite(tripID, role: role, hours: expiresInHours, maxUses: maxUses, participantID: participantID, by: user())
    }
    func revokeInvite(_ inviteID: UUID) async throws { try await server.revokeInvite(inviteID, by: user()) }
    func previewInvite(secret: String) async throws -> InvitePreview { try await server.previewInvite(secret, for: user()) }
    func acceptInvite(secret: String, claimParticipantID: ParticipantID?) async throws -> Trip { try await server.acceptInvite(secret, claim: claimParticipantID, by: user()) }
    func setMemberRole(tripID: TripID, userID: UserID, role: TripRole) async throws -> Trip { try await server.setRole(tripID, member: userID, role: role, by: user()) }
    func removeMember(tripID: TripID, userID: UserID) async throws -> Trip { try await server.removeMember(tripID, member: userID, by: user()) }
    func transferOwnership(tripID: TripID, to userID: UserID) async throws -> Trip { try await server.transferOwnership(tripID, to: userID, by: user()) }
    func leaveTrip(_ tripID: TripID, acknowledgeUnsettled: Bool) async throws { try await server.leaveTrip(tripID, acknowledge: acknowledgeUnsettled, by: user()) }

    // MARK: LedgerService

    func fetchExpenses(tripID: TripID, updatedAfter: Date?, afterID: ExpenseID?, limit: Int) async throws -> ExpensePage {
        try await server.expenses(tripID, updatedAfter: updatedAfter, afterID: afterID, limit: limit, for: user())
    }
    func createExpense(tripID: TripID, payload: Data) async throws -> Expense { try await server.createExpense(tripID, payload: payload, by: user()) }
    func updateExpense(id: ExpenseID, expectedRevision: Int, payload: Data) async throws -> Expense {
        try await server.updateExpense(id, expectedRevision: expectedRevision, payload: payload, by: user())
    }
    func deleteExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense {
        try await server.setExpenseDeleted(id, deleted: true, expectedRevision: expectedRevision, by: user())
    }
    func restoreExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense {
        try await server.setExpenseDeleted(id, deleted: false, expectedRevision: expectedRevision, by: user())
    }
    func fetchSettlements(tripID: TripID) async throws -> [Settlement] { try await server.settlements(tripID, for: user()) }
    func recordSettlement(tripID: TripID, payload: Data) async throws -> Settlement { try await server.recordSettlement(tripID, payload: payload, by: user()) }
    func deleteSettlement(id: UUID, expectedRevision: Int) async throws -> Settlement { try await server.deleteSettlement(id, expectedRevision: expectedRevision, by: user()) }
    func fetchBalances(tripID: TripID) async throws -> [ServerBalance] { try await server.balances(tripID, for: user()) }
    func fetchSuggestedSettlements(tripID: TripID) async throws -> [SuggestedTransfer] { try await server.suggestions(tripID, for: user()) }
    func fetchSummary(tripID: TripID) async throws -> TripSummary? { try await server.summary(tripID, for: user()) }
    func fetchActivity(tripID: TripID, beforeID: Int64?, limit: Int) async throws -> [ActivityEvent] {
        try await server.activity(tripID, beforeID: beforeID, limit: limit, for: user())
    }

    // MARK: ReceiptService

    func uploadReceipt(_ receipt: PreparedReceipt, tripID: TripID) async throws -> ReceiptRegistration {
        try await server.registerReceipt(receipt, tripID: tripID, by: user())
    }

    /// Demo mode never calls an AI provider; it reads the image on-device instead.
    func scanReceipt(id: UUID) async throws -> ReceiptScanResult {
        throw AppError.notConfigured
    }

    func fetchReceipts(tripID: TripID) async throws -> [Receipt] { try await server.receipts(tripID, for: user()) }
    func signedURL(for receipt: Receipt) async throws -> URL {
        let data = try await server.receiptBytes(receipt.id, for: user())
        let url = FileManager.default.temporaryDirectory.appending(path: "\(receipt.id.uuidString).\(receipt.objectPath.split(separator: ".").last ?? "jpg")")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    func downloadReceipt(_ receipt: Receipt) async throws -> Data { try await server.receiptBytes(receipt.id, for: user()) }
    func deleteReceipt(_ receipt: Receipt) async throws { try await server.deleteReceipt(receipt.id, by: user()) }

    // MARK: AccountService

    func fetchProfile() async throws -> Profile { try await server.profile(user()) }
    func updateProfile(displayName: String, avatarEmoji: String?, defaultCurrency: CurrencyCode) async throws -> Profile {
        try await server.updateProfile(user(), name: displayName, emoji: avatarEmoji, currency: defaultCurrency)
    }
    func fetchNotificationPreferences() async throws -> NotificationPreferences { try await server.preferences(user()) }
    func saveNotificationPreferences(_ preferences: NotificationPreferences) async throws { try await server.savePreferences(preferences, user()) }
    func setTripMuted(_ tripID: TripID, muted: Bool) async throws {}
    func registerDevice(token: String, environment: String, bundleID: String, appVersion: String?) async throws { try await server.registerDevice(token, user()) }
    func unregisterDevice(token: String) async throws { try await server.unregisterDevice(token, user()) }
    func exportData() async throws -> Data { try await server.export(for: user()) }
    func deleteAccount(appleAuthorizationCode: String?) async throws {
        try await server.deleteAccount(user())
        setState(.signedOut)
    }

    // MARK: ExchangeRateService

    /// Fixed illustrative rates for demo mode only (labelled "demo" in the UI).
    func rate(from: CurrencyCode, to: CurrencyCode, on date: Date) async throws -> ExchangeRateQuote {
        let usdPer: [String: Decimal] = ["USD": 1, "EUR": Decimal(string: "1.08")!, "GBP": Decimal(string: "1.27")!, "JPY": Decimal(string: "0.0067")!,
                                         "CAD": Decimal(string: "0.73")!, "AUD": Decimal(string: "0.66")!, "MXN": Decimal(string: "0.055")!, "INR": Decimal(string: "0.012")!]
        guard let fromUSD = usdPer[from.rawValue], let toUSD = usdPer[to.rawValue] else { throw AppError.validation(code: "exchange_rate_required", message: nil) }
        var rate = fromUSD / toUSD
        var rounded = Decimal()
        NSDecimalRound(&rounded, &rate, 6, .plain)
        return ExchangeRateQuote(base: from, quote: to, rate: rounded, provider: "demo", asOf: date)
    }

    // MARK: RealtimeService

    func changes(tripID: TripID) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { [server] in
            for await _ in await server.subscribe(tripID) { continuation.yield(()) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
