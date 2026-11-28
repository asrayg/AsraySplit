import Foundation
import SwiftData

/// Composition root. Everything a feature needs is created here and passed down explicitly.
@MainActor
struct AppEnvironment {
    let config: AppConfig
    let backend: Backend
    let store: TripStore
    let network: any NetworkStatusProviding
    let notifications: NotificationCoordinator
    let scanner: ReceiptScanCoordinator
    let nearby: NearbyMesh
    let chat: ChatStore
    let photos: TripPhotoStore
    let location: LocationSharing
    /// Present only in demo mode.
    let demoBackend: InMemoryBackend?

    static func live(config: AppConfig = .load(), arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        let uiTesting = arguments.contains("-uiTesting")
        let local: LocalStore
        if uiTesting {
            local = LocalStore.ephemeral()
        } else if let container = try? LocalStore.makeContainer() {
            local = LocalStore(modelContainer: container)
        } else {
            // A corrupt cache must never block the app: rebuild it from the server.
            Log.app.error("Cache store failed to open; rebuilding")
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Cache"))
            local = (try? LocalStore.makeContainer()).map { LocalStore(modelContainer: $0) } ?? LocalStore.ephemeral()
        }
        let network: any NetworkStatusProviding = uiTesting ? ManualNetworkStatus(online: !arguments.contains("-offline")) : NetworkMonitor()

        let backend: Backend
        var demo: InMemoryBackend?
        if let url = config.supabaseURL, config.isBackendConfigured {
            backend = SupabaseBackend(url: url, publishableKey: config.supabasePublishableKey).backend
        } else {
            let server = InMemoryServer()
            let inMemory = InMemoryBackend(server: server, userID: nil)
            demo = inMemory
            backend = inMemory.backend
        }
        let nearby = NearbyMesh()
        return AppEnvironment(config: config, backend: backend, store: TripStore(local: local, backend: backend, network: network),
                              network: network, notifications: NotificationCoordinator(),
                              scanner: ReceiptScanCoordinator(receipts: backend.receipts, nearby: nearby), nearby: nearby,
                              chat: ChatStore(service: backend.chat, nearby: nearby),
                              photos: TripPhotoStore(service: backend.photos, nearby: nearby),
                              location: LocationSharing(service: backend.locations), demoBackend: demo)
    }

    static func preview(seeded: Bool = true) -> AppEnvironment {
        let server = InMemoryServer()
        let demo = InMemoryBackend(server: server, userID: DemoData.demoUserID)
        let local = LocalStore.ephemeral()
        let network = ManualNetworkStatus()
        let store = TripStore(local: local, backend: demo.backend, network: network)
        store.currentUserID = DemoData.demoUserID
        if seeded { Task { await DemoData.seed(server); await store.syncNow() } }
        return AppEnvironment(config: .load(), backend: demo.backend, store: store, network: network,
                              notifications: NotificationCoordinator(), scanner: ReceiptScanCoordinator(receipts: demo.backend.receipts),
                              nearby: NearbyMesh(), chat: ChatStore(service: demo.backend.chat, nearby: nil),
                              photos: TripPhotoStore(service: demo.backend.photos, nearby: nil,
                                                     directory: FileManager.default.temporaryDirectory.appending(path: "PreviewPhotos")),
                              location: LocationSharing(service: demo.backend.locations), demoBackend: demo)
    }
}
