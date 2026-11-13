import BackgroundTasks
import Foundation
import ImageIO
import MultipeerConnectivity
import Network
import Observation
import UIKit
import UniformTypeIdentifiers

/// Shared trip albums.
/// - Add many photos at once; each is resized to ≤2048 px JPEG with location/EXIF stripped.
/// - Nearby phones swap whatever the other is missing over Bluetooth / peer Wi-Fi as soon as they connect.
/// - The server copy (Supabase Storage) fills in the rest. Uploads/downloads are queued until the phone is on
///   Wi-Fi (never cellular or hotspot), then run automatically; iOS also wakes the app overnight while charging.
///   "Sync now" can override and use cellular.
@MainActor
@Observable
final class TripPhotoStore {
    static let backgroundTaskID = "com.asray.split.photosync"

    private(set) var photos: [UUID: TripPhoto] = [:]
    private(set) var pendingUpload: Set<UUID> = []
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var importing = 0
    var userID: UserID?
    var displayName = ""
    /// Trips this phone belongs to; photos for other trips received nearby are ignored.
    var knownTrips: () -> Set<TripID> = { [] }

    private let service: any PhotoService
    private let nearby: NearbyMesh?
    private let directory: URL
    private var incomingMeta: [UUID: TripPhoto] = [:]
    private var incomingFiles: [UUID: URL] = [:]
    private var sending: Set<String> = []
    private let thumbnails = NSCache<NSUUID, UIImage>()
    private let pathMonitor = NWPathMonitor()
    /// True on Wi-Fi/Ethernet (unmetered, not Low Data Mode).
    private(set) var onWiFi = false

    init(service: any PhotoService, nearby: NearbyMesh?,
         directory: URL = URL.applicationSupportDirectory.appending(path: "TripPhotos")) {
        self.service = service
        self.nearby = nearby
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in self?.networkChanged(wifi: wifi) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "photos.path"))
        guard let nearby else { return }
        nearby.onPeerConnected = { [weak self] peer in self?.offerInventory(to: peer) }
        nearby.onPhotoInventory = { [weak self] peer, theirs in self?.sendMissing(to: peer, theirs: theirs) }
        nearby.onPhotoMeta = { [weak self] photo in self?.receivedMeta(photo) }
        nearby.onPhotoFile = { [weak self] id, url in self?.receivedFile(id, url) }
    }

    func photos(for tripID: TripID) -> [TripPhoto] {
        photos.values.filter { $0.tripId == tripID && hasFile($0.id) }.sorted { ($0.sortDate, $0.id.uuidString) < ($1.sortDate, $1.id.uuidString) }
    }

    func fileURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString.lowercased()).jpg") }
    func hasFile(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: fileURL(id).path) }
    func pendingCount(for tripID: TripID) -> Int { pendingUpload.filter { photos[$0]?.tripId == tripID }.count }

    // MARK: Adding

    /// Imports original image data (any format UIKit reads). Returns how many were added.
    @discardableResult
    func add(_ originals: [Data], tripID: TripID) async -> Int {
        importing += originals.count
        defer { importing -= originals.count }
        var added: [TripPhoto] = []
        for original in originals {
            guard let processed = await Task.detached(priority: .userInitiated, operation: { Self.prepare(original) }).value else { continue }
            let photo = TripPhoto(id: UUID(), tripId: tripID, uploaderId: userID, uploaderName: displayName.isEmpty ? "Me" : displayName,
                                  width: processed.width, height: processed.height, byteSize: processed.data.count,
                                  takenAt: processed.takenAt, createdAt: Date())
            do {
                try write(processed.data, to: fileURL(photo.id))
                photos[photo.id] = photo
                pendingUpload.insert(photo.id)
                added.append(photo)
            } catch {
                Log.app.error("Saving photo failed")
            }
        }
        saveIndex()
        if let nearby { for peer in nearby.peers { sendPhotos(added, to: peer.id) } }
        scheduleOvernightSync()
        if onWiFi { Task { await sync(tripIDs: [tripID]) } }
        return added.count
    }

    struct Prepared: Sendable { let data: Data; let width: Int; let height: Int; let takenAt: Date? }

    /// Downscales to ≤2048 px and re-encodes as JPEG. Re-encoding without the source properties drops GPS/EXIF.
    nonisolated static func prepare(_ original: Data) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TripPhoto.maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= TripPhoto.maxBytes else { return nil }

        var takenAt: Date?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            takenAt = formatter.date(from: stamp)
        }
        return Prepared(data: output as Data, width: image.width, height: image.height, takenAt: takenAt)
    }

    // MARK: Nearby

    private func offerInventory(to peer: MCPeerID) {
        nearby?.sendPhotoInventory(photos.keys.filter(hasFile), to: peer)
    }

    private func sendMissing(to peer: MCPeerID, theirs: Set<UUID>) {
        let missing = photos.values.filter { !theirs.contains($0.id) && hasFile($0.id) }.sorted { $0.sortDate < $1.sortDate }
        sendPhotos(missing, to: peer)
    }

    private func sendPhotos(_ list: [TripPhoto], to peer: MCPeerID) {
        guard let nearby, !list.isEmpty else { return }
        Task {
            for photo in list {
                let key = "\(peer.displayName)|\(photo.id)"
                guard !sending.contains(key) else { continue }
                sending.insert(key)
                _ = await nearby.sendPhoto(photo, fileURL: fileURL(photo.id), to: peer)
                sending.remove(key)
            }
        }
    }

    private func receivedMeta(_ photo: TripPhoto) {
        guard knownTrips().contains(photo.tripId), photos[photo.id] == nil else { return }
        incomingMeta[photo.id] = photo
        if let file = incomingFiles.removeValue(forKey: photo.id) { receivedFile(photo.id, file) }
    }

    private func receivedFile(_ id: UUID, _ url: URL) {
        guard let meta = incomingMeta[id] else {
            incomingFiles[id] = url      // metadata may still be in flight
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        incomingMeta[id] = nil
        // Untrusted input: must be a JPEG within limits.
        guard let data = try? Data(contentsOf: url), data.count <= TripPhoto.maxBytes, data.starts(with: [0xFF, 0xD8, 0xFF]),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1 else { return }
        do {
            try write(data, to: fileURL(id))
            var photo = meta
            photo.byteSize = data.count
            photos[id] = photo
            saveIndex()
        } catch {
            Log.app.error("Saving received photo failed")
        }
    }

    // MARK: Server sync

    private func networkChanged(wifi: Bool) {
        let cameOnline = wifi && !onWiFi
        onWiFi = wifi
        if cameOnline { Task { await sync(tripIDs: Array(knownTrips())) } }
    }

    /// Uploads this phone's new photos and downloads everyone else's. Safe to call repeatedly.
    /// Without `allowCellular` it does nothing off Wi-Fi — the queue waits and runs when Wi-Fi returns.
    func sync(tripIDs: [TripID], allowCellular: Bool = false) async {
        guard !isSyncing, allowCellular || onWiFi else { return }
        isSyncing = true
        defer { isSyncing = false; lastSync = Date() }

        for id in pendingUpload {
            guard let photo = photos[id], let data = try? Data(contentsOf: fileURL(id)) else { continue }
            do {
                let stored = try await service.uploadPhoto(photo, data: data)
                photos[id] = stored
                pendingUpload.remove(id)
                saveIndex()
            } catch {
                Log.app.notice("Photo upload deferred: \(error.asAppError.title, privacy: .public)")
            }
        }
        for tripID in tripIDs {
            guard let remote = try? await service.listPhotos(tripID: tripID) else { continue }
            for photo in remote {
                if photos[photo.id] == nil || !hasFile(photo.id) {
                    guard let data = try? await service.downloadPhoto(photo), data.starts(with: [0xFF, 0xD8, 0xFF]) else { continue }
                    try? write(data, to: fileURL(photo.id))
                }
                if !pendingUpload.contains(photo.id) { photos[photo.id] = photo }
            }
            saveIndex()
        }
    }

    /// Asks iOS to run a sync tonight while the phone is charging and online (Wi-Fi is typical at that point).
    func scheduleOvernightSync() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        var tonight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 1), matchingPolicy: .nextTime) ?? Date()
        if tonight.timeIntervalSinceNow > 86_400 { tonight = Date() }
        request.earliestBeginDate = tonight
        do { try BGTaskScheduler.shared.submit(request) } catch {
            Log.app.notice("Overnight photo sync not scheduled (simulator or disabled)")
        }
    }

    // MARK: Viewing helpers

    func thumbnail(_ id: UUID, size: CGFloat) -> UIImage? {
        if let cached = thumbnails.object(forKey: id as NSUUID) { return cached }
        guard let source = CGImageSourceCreateWithURL(fileURL(id) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: size * UIScreen.main.scale]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails.setObject(image, forKey: id as NSUUID)
        return image
    }

    // MARK: Storage

    private struct Index: Codable { var photos: [TripPhoto]; var pending: [UUID] }
    private var indexURL: URL { directory.appending(path: "index.json") }

    private func write(_ data: Data, to url: URL) throws {
        // Readable after first unlock so the overnight sync can run while the phone is locked.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        photos = Dictionary(index.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pendingUpload = Set(index.pending)
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(Index(photos: Array(photos.values), pending: Array(pendingUpload))) else { return }
        try? write(data, to: indexURL)
    }

    func wipe() {
        photos = [:]
        pendingUpload = []
        thumbnails.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
