import Foundation
import Supabase

/// Production backend: Supabase Auth (Keychain-persisted sessions with automatic refresh),
/// PostgREST RPCs, Storage, Edge Functions and Realtime.
final class SupabaseBackend: AuthService, TripService, LedgerService, ReceiptService, AccountService, ExchangeRateService, RealtimeService, @unchecked Sendable {
    let client: SupabaseClient
    private let redirectURL = URL(string: "asraysplit://auth-callback")!

    init(url: URL, publishableKey: String) {
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: publishableKey,
            options: SupabaseClientOptions(
                db: .init(encoder: JSONCoding.encoder, decoder: JSONCoding.decoder),
                auth: .init(storage: KeychainLocalStorage(service: "com.asray.split.auth"), redirectToURL: URL(string: "asraysplit://auth-callback")!, flowType: .pkce),
                global: .init(logger: nil)))
    }

    var backend: Backend {
        Backend(kind: .supabase, auth: self, trips: self, ledger: self, receipts: self, account: self, rates: self, realtime: self)
    }

    // MARK: Error mapping

    /// Maps PostgREST/HTTP errors onto `AppError` using the server's error contract.
    static func map(_ error: Error) -> AppError {
        if let error = error as? AppError { return error }
        if let error = error as? PostgrestError {
            let code = error.message
            switch error.code {
            case "42501":
                return code == "not_authenticated" ? .notAuthenticated : .notAuthorized(code: code)
            case "PT404": return .notFound
            case "PT409":
                let revision = error.detail.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["current_revision"] as? Int
                return .conflict(code: code, currentRevision: revision)
            case "PT429": return .rateLimited(message: error.hint)
            case "22023", "P0001": return .validation(code: code, message: error.hint)
            case "PGRST301", "PGRST302": return .notAuthenticated
            default: return .server(message: nil)
            }
        }
        if let error = error as? FunctionsError, case .httpError(let status, let data) = error {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let code = body["code"] as? String ?? "function_error"
            switch status {
            case 401: return .notAuthenticated
            case 403: return .notAuthorized(code: code)
            case 404: return .notFound
            case 409: return .conflict(code: code, currentRevision: nil)
            case 429: return .rateLimited(message: body["message"] as? String)
            case 400, 422: return .validation(code: code, message: body["message"] as? String)
            default: return .server(message: body["message"] as? String)
            }
        }
        if let error = error as? AuthError {
            if case .sessionMissing = error { return .notAuthenticated }
            return .notAuthenticated
        }
        return error.asAppError
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.map(error) }
    }

    /// Calls an RPC returning jsonb and decodes it with the shared decoder.
    private func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue] = [:], as type: T.Type = T.self) async throws -> T {
        try await call {
            let data = try await client.rpc(name, params: params).execute().data
            return try JSONCoding.decoder.decode(T.self, from: data)
        }
    }

    private func rpcVoid(_ name: String, _ params: [String: JSONValue] = [:]) async throws {
        try await call { _ = try await client.rpc(name, params: params).execute() }
    }

    private static func json(_ uuid: UUID?) -> JSONValue { uuid.map { .string($0.uuidString.lowercased()) } ?? .null }
    private static func json(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }
    private static func json(_ date: Date?) -> JSONValue { date.map { .string(PostgresDate.timestamp($0)) } ?? .null }
    private static func json(_ value: Int64?) -> JSONValue { value.map { .integer($0) } ?? .null }

    // MARK: AuthService

    func currentState() async -> AuthState {
        guard let session = try? await client.auth.session else { return .signedOut }
        return .signedIn(session.user.id, email: session.user.email)
    }

    func stateChanges() -> AsyncStream<AuthState> {
        AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .signedOut, .userDeleted: continuation.yield(.signedOut)
                    default:
                        if let session, !session.isExpired { continuation.yield(.signedIn(session.user.id, email: session.user.email)) }
                        else if event == .initialSession { continuation.yield(.signedOut) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws {
        try await call {
            _ = try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            // Apple shares the name only on first authorization; persist it as the display name.
            if let fullName, let name = PersonNameComponentsFormatter().string(from: fullName).nilIfEmpty {
                _ = try? await updateProfile(displayName: name, avatarEmoji: nil, defaultCurrency: nil)
            }
        }
    }

    func sendMagicLink(to email: String) async throws {
        try await call { try await client.auth.signInWithOTP(email: email, redirectTo: redirectURL, shouldCreateUser: true) }
    }

    func handleAuthCallback(_ url: URL) async throws -> Bool {
        guard url.scheme == redirectURL.scheme, url.host == redirectURL.host else { return false }
        try await call { _ = try await client.auth.session(from: url) }
        return true
    }

    func signOut() async throws {
        try await call { try await client.auth.signOut(scope: .local) }
    }

    // MARK: TripService

    func fetchTrips() async throws -> [Trip] { try await rpc("list_my_trips") }
    func fetchTrip(_ id: TripID) async throws -> Trip { try await rpc("get_trip", ["p_trip_id": Self.json(id)]) }

    func createTrip(_ draft: TripDraft) async throws -> Trip {
        try await rpc("create_trip", [
            "p_trip_id": Self.json(draft.id), "p_name": .string(draft.trimmedName), "p_base_currency": .string(draft.baseCurrency.rawValue),
            "p_emoji": .string(draft.emoji), "p_color_hex": .string(draft.colorHex),
            "p_start_date": draft.startDate.map { .string(PostgresDate.day($0)) } ?? .null,
            "p_end_date": draft.endDate.map { .string(PostgresDate.day($0)) } ?? .null,
            "p_timezone": .string(draft.timezone), "p_budget_minor": Self.json(draft.budgetMinor),
            "p_guest_names": .array(draft.guestNames.map { .string($0) }),
        ])
    }

    func updateTrip(_ draft: TripDraft, expectedRevision: Int) async throws -> Trip {
        try await rpc("update_trip", [
            "p_trip_id": Self.json(draft.id), "p_expected_revision": .integer(Int64(expectedRevision)), "p_name": .string(draft.trimmedName),
            "p_emoji": .string(draft.emoji), "p_color_hex": .string(draft.colorHex),
            "p_start_date": draft.startDate.map { .string(PostgresDate.day($0)) } ?? .null,
            "p_end_date": draft.endDate.map { .string(PostgresDate.day($0)) } ?? .null,
            "p_timezone": .string(draft.timezone), "p_base_currency": .string(draft.baseCurrency.rawValue), "p_budget_minor": Self.json(draft.budgetMinor),
        ])
    }

    func setArchived(_ tripID: TripID, archived: Bool) async throws -> Trip {
        try await rpc("set_trip_archived", ["p_trip_id": Self.json(tripID), "p_archived": .bool(archived)])
    }

    func deleteTrip(_ tripID: TripID) async throws { try await rpcVoid("delete_trip", ["p_trip_id": Self.json(tripID)]) }

    func addParticipant(tripID: TripID, participantID: ParticipantID, name: String) async throws -> Trip {
        try await rpc("add_participant", ["p_trip_id": Self.json(tripID), "p_participant_id": Self.json(participantID), "p_display_name": .string(name)])
    }

    func renameParticipant(_ participantID: ParticipantID, name: String) async throws -> Trip {
        try await rpc("rename_participant", ["p_participant_id": Self.json(participantID), "p_display_name": .string(name)])
    }

    func createInvite(tripID: TripID, role: TripRole, expiresInHours: Int, maxUses: Int, participantID: ParticipantID?) async throws -> TripInvite {
        try await rpc("create_invite", ["p_trip_id": Self.json(tripID), "p_role": .string(role.rawValue), "p_expires_in_hours": .integer(Int64(expiresInHours)),
                                        "p_max_uses": .integer(Int64(maxUses)), "p_participant_id": Self.json(participantID)])
    }

    func revokeInvite(_ inviteID: UUID) async throws { try await rpcVoid("revoke_invite", ["p_invite_id": Self.json(inviteID)]) }

    private struct InviteError: Decodable { var error: String? }

    private func inviteRPC<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let data: Data = try await call { try await client.rpc(name, params: params).execute().data }
        if let failure = try? JSONCoding.decoder.decode(InviteError.self, from: data), let code = failure.error {
            throw AppError.invite(AppError.InviteFailure(rawValue: code) ?? .invalid)
        }
        do { return try JSONCoding.decoder.decode(T.self, from: data) } catch { throw AppError.server(message: nil) }
    }

    func previewInvite(secret: String) async throws -> InvitePreview { try await inviteRPC("preview_invite", ["p_secret": .string(secret)]) }

    func acceptInvite(secret: String, claimParticipantID: ParticipantID?) async throws -> Trip {
        try await inviteRPC("accept_invite", ["p_secret": .string(secret), "p_claim_participant_id": Self.json(claimParticipantID)])
    }

    func setMemberRole(tripID: TripID, userID: UserID, role: TripRole) async throws -> Trip {
        try await rpc("set_member_role", ["p_trip_id": Self.json(tripID), "p_user_id": Self.json(userID), "p_role": .string(role.rawValue)])
    }

    func removeMember(tripID: TripID, userID: UserID) async throws -> Trip {
        try await rpc("remove_member", ["p_trip_id": Self.json(tripID), "p_user_id": Self.json(userID)])
    }

    func transferOwnership(tripID: TripID, to userID: UserID) async throws -> Trip {
        try await rpc("transfer_ownership", ["p_trip_id": Self.json(tripID), "p_new_owner_id": Self.json(userID)])
    }

    func leaveTrip(_ tripID: TripID, acknowledgeUnsettled: Bool) async throws {
        try await rpcVoid("leave_trip", ["p_trip_id": Self.json(tripID), "p_acknowledge_unsettled": .bool(acknowledgeUnsettled)])
    }

    // MARK: LedgerService

    func fetchExpenses(tripID: TripID, updatedAfter: Date?, afterID: ExpenseID?, limit: Int) async throws -> ExpensePage {
        let expenses: [Expense] = try await rpc("list_expenses", ["p_trip_id": Self.json(tripID), "p_updated_after": Self.json(updatedAfter),
                                                                  "p_after_id": Self.json(afterID), "p_limit": .integer(Int64(limit))])
        return ExpensePage(expenses: expenses, hasMore: expenses.count >= limit)
    }

    private func payloadValue(_ data: Data) throws -> JSONValue {
        do { return try JSONValue.decoding(data) } catch { throw AppError.validation(code: "malformed_payload", message: nil) }
    }

    func createExpense(tripID: TripID, payload: Data) async throws -> Expense {
        try await rpc("create_expense", ["p_trip_id": Self.json(tripID), "p_payload": try payloadValue(payload)])
    }

    func updateExpense(id: ExpenseID, expectedRevision: Int, payload: Data) async throws -> Expense {
        try await rpc("update_expense", ["p_expense_id": Self.json(id), "p_expected_revision": .integer(Int64(expectedRevision)), "p_payload": try payloadValue(payload)])
    }

    func deleteExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense {
        try await rpc("delete_expense", ["p_expense_id": Self.json(id), "p_expected_revision": .integer(Int64(expectedRevision))])
    }

    func restoreExpense(id: ExpenseID, expectedRevision: Int) async throws -> Expense {
        try await rpc("restore_expense", ["p_expense_id": Self.json(id), "p_expected_revision": .integer(Int64(expectedRevision))])
    }

    func fetchSettlements(tripID: TripID) async throws -> [Settlement] { try await rpc("list_settlements", ["p_trip_id": Self.json(tripID)]) }

    func recordSettlement(tripID: TripID, payload: Data) async throws -> Settlement {
        try await rpc("record_settlement", ["p_trip_id": Self.json(tripID), "p_payload": try payloadValue(payload)])
    }

    func deleteSettlement(id: UUID, expectedRevision: Int) async throws -> Settlement {
        try await rpc("delete_settlement", ["p_settlement_id": Self.json(id), "p_expected_revision": .integer(Int64(expectedRevision))])
    }

    func fetchBalances(tripID: TripID) async throws -> [ServerBalance] { try await rpc("trip_balances", ["p_trip_id": Self.json(tripID)]) }

    func fetchSuggestedSettlements(tripID: TripID) async throws -> [SuggestedTransfer] {
        try await rpc("suggested_settlements", ["p_trip_id": Self.json(tripID)])
    }

    func fetchSummary(tripID: TripID) async throws -> TripSummary? { try await rpc("trip_summary", ["p_trip_id": Self.json(tripID)]) }

    func fetchActivity(tripID: TripID, beforeID: Int64?, limit: Int) async throws -> [ActivityEvent] {
        try await rpc("list_activity", ["p_trip_id": Self.json(tripID), "p_before_id": Self.json(beforeID), "p_limit": .integer(Int64(limit))])
    }

    // MARK: ReceiptService

    private static let bucket = "receipts"

    func uploadReceipt(_ receipt: PreparedReceipt, tripID: TripID) async throws -> ReceiptRegistration {
        let path = "\(tripID.sortKey)/\(receipt.id.sortKey).\(receipt.fileExtension)"
        try await call {
            do {
                try await client.storage.from(Self.bucket).upload(path, data: receipt.data, options: FileOptions(cacheControl: "3600", contentType: receipt.mimeType, upsert: false))
            } catch let error as StorageError where error.statusCode == "409" || error.message.localizedCaseInsensitiveContains("exists") {
                // Retried upload of the same object: fine, registration below is idempotent.
            }
        }
        struct Registration: Decodable { var receipt: Receipt; var duplicates: [ReceiptDuplicate] }
        let registration: Registration = try await rpc("register_receipt", ["p_payload": .object([
            "id": Self.json(receipt.id), "trip_id": Self.json(tripID), "object_path": .string(path), "mime_type": .string(receipt.mimeType),
            "byte_size": .integer(Int64(receipt.data.count)), "width": receipt.width.map { .integer(Int64($0)) } ?? .null,
            "height": receipt.height.map { .integer(Int64($0)) } ?? .null, "sha256": .string(receipt.sha256),
            "perceptual_hash": Self.json(receipt.perceptualHash),
        ])])
        return ReceiptRegistration(receipt: registration.receipt, duplicates: registration.duplicates)
    }

    func scanReceipt(id: UUID) async throws -> ReceiptScanResult {
        let data: Data = try await call {
            try await client.functions.invoke("scan-receipt", options: FunctionInvokeOptions(body: ["receipt_id": id.uuidString.lowercased()])) { data, _ in data }
        }
        do { return try ScanResultValidator.decode(data) } catch { throw AppError.validation(code: "scan_invalid_output", message: nil) }
    }

    func fetchReceipts(tripID: TripID) async throws -> [Receipt] { try await rpc("list_receipts", ["p_trip_id": Self.json(tripID)]) }

    /// Short-lived signed URL (5 minutes) for viewing a private receipt.
    func signedURL(for receipt: Receipt) async throws -> URL {
        try await call { try await client.storage.from(Self.bucket).createSignedURL(path: receipt.objectPath, expiresIn: 300) }
    }

    func downloadReceipt(_ receipt: Receipt) async throws -> Data {
        try await call { try await client.storage.from(Self.bucket).download(path: receipt.objectPath) }
    }

    func deleteReceipt(_ receipt: Receipt) async throws {
        try await rpcVoid("delete_receipt", ["p_receipt_id": Self.json(receipt.id)])
        // Best effort immediate removal; the server-side cleanup queue guarantees eventual deletion.
        _ = try? await client.storage.from(Self.bucket).remove(paths: [receipt.objectPath])
    }

    // MARK: AccountService

    private func userID() async throws -> UserID {
        guard let id = await currentState().userID else { throw AppError.notAuthenticated }
        return id
    }

    func fetchProfile() async throws -> Profile {
        let id = try await userID()
        return try await call {
            try await client.from("profiles").select("id, display_name, avatar_emoji, default_currency, onboarded_at").eq("id", value: id).single().execute().value
        }
    }

    func updateProfile(displayName: String, avatarEmoji: String?, defaultCurrency: CurrencyCode) async throws -> Profile {
        try await updateProfile(displayName: displayName, avatarEmoji: avatarEmoji, defaultCurrency: Optional(defaultCurrency))
    }

    private func updateProfile(displayName: String, avatarEmoji: String?, defaultCurrency: CurrencyCode?) async throws -> Profile {
        let id = try await userID()
        var values: [String: JSONValue] = ["display_name": .string(String(displayName.prefix(60))), "onboarded_at": .string(PostgresDate.timestamp(Date()))]
        values["avatar_emoji"] = Self.json(avatarEmoji)
        if let defaultCurrency { values["default_currency"] = .string(defaultCurrency.rawValue) }
        return try await call {
            try await client.from("profiles").update(values).eq("id", value: id)
                .select("id, display_name, avatar_emoji, default_currency, onboarded_at").single().execute().value
        }
    }

    func fetchNotificationPreferences() async throws -> NotificationPreferences {
        let id = try await userID()
        let rows: [NotificationPreferences] = try await call {
            try await client.from("notification_preferences").select().eq("user_id", value: id).execute().value
        }
        return rows.first ?? NotificationPreferences()
    }

    func saveNotificationPreferences(_ preferences: NotificationPreferences) async throws {
        let id = try await userID()
        guard case .object(var values) = try JSONValue.encoding(preferences) else { return }
        values["user_id"] = Self.json(id)
        try await call { _ = try await client.from("notification_preferences").upsert(values, onConflict: "user_id").execute() }
    }

    func setTripMuted(_ tripID: TripID, muted: Bool) async throws {
        let id = try await userID()
        let values: [String: JSONValue] = ["user_id": Self.json(id), "trip_id": Self.json(tripID), "muted": .bool(muted)]
        try await call { _ = try await client.from("trip_notification_settings").upsert(values, onConflict: "user_id,trip_id").execute() }
    }

    func registerDevice(token: String, environment: String, bundleID: String, appVersion: String?) async throws {
        try await rpcVoid("register_device", ["p_token": .string(token), "p_environment": .string(environment), "p_bundle_id": .string(bundleID),
                                              "p_app_version": Self.json(appVersion), "p_locale": .string(Locale.current.identifier),
                                              "p_timezone": .string(TimeZone.current.identifier)])
    }

    func unregisterDevice(token: String) async throws { try await rpcVoid("unregister_device", ["p_token": .string(token)]) }

    func exportData() async throws -> Data {
        try await call { try await client.rpc("export_my_data").execute().data }
    }

    func deleteAccount(appleAuthorizationCode: String?) async throws {
        let body: [String: String] = appleAuthorizationCode.map { ["apple_authorization_code": $0] } ?? [:]
        try await call { try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(body: body)) }
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: ExchangeRateService

    func rate(from: CurrencyCode, to: CurrencyCode, on date: Date) async throws -> ExchangeRateQuote {
        try await call {
            try await client.functions.invoke("exchange-rates", options: FunctionInvokeOptions(body: [
                "base": from.rawValue, "quote": to.rawValue, "date": PostgresDate.day(date),
            ]), decoder: JSONCoding.decoder)
        }
    }

    // MARK: RealtimeService

    func changes(tripID: TripID) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let channel = client.channel("trip:\(tripID.sortKey)")
            let tables = ["expenses", "settlements", "trip_members", "trip_participants", "receipts", "activity_events"]
            let streams = tables.map { channel.postgresChange(AnyAction.self, schema: "public", table: $0, filter: .eq("trip_id", value: tripID.sortKey)) }
                + [channel.postgresChange(AnyAction.self, schema: "public", table: "trips", filter: .eq("id", value: tripID.sortKey))]
            let task = Task {
                await channel.subscribe()
                await withTaskGroup(of: Void.self) { group in
                    for stream in streams {
                        group.addTask { for await _ in stream { continuation.yield(()) } }
                    }
                }
            }
            continuation.onTermination = { [client] _ in
                task.cancel()
                Task { await client.removeChannel(channel) }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
