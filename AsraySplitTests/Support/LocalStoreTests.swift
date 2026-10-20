import XCTest
@testable import AsraySplit

final class LocalStoreTests: XCTestCase {
    func testRoundTripsTripAndOutbox() async throws {
        let store = LocalStore.ephemeral()
        let trip = makeTrip()
        try await store.saveTrip(trip)
        let loaded = try await store.trip(trip.id)
        XCTAssertEqual(loaded?.trip.name, "Test")
        let op = OutboxOperation(tripID: trip.id, entityID: UUID(), kind: .createExpense, payload: Data("{}".utf8), createdAt: .now, nextAttemptAt: .now)
        try await store.enqueue(op)
        let count = try await store.unsyncedOperationCount()
        XCTAssertEqual(count, 1)
        try await store.wipe()
        let after = try await store.trips()
        XCTAssertTrue(after.isEmpty)
    }

    func testTwoIndependentStores() async throws {
        let a = LocalStore.ephemeral()
        let b = LocalStore.ephemeral()
        try await a.saveTrip(makeTrip())
        let bTrips = try await b.trips()
        XCTAssertTrue(bTrips.isEmpty)
    }
}
