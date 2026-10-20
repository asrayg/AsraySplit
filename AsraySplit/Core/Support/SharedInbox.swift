import Foundation

/// Hand-off between the Share Extension and the app through the App Group container.
/// The extension only writes files; all parsing, uploading and saving happens in the app.
/// Compiled into both the app and the AsraySplitShare extension.
struct SharedTripSummary: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var emoji: String
}

struct SharedInboxItem: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var tripId: UUID?
    var createdAt: Date
    var fileName: String?
    var contentType: String?
    var text: String?
}

struct SharedInbox {
    static let maxFileBytes = 25 * 1024 * 1024
    let root: URL

    /// The App Group identifier comes from Info.plist (`AppGroupIdentifier`), which differs per build configuration.
    static var appGroupIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    /// Nil when the App Group isn't available (e.g. unsigned builds).
    static func shared() -> SharedInbox? {
        guard let id = appGroupIdentifier, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return SharedInbox(root: url.appending(path: "Inbox", directoryHint: .isDirectory))
    }

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var indexURL: URL { root.appending(path: "items.json") }
    private var tripsURL: URL { root.appending(path: "trips.json") }

    private static let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }()
    private static let decoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()

    func items() -> [SharedInboxItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return ((try? Self.decoder.decode([SharedInboxItem].self, from: data)) ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private func save(_ items: [SharedInboxItem]) throws {
        try Self.encoder.encode(items).write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func add(data: Data?, fileExtension: String?, contentType: String?, text: String?, tripId: UUID?, now: Date = Date()) throws -> SharedInboxItem {
        var item = SharedInboxItem(id: UUID(), tripId: tripId, createdAt: now, fileName: nil, contentType: contentType,
                                   text: text.map { String($0.prefix(20_000)) })
        if let data {
            guard data.count <= Self.maxFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let name = "\(item.id.uuidString).\(fileExtension ?? "bin")"
            try data.write(to: root.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            item.fileName = name
        }
        try save(items() + [item])
        return item
    }

    func data(for item: SharedInboxItem) -> Data? {
        item.fileName.flatMap { try? Data(contentsOf: root.appending(path: $0)) }
    }

    func remove(_ item: SharedInboxItem) {
        if let name = item.fileName { try? FileManager.default.removeItem(at: root.appending(path: name)) }
        try? save(items().filter { $0.id != item.id })
    }

    /// Trip names the extension can offer, written by the app whenever trips change. No financial data.
    func writeTrips(_ trips: [SharedTripSummary]) {
        try? Self.encoder.encode(trips).write(to: tripsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func trips() -> [SharedTripSummary] {
        guard let data = try? Data(contentsOf: tripsURL) else { return [] }
        return (try? Self.decoder.decode([SharedTripSummary].self, from: data)) ?? []
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
