import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case trip(TripID)
    case expense(TripID, ExpenseID)
    case balances(TripID)
    case tripSettings(TripID)
    case activity(TripID)
    case receipts(TripID)
    case chat(TripID)
    case photos(TripID)
}

enum SheetRoute: Identifiable, Equatable {
    case join(secret: String)
    case createTrip
    case addExpense(TripID)
    case scanReceipt(TripID?)
    /// Opens the review for a scan job already started (e.g. an item shared from another app).
    case reviewScan(TripID, jobID: UUID)
    case settleUp(TripID, SuggestedTransfer?)

    var id: String {
        switch self {
        case .join(let secret): "join-\(secret)"
        case .createTrip: "create-trip"
        case .addExpense(let trip): "add-\(trip)"
        case .scanReceipt(let trip): "scan-\(trip?.uuidString ?? "")"
        case .reviewScan(let trip, let job): "review-\(trip)-\(job)"
        case .settleUp(let trip, let transfer): "settle-\(trip)-\(transfer?.id ?? "")"
        }
    }
}

struct Toast: Equatable, Identifiable {
    enum Style { case info, success, warning }
    let id = UUID()
    var message: String
    var style: Style = .info
    var undo: (@MainActor () async -> Void)?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Session, routing and app-level side effects. Feature state lives in feature models.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, needsProfile, ready }

    private(set) var phase: Phase = .launching
    private(set) var profile: Profile?
    private(set) var authState: AuthState = .unknown
    var path: [Route] = []
    var sheet: SheetRoute?
    var toast: Toast?
    var presentedError: AppError?
    private(set) var isDemo = false

    let env: AppEnvironment
    var store: TripStore { env.store }
    private var authTask: Task<Void, Never>?
    private var pendingLink: DeepLink?
    /// Set while a crew sign-in is in flight so the profile is filled without the setup form.
    private var pendingCrew: CrewMember?

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        guard authTask == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            Task { await enterDemoMode(seeded: !ProcessInfo.processInfo.arguments.contains("-emptyDemo")) }
        }
        let stream = env.backend.auth.stateChanges()
        authTask = Task { [weak self] in
            for await state in stream {
                await self?.apply(state)
            }
        }
        env.notifications.onOpen = { [weak self] link in self?.open(link) }
        env.notifications.onToken = { [weak self] token in
            guard let self else { return }
            Task { try? await self.env.backend.account.registerDevice(token: token, environment: self.env.config.apnsEnvironment,
                                                                      bundleID: Bundle.main.bundleIdentifier ?? "", appVersion: Bundle.main.appVersion) }
        }
    }

    private func apply(_ state: AuthState) async {
        let previous = authState.userID
        authState = state
        switch state {
        case .unknown:
            phase = .launching
        case .signedOut:
            if previous != nil { await env.store.wipeLocalData(); env.chat.wipe(); env.photos.wipe() }
            env.nearby.stop()
            profile = nil
            env.store.currentUserID = nil
            phase = .signedOut
        case .signedIn(let userID, _):
            guard previous != userID else { return }
            if let previous, previous != userID { await env.store.wipeLocalData() }
            env.store.currentUserID = userID
            profile = try? await env.store.local.value(Profile.self, forKey: "profile")
            do {
                let fresh = try await env.backend.account.fetchProfile()
                profile = fresh
                try? await env.store.local.setValue(fresh, forKey: "profile")
            } catch {
                Log.auth.error("Profile fetch failed: \(error.asAppError.title, privacy: .public)")
            }
            phase = (profile?.onboardedAt == nil && !isDemo) ? .needsProfile : .ready
            if phase == .needsProfile, let crew = pendingCrew {
                pendingCrew = nil
                await completeProfile(name: crew.name, emoji: crew.emoji, currency: .usd)
            }
            await env.store.start()
            await env.notifications.refreshAuthorization()
            if let preferences = try? await env.backend.account.fetchNotificationPreferences() {
                await env.notifications.scheduleDailyReminders(for: env.store.activeTrips, enabled: preferences.dailyReminder)
            }
            if let link = pendingLink { pendingLink = nil; open(link) }
            processSharedInbox()
        }
    }

    // MARK: Demo mode

    func enterDemoMode(seeded: Bool = true) async {
        guard let demo = env.demoBackend else {
            presentedError = .notConfigured
            return
        }
        isDemo = true
        if seeded { await DemoData.seed(demo.server) }
        await demo.signInDemo()
    }

    // MARK: Crew trip

    private(set) var crewJoinError: String?

    /// Links this account to its person on the built-in Puerto Rico trip, then syncs. Idempotent.
    func joinCrewTrip() async {
        guard phase == .ready, let name = UserDefaults.standard.string(forKey: Self.crewNameKey) ?? profile?.displayName else { return }
        crewJoinError = nil
        do {
            _ = try await env.backend.trips.joinCrewTrip(name: name)
            await store.syncNow()
        } catch {
            // Offline with a cached trip is fine; only surface the error when there's nothing to show.
            if store.trip(CrewMember.tripID) == nil { crewJoinError = error.asAppError.message }
        }
    }

    // MARK: Nearby phones

    /// Starts Bluetooth/peer Wi-Fi once signed in. Phones with Apple Intelligence offer to read receipts for others.
    func startNearby() {
        guard phase == .ready, let userID = authState.userID else { return }
        let name = profile?.displayName ?? "Phone"
        env.chat.userID = userID
        env.chat.displayName = name
        env.photos.userID = userID
        env.photos.displayName = name
        env.photos.knownTrips = { [weak self] in Set(self?.store.trips.map(\.trip.id) ?? []) }
        env.photos.scheduleOvernightSync()
        guard !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }
        if OnDeviceReceiptAI.isAvailable {
            env.nearby.parseHandler = { lines, currency in await OnDeviceReceiptAI.structure(lines: lines, currency: currency) }
        }
        if env.nearby.isRunning { env.nearby.stop() }   // restart so peers see the current name
        env.nearby.start(displayName: name)
    }

    // MARK: Crew sign-in

    static let crewNameKey = "crew.name"

    func signIn(as crew: CrewMember) async {
        UserDefaults.standard.set(crew.name, forKey: Self.crewNameKey)
        pendingCrew = crew
        do { try await env.backend.auth.signInAnonymously() } catch {
            pendingCrew = nil
            presentedError = error.asAppError
        }
    }

    // MARK: Profile

    func completeProfile(name: String, emoji: String?, currency: CurrencyCode) async {
        do {
            let updated = try await env.backend.account.updateProfile(displayName: name, avatarEmoji: emoji, defaultCurrency: currency)
            profile = updated
            try? await env.store.local.setValue(updated, forKey: "profile")
            phase = .ready
        } catch {
            presentedError = error.asAppError
        }
    }

    // MARK: Links

    func handle(url: URL) {
        if url.scheme == "asraysplit", url.host == "auth-callback" {
            Task {
                do { _ = try await env.backend.auth.handleAuthCallback(url) } catch { presentedError = error.asAppError }
            }
            return
        }
        guard let link = DeepLink.parse(url, inviteHost: env.config.inviteHost) else {
            show(Toast(message: String(localized: "That link isn’t supported."), style: .warning))
            return
        }
        open(link)
    }

    func open(_ link: DeepLink) {
        guard phase == .ready else { pendingLink = link; return }
        switch link {
        case .join(let secret):
            sheet = .join(secret: secret)
        case .trip(let trip):
            path = [.trip(trip)]
        case .expense(let trip, let expense):
            path = [.trip(trip), .expense(trip, expense)]
        case .balances(let trip):
            path = [.trip(trip), .balances(trip)]
        case .authCallback(let url):
            handle(url: url)
        }
    }

    // MARK: Shared items (Share Extension)

    /// Imports the oldest item shared from another app (receipt photo, PDF or Uber/Lyft receipt text)
    /// and opens its review. Called when the app becomes active.
    func processSharedInbox(inbox: SharedInbox? = SharedInbox.shared()) {
        guard phase == .ready, sheet == nil, let inbox, let item = inbox.items().first else { return }
        guard let trip = env.store.trip(item.tripId) ?? env.store.activeTrips.first else {
            show(Toast(message: String(localized: "Create a trip first, then share the receipt again."), style: .warning))
            return
        }
        defer { inbox.remove(item) }
        do {
            let jobID: UUID
            if let data = inbox.data(for: item) {
                jobID = try env.scanner.start(fileData: data, contentType: item.contentType.flatMap { UTType($0) }, trip: trip)
            } else if let text = item.text {
                jobID = try env.scanner.start(text: text, trip: trip)
            } else {
                return
            }
            sheet = .reviewScan(trip.id, jobID: jobID)
        } catch {
            show(Toast(message: (error as? LocalizedError)?.errorDescription ?? String(localized: "That shared item couldn’t be read."), style: .warning))
        }
    }

    // MARK: Feedback

    func show(_ toast: Toast) { self.toast = toast }
    func report(_ error: Error) {
        let appError = error.asAppError
        guard appError != .cancelled else { return }
        if appError == .offline { show(Toast(message: appError.message, style: .warning)) } else { presentedError = appError }
    }

    // MARK: Account

    /// Signs out after the caller has confirmed losing `unsyncedCount` pending changes.
    func signOut() async {
        if let token = env.notifications.deviceToken { try? await env.backend.account.unregisterDevice(token: token) }
        env.notifications.cancelAllLocal()
        do { try await env.backend.auth.signOut() } catch { Log.auth.error("Sign out failed; clearing local session anyway") }
        await env.store.wipeLocalData()
        isDemo = false
        path = []
        await apply(.signedOut)
    }

    func deleteAccount(appleAuthorizationCode: String?) async throws {
        try await env.backend.account.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
        env.notifications.cancelAllLocal()
        await env.store.wipeLocalData()
        isDemo = false
        path = []
        await apply(.signedOut)
    }
}

extension Bundle {
    var appVersion: String? {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return "\(version) (\(infoDictionary?["CFBundleVersion"] as? String ?? "0"))"
    }
}
