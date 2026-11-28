import Foundation

/// The fixed group this TestFlight build is for. Picking a name signs in anonymously and fills the profile.
struct CrewMember: Identifiable, Hashable, Sendable {
    let name: String
    let emoji: String
    var id: String { name }

    /// The one hard-coded trip (seeded by migration 20261113000300_crew_trip.sql).
    static let tripID = UUID(uuidString: "c0ffee00-2026-4000-8000-00000000c0de")!

    static let all: [CrewMember] = [
        CrewMember(name: "Asray", emoji: "🌴"),
        CrewMember(name: "Anoop", emoji: "🏝️"),
        CrewMember(name: "Arjun", emoji: "🍹"),
        CrewMember(name: "Justin", emoji: "🤿"),
    ]
}
