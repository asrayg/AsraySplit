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

    static let maxLength = 2000
}
