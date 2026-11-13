import Foundation
import Observation

/// Trip chat for all trips. Messages travel two ways and are merged by id:
/// - nearby phones over Bluetooth / peer Wi-Fi (instant, no internet), and
/// - Supabase (durable history, delivery when apart).
/// Your own messages stay "unsent" until the server confirms them; they retry automatically.
/// The on-device cache is just a cache — the server copy is the record.
@MainActor
@Observable
final class ChatStore {
    private(set) var byTrip: [TripID: [UUID: ChatMessage]] = [:]
    private(set) var unsent: Set<UUID> = []
    var userID: UserID?
    var displayName = ""

    private let service: any ChatService
    private let nearby: NearbyMesh?
    private let cacheURL: URL?

    init(service: any ChatService, nearby: NearbyMesh?, cacheURL: URL? = URL.applicationSupportDirectory.appending(path: "chat-cache.json")) {
        self.service = service
        self.nearby = nearby
        self.cacheURL = cacheURL
        loadCache()
        nearby?.onChat = { [weak self] message in self?.receiveNearby(message) }
    }

    func messages(for tripID: TripID) -> [ChatMessage] {
        (byTrip[tripID] ?? [:]).values.sorted { ($0.sentAt, $0.id.uuidString) < ($1.sentAt, $1.id.uuidString) }
    }

    func isMine(_ message: ChatMessage) -> Bool { message.senderId != nil && message.senderId == userID }

    // MARK: Sending

    @discardableResult
    func send(_ text: String, tripID: TripID) async -> ChatMessage? {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatMessage.maxLength))
        guard !body.isEmpty else { return nil }
        let message = ChatMessage(id: UUID(), tripId: tripID, senderId: userID, senderName: displayName.isEmpty ? "Me" : displayName,
                                  body: body, sentAt: Date(), createdAt: nil)
        insert(message)
        unsent.insert(message.id)
        saveCache()
        nearby?.broadcast(message)
        await upload(message)
        return message
    }

    /// Fetches server history and retries this trip's unsent messages.
    func refresh(tripID: TripID) async {
        await flush(tripID: tripID)
        do {
            let remote = try await service.listMessages(tripID: tripID)
            remote.forEach(insert)
            saveCache()
        } catch {
            Log.app.notice("Chat refresh failed: \(error.asAppError.title, privacy: .public)")
        }
    }

    /// Keeps a trip's chat live while the screen is open: realtime pushes plus a slow retry loop.
    func watch(tripID: TripID) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in self.service.messageChanges(tripID: tripID) { await self.refresh(tripID: tripID) }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    await self.flush(tripID: tripID)
                }
            }
        }
    }

    func flush(tripID: TripID) async {
        for id in unsent {
            guard let message = byTrip[tripID]?[id] else { continue }
            await upload(message)
        }
    }

    private func upload(_ message: ChatMessage) async {
        do {
            let stored = try await service.postMessage(message)
            unsent.remove(message.id)
            insert(stored)
            saveCache()
        } catch {
            // Offline or server error: stays unsent and retries later. Nearby phones already have it.
        }
    }

    // MARK: Receiving

    private func receiveNearby(_ message: ChatMessage) {
        guard byTrip[message.tripId]?[message.id] == nil else { return }
        var clean = message
        clean.body = String(clean.body.prefix(ChatMessage.maxLength))
        clean.senderName = String(clean.senderName.prefix(60))
        insert(clean)
        saveCache()
    }

    private func insert(_ message: ChatMessage) {
        byTrip[message.tripId, default: [:]][message.id] = message
    }

    // MARK: Cache

    private struct Cache: Codable { var messages: [ChatMessage]; var unsent: [UUID] }

    func wipe() {
        byTrip = [:]
        unsent = []
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    private func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        cache.messages.forEach(insert)
        unsent = Set(cache.unsent)
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let cache = Cache(messages: byTrip.values.flatMap(\.values), unsent: Array(unsent))
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }
}
