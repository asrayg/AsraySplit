import XCTest
@testable import AsraySplit

private final class FakeChatService: ChatService, @unchecked Sendable {
    var stored: [UUID: ChatMessage] = [:]
    var failPosts = false
    var postCount = 0

    func listMessages(tripID: TripID) async throws -> [ChatMessage] { stored.values.filter { $0.tripId == tripID } }
    func postMessage(_ message: ChatMessage) async throws -> ChatMessage {
        postCount += 1
        if failPosts { throw AppError.offline }
        if let existing = stored[message.id] { return existing }
        stored[message.id] = message
        return message
    }
    func messageChanges(tripID: TripID) -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private let trip = UUID()

    func testSendStoresOnServerAndClearsUnsent() async {
        let service = FakeChatService()
        let store = ChatStore(service: service, nearby: nil, cacheURL: nil)
        store.userID = UUID(); store.displayName = "Asray"
        let sent = await store.send("  hola  ", tripID: trip)
        XCTAssertEqual(sent?.body, "hola")
        XCTAssertTrue(store.unsent.isEmpty)
        XCTAssertEqual(service.stored.count, 1)
        XCTAssertTrue(store.isMine(store.messages(for: trip)[0]))
    }

    func testBlankMessageIsIgnored() async {
        let store = ChatStore(service: FakeChatService(), nearby: nil, cacheURL: nil)
        let sent = await store.send("   ", tripID: trip)
        XCTAssertNil(sent)
        XCTAssertTrue(store.messages(for: trip).isEmpty)
    }

    func testOfflineMessageStaysUnsentAndRetries() async {
        let service = FakeChatService()
        service.failPosts = true
        let store = ChatStore(service: service, nearby: nil, cacheURL: nil)
        store.userID = UUID()
        let sent = await store.send("offline", tripID: trip)
        XCTAssertEqual(store.unsent, [sent!.id])

        service.failPosts = false
        await store.refresh(tripID: trip)
        XCTAssertTrue(store.unsent.isEmpty)
        XCTAssertEqual(store.messages(for: trip).count, 1, "server copy merges with the local one by id")
    }

    func testServerRefreshDoesNotDuplicate() async {
        let service = FakeChatService()
        let store = ChatStore(service: service, nearby: nil, cacheURL: nil)
        store.userID = UUID()
        await store.send("one", tripID: trip)
        await store.refresh(tripID: trip)
        await store.refresh(tripID: trip)
        XCTAssertEqual(store.messages(for: trip).count, 1)
    }

    func testCachePersistsAcrossLaunches() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "chat-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = FakeChatService()
        service.failPosts = true
        let first = ChatStore(service: service, nearby: nil, cacheURL: url)
        first.userID = UUID()
        await first.send("saved", tripID: trip)

        let second = ChatStore(service: service, nearby: nil, cacheURL: url)
        XCTAssertEqual(second.messages(for: trip).map(\.body), ["saved"])
        XCTAssertEqual(second.unsent.count, 1)
    }
}

final class LocationPinTests: XCTestCase {
    func testPinRoundTrips() throws {
        let body = ChatMessage.locationBody(latitude: 18.4655, longitude: -66.1057, label: "Asray is here")
        let message = ChatMessage(id: UUID(), tripId: UUID(), senderId: nil, senderName: "Asray", body: body, sentAt: Date())
        let pin = try XCTUnwrap(message.pinnedCoordinate)
        XCTAssertEqual(pin.latitude, 18.4655, accuracy: 0.000001)
        XCTAssertEqual(pin.longitude, -66.1057, accuracy: 0.000001)
        XCTAssertEqual(message.mapsURL?.host, "maps.apple.com")
    }

    func testPlainTextIsNotAPin() {
        let message = ChatMessage(id: UUID(), tripId: UUID(), senderId: nil, senderName: "A", body: "📍 meet at ll=999,999", sentAt: Date())
        XCTAssertNil(message.pinnedCoordinate)
    }
}
