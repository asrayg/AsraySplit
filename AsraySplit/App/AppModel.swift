import Foundation
import Observation
import SwiftUI

enum Route: Hashable {
    case trip(TripID)
    case expense(TripID, ExpenseID)
    case balances(TripID)
    case tripSettings(TripID)
    case activity(TripID)
    case receipts(TripID)
}

enum SheetRoute: Identifiable, Equatable {
    case join(secret: String)
    case createTrip
    case addExpense(TripID)
    case scanReceipt(TripID?)
    case settleUp(TripID, SuggestedTransfer?)

    var id: String {
        switch self {
        case .join(let secret): "join-\(secret)"
        case .createTrip: "create-trip"
        case .addExpense(let trip): "add-\(trip)"
        case .scanReceipt(let trip): "scan-\(trip?.uuidString ?? "")"
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
            if previous != nil { await env.store.wipeLocalData() }
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
            await env.store.start()
            await env.notifications.refreshAuthorization()
            if let link = pendingLink { pendingLink = nil; open(link) }
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
