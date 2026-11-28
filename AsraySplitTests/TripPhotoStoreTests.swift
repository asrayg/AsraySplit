import UIKit
import XCTest
@testable import AsraySplit

private final class FakePhotoService: PhotoService, @unchecked Sendable {
    var uploaded: [UUID: Data] = [:]
    func listPhotos(tripID: TripID) async throws -> [TripPhoto] { [] }
    func uploadPhoto(_ photo: TripPhoto, data: Data) async throws -> TripPhoto { uploaded[photo.id] = data; return photo }
    func downloadPhoto(_ photo: TripPhoto) async throws -> Data { throw AppError.notFound }
}

@MainActor
final class TripPhotoStoreTests: XCTestCase {
    private func sampleJPEG(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeStore(_ service: FakePhotoService) -> (TripPhotoStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "photos-\(UUID())")
        return (TripPhotoStore(service: service, nearby: nil, directory: dir), dir)
    }

    func testPrepareDownscalesTo2048AndOutputsJPEG() throws {
        let prepared = try XCTUnwrap(TripPhotoStore.prepare(sampleJPEG(width: 4000, height: 3000)))
        XCTAssertEqual(max(prepared.width, prepared.height), TripPhoto.maxDimension)
        XCTAssertTrue(prepared.data.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testPrepareRejectsGarbage() {
        XCTAssertNil(TripPhotoStore.prepare(Data("not an image".utf8)))
    }

    func testAddQueuesForUploadAndSurvivesRelaunch() async {
        let service = FakePhotoService()
        let (store, dir) = makeStore(service)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = UUID()
        let added = await store.add([sampleJPEG(width: 800, height: 600), sampleJPEG(width: 600, height: 800)], tripID: trip)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.photos(for: trip).count, 2)
        XCTAssertEqual(store.pendingCount(for: trip), 2)

        let reopened = TripPhotoStore(service: service, nearby: nil, directory: dir)
        XCTAssertEqual(reopened.photos(for: trip).count, 2)
        XCTAssertEqual(reopened.pendingCount(for: trip), 2)
    }

    func testForcedSyncUploadsAndClearsQueue() async {
        let service = FakePhotoService()
        let (store, dir) = makeStore(service)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trip = UUID()
        await store.add([sampleJPEG(width: 400, height: 400)], tripID: trip)
        await store.sync(tripIDs: [trip], allowCellular: true)
        XCTAssertEqual(service.uploaded.count, 1)
        XCTAssertEqual(store.pendingCount(for: trip), 0)
    }
}
