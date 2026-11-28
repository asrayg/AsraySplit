import Foundation

/// One photo in a trip's shared album. The id is created on the phone that added it, so copies received
/// over Bluetooth and from the server line up.
struct TripPhoto: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let tripId: TripID
    var uploaderId: UserID?
    var uploaderName: String
    var width: Int
    var height: Int
    var byteSize: Int
    var takenAt: Date?
    var createdAt: Date?

    var objectPath: String { "\(tripId.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg" }
    var sortDate: Date { takenAt ?? createdAt ?? .distantPast }

    /// Limits shared with the `trip-photos` bucket and `register_trip_photo`.
    static let maxBytes = 15 * 1024 * 1024
    static let maxDimension = 2048
}
