import Foundation

/// One trip chat message. The id is created on the sending phone, so the same message arriving over
/// Bluetooth and from the server is shown once.
struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let tripId: TripID
    var senderId: UserID?
    var senderName: String
    var body: String
    var sentAt: Date
    var createdAt: Date?
    /// Sent by Asray with the 📣 button; notifies everyone. Optional so older cached/peer messages decode.
    var isAnnouncement: Bool?

    static let maxLength = 2000
}

/// A crew member's last shared position.
struct MemberLocation: Codable, Hashable, Identifiable, Sendable {
    let tripId: TripID
    let userId: UserID
    var displayName: String
    var latitude: Double
    var longitude: Double
    var accuracyM: Double?
    var recordedAt: Date
    var id: UserID { userId }
}

extension ChatMessage {
    /// Location pins are ordinary messages whose body carries an Apple Maps link, so they travel over
    /// Bluetooth and the offline queue like any other message.
    static func locationBody(latitude: Double, longitude: Double, label: String) -> String {
        let q = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Here"
        return "📍 \(label)\nhttps://maps.apple.com/?ll=\(String(format: "%.6f", latitude)),\(String(format: "%.6f", longitude))&q=\(q)"
    }

    /// Coordinates if this message is a location pin.
    var pinnedCoordinate: (latitude: Double, longitude: Double)? {
        guard body.hasPrefix("📍"), let range = body.range(of: "ll=") else { return nil }
        let rest = body[range.upperBound...].prefix { $0 != "&" && !$0.isWhitespace }
        let parts = rest.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    var mapsURL: URL? { body.split(separator: "\n").last.flatMap { URL(string: String($0)) } }
}
