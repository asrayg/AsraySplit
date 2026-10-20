import Foundation

/// Every URL the app understands. Parsing is pure and unit tested.
///
/// - https://<invite-host>/join/<token>   universal link (installed app) / web fallback (not installed)
/// - asraysplit://join/<token-or-code>
/// - asraysplit://trip/<trip-id>
/// - asraysplit://trip/<trip-id>/expense/<expense-id>
/// - asraysplit://trip/<trip-id>/balances
/// - asraysplit://auth-callback?...       magic-link completion (handled by AuthService)
enum DeepLink: Equatable, Sendable {
    case join(secret: String)
    case trip(TripID)
    case expense(TripID, ExpenseID)
    case balances(TripID)
    case authCallback(URL)

    static func parse(_ url: URL, inviteHost: String) -> DeepLink? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parts: [String]
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard url.host?.lowercased() == inviteHost.lowercased() || url.host?.lowercased() == "www.\(inviteHost.lowercased())" else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        case "asraysplit":
            if url.host == "auth-callback" { return .authCallback(url) }
            parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        default:
            return nil
        }
        parts = parts.map { $0.removingPercentEncoding ?? $0 }
        guard let head = parts.first?.lowercased() else { return nil }
        switch head {
        case "join":
            if parts.count >= 2, isValidSecret(parts[1]) { return .join(secret: parts[1]) }
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, isValidSecret(code) { return .join(secret: code) }
            return nil
        case "trip":
            guard parts.count >= 2, let trip = UUID(uuidString: parts[1]) else { return nil }
            if parts.count >= 4, parts[2] == "expense", let expense = UUID(uuidString: parts[3]) { return .expense(trip, expense) }
            if parts.count >= 3, parts[2] == "balances" { return .balances(trip) }
            return .trip(trip)
        default:
            return nil
        }
    }

    /// Invite link tokens are base64url (32 chars); short codes are 8 chars (dashes allowed).
    static func isValidSecret(_ value: String) -> Bool {
        let cleaned = value.replacingOccurrences(of: "-", with: "")
        guard (8...64).contains(cleaned.count) else { return false }
        return cleaned.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func inviteURL(token: String, host: String) -> URL {
        URL(string: "https://\(host)/join/\(token)")!
    }

    static func url(for link: DeepLink) -> URL? {
        switch link {
        case .join(let secret): URL(string: "asraysplit://join/\(secret)")
        case .trip(let trip): URL(string: "asraysplit://trip/\(trip.sortKey)")
        case .expense(let trip, let expense): URL(string: "asraysplit://trip/\(trip.sortKey)/expense/\(expense.sortKey)")
        case .balances(let trip): URL(string: "asraysplit://trip/\(trip.sortKey)/balances")
        case .authCallback(let url): url
        }
    }

    /// Notification payloads carry identifiers only (see private.enqueue_push_jobs).
    static func fromNotification(_ userInfo: [AnyHashable: Any]) -> DeepLink? {
        guard let tripString = userInfo["trip_id"] as? String, let trip = UUID(uuidString: tripString) else { return nil }
        let kind = userInfo["kind"] as? String ?? ""
        if kind.hasPrefix("expense_"), let entity = (userInfo["entity_id"] as? String).flatMap(UUID.init(uuidString:)) {
            return .expense(trip, entity)
        }
        if kind.hasPrefix("settlement_") { return .balances(trip) }
        return .trip(trip)
    }
}
