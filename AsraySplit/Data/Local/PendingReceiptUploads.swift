import Foundation

/// A receipt image captured while offline, waiting for its expense to sync so it can be uploaded and
/// attached. Image bytes live in a protected file; metadata lives in the cache's key-value store.
struct PendingReceiptUpload: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { receiptId }
    // Property names avoid `ID` acronyms so snake_case coding round-trips.
    var receiptId: UUID
    var tripId: TripID
    var expenseId: ExpenseID
    var mimeType: String
    var fileExtension: String
    var width: Int?
    var height: Int?
    var sha256: String
    var perceptualHash: String?
    var attempts = 0

    static let storeKey = "pending-receipt-uploads"

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "PendingReceipts", directoryHint: .isDirectory)
    }

    var fileURL: URL { Self.directory.appending(path: "\(receiptId.uuidString).\(fileExtension)") }

    init(prepared: PreparedReceipt, tripId: TripID, expenseId: ExpenseID) {
        receiptId = prepared.id
        self.tripId = tripId
        self.expenseId = expenseId
        mimeType = prepared.mimeType
        fileExtension = prepared.fileExtension
        width = prepared.width
        height = prepared.height
        sha256 = prepared.sha256
        perceptualHash = prepared.perceptualHash
    }

    func prepared() throws -> PreparedReceipt {
        PreparedReceipt(id: receiptId, data: try Data(contentsOf: fileURL), mimeType: mimeType, fileExtension: fileExtension,
                        width: width, height: height, sha256: sha256, perceptualHash: perceptualHash)
    }
}
