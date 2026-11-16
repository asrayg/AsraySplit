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
    /// Edits/deletes of my messages that the server hasn't confirmed yet (newest local version).
    private(set) var pendingChanges: [UUID: ChatMessage] = [:]
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
        (byTrip[tripID] ?? [:]).values.filter { $0.deletedAt == nil }.sorted { ($0.sentAt, $0.id.uuidString) < ($1.sentAt, $1.id.uuidString) }
    }

    func isMine(_ message: ChatMessage) -> Bool { message.senderId != nil && message.senderId == userID }

    // MARK: Unread

    private(set) var lastRead: [TripID: Date] = (UserDefaults.standard.dictionary(forKey: "chat.lastRead") as? [String: Double] ?? [:])
        .reduce(into: [:]) { result, item in if let id = UUID(uuidString: item.key) { result[id] = Date(timeIntervalSince1970: item.value) } }

    func unreadCount(for tripID: TripID) -> Int {
        let since = lastRead[tripID] ?? .distantPast
        return (byTrip[tripID] ?? [:]).values.filter { !isMine($0) && $0.deletedAt == nil && $0.sentAt > since }.count
    }

    func markRead(_ tripID: TripID) {
        lastRead[tripID] = Date()
        UserDefaults.standard.set(lastRead.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 }, forKey: "chat.lastRead")
    }

    // MARK: Sending

    @discardableResult
    func send(_ text: String, tripID: TripID, announce: Bool = false) async -> ChatMessage? {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatMessage.maxLength))
        guard !body.isEmpty else { return nil }
        let message = ChatMessage(id: UUID(), tripId: tripID, senderId: userID, senderName: displayName.isEmpty ? "Me" : displayName,
                                  body: body, sentAt: Date(), createdAt: nil, isAnnouncement: announce ? true : nil)
        insert(message)
        unsent.insert(message.id)
        saveCache()
        nearby?.broadcast(message)
        await upload(message)
        return message
    }

    // MARK: Editing

    func edit(_ message: ChatMessage, to text: String) async {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatMessage.maxLength))
        guard isMine(message), !body.isEmpty, body != message.body else { return }
        var changed = byTrip[message.tripId]?[message.id] ?? message
        changed.body = body
        changed.editedAt = Date()
        await apply(changed)
    }

    func delete(_ message: ChatMessage) async {
        guard isMine(message) else { return }
        var changed = byTrip[message.tripId]?[message.id] ?? message
        changed.body = ""
        changed.deletedAt = Date()
        await apply(changed)
    }

    private func apply(_ changed: ChatMessage) async {
        byTrip[changed.tripId, default: [:]][changed.id] = changed
        nearby?.broadcast(changed)
        if unsent.contains(changed.id) {
            // Never reached the server: a delete just cancels the send; an edit goes out with the post.
            if changed.deletedAt != nil { unsent.remove(changed.id) }
        } else {
            pendingChanges[changed.id] = changed
        }
        saveCache()
        await flushChanges()
    }

    private func flushChanges() async {
        for (id, change) in pendingChanges {
            do {
                let stored = change.deletedAt != nil ? try await service.deleteMessage(id: id) : try await service.editMessage(id: id, body: change.body)
                if pendingChanges[id]?.version == change.version { pendingChanges[id] = nil }
                insert(stored)
            } catch let error as AppError where error == .notFound {
                pendingChanges[id] = nil
            } catch {
                // Offline: retried on the next flush.
            }
        }
        saveCache()
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
        await flushChanges()
        for id in unsent {
            guard let message = byTrip[tripID]?[id] else { continue }
            await upload(message)
        }
    }

    private func upload(_ message: ChatMessage) async {
        do {
            let stored = try await service.postMessage(message)
            unsent.remove(message.id)
            // Edited/deleted while the post was in flight: send that change next.
            if let local = byTrip[message.tripId]?[message.id], local.version > stored.version { pendingChanges[message.id] = local }
            insert(stored)
            saveCache()
        } catch {
            // Offline or server error: stays unsent and retries later. Nearby phones already have it.
        }
    }

    // MARK: Receiving

    private func receiveNearby(_ message: ChatMessage) {
        if let existing = byTrip[message.tripId]?[message.id], existing.version >= message.version { return }
        // Only the sender may change a message; ignore edits that claim someone else's message.
        if let existing = byTrip[message.tripId]?[message.id], existing.senderId != message.senderId { return }
        var clean = message
        clean.body = String(clean.body.prefix(ChatMessage.maxLength))
        clean.senderName = String(clean.senderName.prefix(60))
        insert(clean)
        saveCache()
    }

    /// Keeps whichever copy is newest, and never lets a server copy undo an edit that's still queued.
    private func insert(_ message: ChatMessage) {
        if let pending = pendingChanges[message.id], pending.version > message.version { return }
        if let existing = byTrip[message.tripId]?[message.id], existing.version > message.version { return }
        byTrip[message.tripId, default: [:]][message.id] = message
    }

    // MARK: Cache

    private struct Cache: Codable { var messages: [ChatMessage]; var unsent: [UUID]; var changes: [ChatMessage]? }

    func wipe() {
        byTrip = [:]
        unsent = []
        pendingChanges = [:]
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    private func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        cache.messages.forEach(insert)
        unsent = Set(cache.unsent)
        pendingChanges = Dictionary((cache.changes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let cache = Cache(messages: byTrip.values.flatMap(\.values), unsent: Array(unsent), changes: Array(pendingChanges.values))
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }
}
