import XCTest
@testable import AsraySplit

final class RideReceiptParserTests: XCTestCase {
    let us = Locale(identifier: "en_US")
    let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

    func testUberReceipt() throws {
        let text = """
        Uber
        Total $23.45
        Thanks for riding, Alex
        Here's your receipt for your ride, October 19
        Trip fare $18.20
        Subtotal $18.20
        Booking Fee $2.75
        Tolls, Surcharges, and Fees $1.50
        Promotion -$2.00
        Tip $3.00
        Payments
        Visa ••••1234 $23.45
        UberX 5.12 miles | 18 min
        10:02 PM 123 Main St, San Francisco, CA
        10:20 PM 500 Market St, San Francisco, CA
        """
        let (result, ride) = try XCTUnwrap(RideReceiptParser.parse(text, currency: .usd, locale: us, now: now))
        XCTAssertEqual(ride.provider, .uber)
        XCTAssertEqual(ride.product, "UberX")
        XCTAssertEqual(ride.pickup, "123 Main St, San Francisco, CA")
        XCTAssertEqual(ride.dropoff, "500 Market St, San Francisco, CA")
        XCTAssertEqual(ride.distance, "5.12 miles")
        XCTAssertEqual(result.items.map(\.amountMinor), [1820])
        XCTAssertEqual(result.serviceFeeMinor, 425)
        XCTAssertEqual(result.tipMinor, 300)
        XCTAssertEqual(result.discountMinor, 200)
        XCTAssertEqual(result.totalMinor, 2345)
        XCTAssertTrue(ReceiptReconciler.isReconciled(result.totals), "fare + fees + tip − promo = total")
        XCTAssertEqual(result.ride, ride)
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: try XCTUnwrap(result.purchasedAt))
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 19)
        XCTAssertEqual(components.year, 2026)
    }

    func testLyftReceipt() throws {
        let text = """
        Lyft
        Thanks for riding with Jordan!
        October 19, 2026 at 10:02 PM
        Lyft fare (5.1mi, 18m 3s) $17.40
        Service fee $2.30
        Tip $3.00
        Visa *1234 $22.70
        Pickup 10:02 PM 123 Main St
        Drop-off 10:20 PM 500 Market St
        """
        let (result, ride) = try XCTUnwrap(RideReceiptParser.parse(text, currency: .usd, locale: us, now: now))
        XCTAssertEqual(ride.provider, .lyft)
        XCTAssertEqual(ride.driverName, "Jordan")
        XCTAssertEqual(ride.pickup, "123 Main St")
        XCTAssertEqual(ride.dropoff, "500 Market St")
        XCTAssertEqual(ride.distance, "5.1mi")
        XCTAssertEqual(result.items.first?.amountMinor, 1740)
        XCTAssertEqual(result.serviceFeeMinor, 230)
        XCTAssertEqual(result.tipMinor, 300)
        XCTAssertEqual(result.totalMinor, 2270, "computed when no total line is printed")
        XCTAssertTrue(ReceiptReconciler.isReconciled(result.totals))
    }

    func testFareDerivedFromTotalWhenNotItemized() throws {
        let text = "Your Uber trip\nThanks for riding\nTotal €31,40\nBooking fee €2,00\nTip €4,00"
        let (result, _) = try XCTUnwrap(RideReceiptParser.parse(text, currency: .eur, locale: Locale(identifier: "de_DE"), now: now))
        XCTAssertEqual(result.items.first?.amountMinor, 2540)
        XCTAssertTrue(ReceiptReconciler.isReconciled(result.totals))
    }

    func testIgnoresNonRideReceipts() {
        XCTAssertNil(RideReceiptParser.parse("CAFE MARGO\nLatte 5.50\nTotal 5.50", currency: .usd, locale: us))
        XCTAssertNil(RideReceiptParser.detect(["Uber Eats order", "Burrito $12.00"]))
    }
}

final class SharedInboxTests: XCTestCase {
    func testRoundTripsItemsAndTrips() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        let inbox = SharedInbox(root: root)
        let trip = UUID()
        let image = try inbox.add(data: Data([1, 2, 3]), fileExtension: "jpg", contentType: "public.jpeg", text: nil, tripId: trip)
        let text = try inbox.add(data: nil, fileExtension: nil, contentType: nil, text: "Uber receipt", tripId: nil, now: Date().addingTimeInterval(1))
        XCTAssertEqual(inbox.items().map(\.id), [image.id, text.id])
        XCTAssertEqual(inbox.data(for: image), Data([1, 2, 3]))
        inbox.remove(image)
        XCTAssertEqual(inbox.items().map(\.id), [text.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: image.fileName!).path))

        inbox.writeTrips([SharedTripSummary(id: trip, name: "Lisbon", emoji: "🌊")])
        XCTAssertEqual(inbox.trips().first?.name, "Lisbon")
        inbox.clear()
        XCTAssertTrue(inbox.items().isEmpty)
    }
}

@MainActor
final class RideReviewTests: XCTestCase {
    func testRideDefaultsToEqualSplitAmongRiders() throws {
        let trip = makeTrip()
        let ids = trip.participants.map(\.id)
        let (result, _) = try XCTUnwrap(RideReceiptParser.parse("Uber\nThanks for riding\nTrip fare $20.00\nBooking fee $1.00\nTip $3.00\nTotal $24.00\n9:00 PM Hotel Lisboa\n9:20 PM Alfama", currency: .usd, locale: Locale(identifier: "en_US")))
        let model = ScanReviewModel(trip: trip, result: result, receiptID: nil, me: ids[0])
        XCTAssertEqual(model.category, .transport)
        XCTAssertEqual(model.riders, Set(ids))
        XCTAssertNil(model.blockingIssue)

        model.setRiders([ids[0], ids[1]])
        let payload = try model.makePayload()
        XCTAssertEqual(payload.title, "Uber to Alfama")
        XCTAssertEqual(payload.amountMinor, 2400)
        XCTAssertEqual(payload.allocations.map(\.amountMinor).sorted(), [1200, 1200])
        XCTAssertEqual(payload.tags, ["ride", "uber"])
        XCTAssertEqual(payload.notes, "Uber · Hotel Lisboa → Alfama")
        XCTAssertNoThrow(try payload.validate(baseCurrency: .usd, participants: Set(ids)))
    }
}
