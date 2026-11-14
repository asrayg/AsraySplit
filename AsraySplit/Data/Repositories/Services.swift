import Foundation

// Remote service boundaries. `SupabaseBackend` implements them against the real project;
// `InMemoryBackend` implements them for demo mode, previews and tests. Features never talk to
// a concrete backend directly.

enum AuthState: Equatable, Sendable {
    case unknown
    case signedOut
    case signedIn(UserID, email: String?)

    var userID: UserID? { if case .signedIn(let id, _) = self { id } else { nil } }
}

protocol AuthService: AnyObject, Sendable {
    func currentState() async -> AuthState
    func stateChanges() -> AsyncStream<AuthState>
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws
    func sendMagicLink(to email: String) async throws
    /// Passwordless, email-less account for the fixed trip crew (TestFlight build).
    func signInAnonymously() async throws
    /// Completes a magic-link sign-in. Returns false when the URL is not an auth callback.
    func handleAuthCallback(_ url: URL) async throws -> Bool
    func signOut() async throws
}

protocol TripService: Sendable {
    func fetchTrips() async throws -> [Trip]
    func fetchTrip(_ id: TripID) async throws -> Trip
    func createTrip(_ draft: TripDraft) async throws -> Trip
    func updateTrip(_ draft: TripDraft, expectedRevision: Int) async throws -> Trip
    func setArchived(_ tripID: TripID, archived: Bool) async throws -> Trip
    func deleteTrip(_ tripID: TripID) async throws
    func addParticipant(tripID: TripID, participantID: ParticipantID, name: String) async throws -> Trip
    func renameParticipant(_ participantID: ParticipantID, name: String) async throws -> Trip
    func createInvite(tripID: TripID, role: TripRole, expiresInHours: Int, maxUses: Int, participantID: ParticipantID?) async throws -> TripInvite
    func revokeInvite(_ inviteID: UUID) async throws
    func previewInvite(secret: String) async throws -> InvitePreview
    func acceptInvite(secret: String, claimParticipantID: ParticipantID?) async throws -> Trip
    func setMemberRole(tripID: TripID, userID: UserID, role: TripRole) async throws -> Trip
    func removeMember(tripID: TripID, userID: UserID) async throws -> Trip
    func transferOwnership(tripID: TripID, to userID: UserID) async throws -> Trip
    func leaveTrip(_ tripID: TripID, acknowledgeUnsettled: Bool) async throws
    /// Crew build: joins the built-in trip as the named person (see migration 20261113000300).
    func joinCrewTrip(name: String) async throws -> Trip
}

struct ExpensePage: Sendable {
    var expenses: [Expense]
    var hasMore: Bool
}

protocol LedgerService: Sendable {
    /// Incremental sync including tombstones, ordered by (updatedAt, id).
    func fetchExpenses(tripID: TripID, updatedAfter: Date?, afterID: ExpenseID?, limit: Int) async throws -> ExpensePage
    func createExpense(tripID: TripID, payload: Data) async throws -> Expense
    func updateExpense(id: ExpenseID, expectedRevision: Int, payload: Data) async throws -> Expense
    func deleteExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense
    func restoreExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense
    func fetchSettlements(tripID: TripID) async throws -> [Settlement]
    func recordSettlement(tripID: TripID, payload: Data) async throws -> Settlement
    func deleteSettlement(id: UUID, expectedRevision: Int) async throws -> Settlement
    func fetchBalances(tripID: TripID) async throws -> [ServerBalance]
    func fetchSuggestedSettlements(tripID: TripID) async throws -> [SuggestedTransfer]
    func fetchSummary(tripID: TripID) async throws -> TripSummary?
    func fetchActivity(tripID: TripID, beforeID: Int64?, limit: Int) async throws -> [ActivityEvent]
    /// Emails a member who owes money a reminder (at most once a day per trip).
    func requestPaymentReminder(tripID: TripID, debtor: ParticipantID) async throws -> ReminderResult
}

struct PreparedReceipt: Sendable {
    var id: UUID
    var data: Data
    var mimeType: String
    var fileExtension: String
    var width: Int?
    var height: Int?
    var sha256: String
    var perceptualHash: String?
}

struct Receipt: Identifiable, Codable, Hashable, Sendable {
    enum ScanStatus: String, Codable, Sendable { case none, queued, processing, succeeded, failed }
    var id: UUID
    var tripId: TripID
    var expenseId: ExpenseID?
    var settlementId: UUID?
    var uploadedBy: UserID?
    var objectPath: String
    var mimeType: String
    var byteSize: Int
    var scanStatus: ScanStatus
    var scanResult: JSONValue?
    var scanError: String?
    var createdAt: Date
}

struct ReceiptDuplicate: Codable, Hashable, Sendable {
    var receiptId: UUID
    var expenseId: ExpenseID?
    var createdAt: Date
    var exact: Bool
}

struct ReceiptRegistration: Sendable {
    var receipt: Receipt
    var duplicates: [ReceiptDuplicate]
}

protocol ReceiptService: Sendable {
    func uploadReceipt(_ receipt: PreparedReceipt, tripID: TripID) async throws -> ReceiptRegistration
    /// Runs server-side AI extraction. The result is untrusted until validated by `ScanResultValidator`.
    func scanReceipt(id: UUID) async throws -> ReceiptScanResult
    func fetchReceipts(tripID: TripID) async throws -> [Receipt]
    /// Links an uploaded receipt to an existing expense (used for receipts captured offline).
    func attachReceipt(_ receiptID: UUID, to expenseID: ExpenseID) async throws -> Expense
    func signedURL(for receipt: Receipt) async throws -> URL
    func downloadReceipt(_ receipt: Receipt) async throws -> Data
    func deleteReceipt(_ receipt: Receipt) async throws
}

struct NotificationPreferences: Codable, Equatable, Sendable {
    var pushEnabled = true
    var expenseChanges = true
    var settlements = true
    var membership = true
    var receiptScans = true
    var dailyReminder = false
    var showDetailsOnLockScreen = false
    var quietHoursStart: String?
    var quietHoursEnd: String?
    var timezone = TimeZone.current.identifier
    /// Settle-up reminder emails (sent through Resend).
    var emailReminders = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationPreferences()
        pushEnabled = try container.decodeIfPresent(Bool.self, forKey: .pushEnabled) ?? defaults.pushEnabled
        expenseChanges = try container.decodeIfPresent(Bool.self, forKey: .expenseChanges) ?? defaults.expenseChanges
        settlements = try container.decodeIfPresent(Bool.self, forKey: .settlements) ?? defaults.settlements
        membership = try container.decodeIfPresent(Bool.self, forKey: .membership) ?? defaults.membership
        receiptScans = try container.decodeIfPresent(Bool.self, forKey: .receiptScans) ?? defaults.receiptScans
        dailyReminder = try container.decodeIfPresent(Bool.self, forKey: .dailyReminder) ?? defaults.dailyReminder
        showDetailsOnLockScreen = try container.decodeIfPresent(Bool.self, forKey: .showDetailsOnLockScreen) ?? defaults.showDetailsOnLockScreen
        quietHoursStart = try container.decodeIfPresent(String.self, forKey: .quietHoursStart)
        quietHoursEnd = try container.decodeIfPresent(String.self, forKey: .quietHoursEnd)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? defaults.timezone
        emailReminders = try container.decodeIfPresent(Bool.self, forKey: .emailReminders) ?? defaults.emailReminders
    }
}

struct ReminderResult: Codable, Equatable, Sendable {
    var queued: Bool
    /// no_account, settled, opted_out, already_reminded_today
    var reason: String?
}

protocol AccountService: Sendable {
    func fetchProfile() async throws -> Profile
    func updateProfile(displayName: String, avatarEmoji: String?, defaultCurrency: CurrencyCode) async throws -> Profile
    func fetchNotificationPreferences() async throws -> NotificationPreferences
    func saveNotificationPreferences(_ preferences: NotificationPreferences) async throws
    func setTripMuted(_ tripID: TripID, muted: Bool) async throws
    func registerDevice(token: String, environment: String, bundleID: String, appVersion: String?) async throws
    func unregisterDevice(token: String) async throws
    /// JSON export of everything the user can see.
    func exportData() async throws -> Data
    /// Deletes the account server-side. `appleAuthorizationCode` lets the server revoke Sign in with Apple tokens.
    func deleteAccount(appleAuthorizationCode: String?) async throws
}

struct ExchangeRateQuote: Codable, Equatable, Sendable {
    var base: CurrencyCode
    var quote: CurrencyCode
    @ExactDecimal var rate: Decimal
    var provider: String
    var asOf: Date
}

protocol ExchangeRateService: Sendable {
    /// Units of `to` per one unit of `from` for the given day.
    func rate(from: CurrencyCode, to: CurrencyCode, on date: Date) async throws -> ExchangeRateQuote
}

protocol RealtimeService: Sendable {
    /// Emits whenever any row of the trip changes. Consumers refetch canonical data; payloads are ignored.
    func changes(tripID: TripID) -> AsyncStream<Void>
}

protocol ChatService: Sendable {
    func listMessages(tripID: TripID) async throws -> [ChatMessage]
    /// Idempotent on `message.id`. Only the sender posts their own messages.
    func postMessage(_ message: ChatMessage) async throws -> ChatMessage
    /// Emits when the trip's messages change on the server.
    func messageChanges(tripID: TripID) -> AsyncStream<Void>
}

protocol PhotoService: Sendable {
    func listPhotos(tripID: TripID) async throws -> [TripPhoto]
    /// Uploads the JPEG (idempotent if already present) and registers it.
    func uploadPhoto(_ photo: TripPhoto, data: Data) async throws -> TripPhoto
    func downloadPhoto(_ photo: TripPhoto) async throws -> Data
}

protocol LocationService: Sendable {
    func updateMyLocation(tripID: TripID, latitude: Double, longitude: Double, accuracy: Double?, recordedAt: Date) async throws
    func stopSharingLocation(tripID: TripID) async throws
    func listMemberLocations(tripID: TripID) async throws -> [MemberLocation]
    func locationChanges(tripID: TripID) -> AsyncStream<Void>
}

/// Everything remote, bundled for dependency injection.
struct Backend: Sendable {
    var kind: Kind
    var auth: any AuthService
    var trips: any TripService
    var ledger: any LedgerService
    var receipts: any ReceiptService
    var account: any AccountService
    var rates: any ExchangeRateService
    var realtime: any RealtimeService
    var chat: any ChatService
    var photos: any PhotoService
    var locations: any LocationService

    enum Kind: Equatable, Sendable { case supabase, demo }
}
