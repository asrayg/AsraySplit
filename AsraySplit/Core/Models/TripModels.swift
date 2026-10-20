import Foundation

typealias TripID = UUID
typealias ParticipantID = UUID
typealias UserID = UUID

struct Profile: Codable, Equatable, Sendable, Identifiable {
    var id: UserID
    var displayName: String
    var avatarEmoji: String?
    var defaultCurrency: CurrencyCode
    var onboardedAt: Date?
}

enum TripRole: String, Codable, Sendable, Comparable {
    case owner, admin, member

    var rank: Int { switch self { case .owner: 3; case .admin: 2; case .member: 1 } }
    static func < (lhs: TripRole, rhs: TripRole) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .member: String(localized: "Member")
        }
    }
}

enum MemberStatus: String, Codable, Sendable { case active, left, removed }

struct Participant: Identifiable, Codable, Hashable, Sendable {
    var id: ParticipantID
    var tripId: TripID
    var displayName: String
    var userId: UserID?
    var archivedAt: Date?

    var isGuest: Bool { userId == nil }
    var initials: String {
        displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct TripMember: Codable, Hashable, Sendable {
    var tripId: TripID
    var userId: UserID
    var participantId: ParticipantID
    var role: TripRole
    var status: MemberStatus
    var joinedAt: Date
}

struct Trip: Identifiable, Codable, Hashable, Sendable {
    var id: TripID
    var ownerId: UserID?
    var name: String
    var emoji: String
    var colorHex: String
    var startDate: Date?
    var endDate: Date?
    var timezone: String
    var baseCurrency: CurrencyCode
    var budgetMinor: Int64?
    var revision: Int
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var myRole: TripRole?
    var participants: [Participant]
    var members: [TripMember]

    var isArchived: Bool { archivedAt != nil }
    var activeParticipants: [Participant] { participants.filter { $0.archivedAt == nil } }
    var activeMembers: [TripMember] { members.filter { $0.status == .active } }
    var budget: Money? { budgetMinor.map { Money(minorUnits: $0, currency: baseCurrency) } }

    func participant(_ id: ParticipantID?) -> Participant? { participants.first { $0.id == id } }
    func participant(forUser userID: UserID?) -> Participant? {
        guard let userID else { return nil }
        return participants.first { $0.userId == userID }
    }
    func name(of id: ParticipantID?) -> String { participant(id)?.displayName ?? String(localized: "Former traveler") }
    func canManage(_ role: TripRole = .admin) -> Bool { (myRole ?? .member) >= role }

    /// "Today" for this trip, respecting the trip time zone.
    func isActive(on date: Date = .now) -> Bool {
        guard let startDate, let endDate else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = PostgresDate.parse(PostgresDate.day(date)) ?? date
        return day >= calendar.startOfDay(for: startDate) && day <= calendar.startOfDay(for: endDate)
    }
}

struct TripDraft: Equatable, Sendable {
    var id = UUID()
    var name = ""
    var emoji = "✈️"
    var colorHex = "23C58A"
    var startDate: Date? = .now
    var endDate: Date? = .now.addingTimeInterval(7 * 86_400)
    var timezone = TimeZone.current.identifier
    var baseCurrency: CurrencyCode = CurrencyCode(Locale.current.currency?.identifier ?? "USD") ?? .usd
    var budgetMinor: Int64?
    var guestNames: [String] = []

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool {
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else { return false }
        if let startDate, let endDate, endDate < startDate { return false }
        return true
    }

    init() {}

    init(trip: Trip) {
        id = trip.id
        name = trip.name
        emoji = trip.emoji
        colorHex = trip.colorHex
        startDate = trip.startDate
        endDate = trip.endDate
        timezone = trip.timezone
        baseCurrency = trip.baseCurrency
        budgetMinor = trip.budgetMinor
    }
}

struct TripInvite: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var tripId: TripID
    var token: String
    var code: String
    var role: TripRole
    var expiresAt: Date
    var maxUses: Int

    /// Formatted for reading aloud: ABCD-EFGH.
    var displayCode: String { code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code }
}

struct InvitePreview: Codable, Equatable, Sendable {
    struct Claimable: Codable, Equatable, Sendable, Identifiable { var id: ParticipantID; var displayName: String }
    var tripId: TripID
    var name: String
    var emoji: String
    var startDate: Date?
    var endDate: Date?
    var baseCurrency: CurrencyCode
    var role: TripRole
    var expiresAt: Date
    var invitedBy: String?
    var memberCount: Int
    var alreadyMember: Bool
    var exhausted: Bool
    var reservedParticipantId: ParticipantID?
    var claimableParticipants: [Claimable]
}
