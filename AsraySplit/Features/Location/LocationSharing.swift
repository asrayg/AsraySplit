import CoreLocation
import Foundation
import Observation

/// Opt-in live location for the crew, plus one-shot fixes for "drop a pin in chat".
/// - While the app is open: updates every ~50 m.
/// - In the background (if "Always" is allowed): iOS wakes the app on significant moves (~500 m).
/// - Offline: the newest fix is kept on the phone and uploaded when there's a connection (older fixes
///   never overwrite newer ones on the server).
@MainActor
@Observable
final class LocationSharing: NSObject {
    private(set) var friends: [MemberLocation] = []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: CLLocation?
    private(set) var isSharing: Bool
    var tripID: TripID?

    private let service: any LocationService
    private let manager = CLLocationManager()
    private var lastUploaded: CLLocation?
    private var oneShot: [CheckedContinuation<CLLocation?, Never>] = []
    private let defaults = UserDefaults.standard

    init(service: any LocationService) {
        self.service = service
        isSharing = UserDefaults.standard.bool(forKey: "location.sharing")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        authorization = manager.authorizationStatus
    }

    // MARK: Sharing

    func setSharing(_ on: Bool) {
        isSharing = on
        defaults.set(on, forKey: "location.sharing")
        if on {
            if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
            else if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
            startUpdates()
        } else {
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
            clearPending()
            if let tripID { Task { try? await service.stopSharingLocation(tripID: tripID) } }
        }
    }

    /// Call when the app becomes active or the network returns.
    func resume() {
        if isSharing { startUpdates() }
        Task { await flushPending() }
    }

    private func startUpdates() {
        guard isSharing, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        if authorization == .authorizedAlways { manager.startMonitoringSignificantLocationChanges() }
    }

    // MARK: One-shot (chat pin)

    func currentLocation() async -> CLLocation? {
        if let lastFix, lastFix.timestamp.timeIntervalSinceNow > -60 { return lastFix }
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        return await withCheckedContinuation { continuation in
            MainActor.assumeIsolated {
                oneShot.append(continuation)
                manager.requestLocation()
            }
        }
    }

    // MARK: Friends

    func refreshFriends() async {
        guard let tripID, let list = try? await service.listMemberLocations(tripID: tripID) else { return }
        friends = list
    }

    func watchFriends() async {
        guard let tripID else { return }
        await refreshFriends()
        for await _ in service.locationChanges(tripID: tripID) { await refreshFriends() }
    }

    // MARK: Upload with offline queue

    private func handle(_ location: CLLocation) {
        lastFix = location
        let continuations = oneShot
        oneShot = []
        continuations.forEach { $0.resume(returning: location) }
        guard isSharing else { return }
        // Throttle: at most once a minute unless moved 100 m.
        if let lastUploaded, location.timestamp.timeIntervalSince(lastUploaded.timestamp) < 60, location.distance(from: lastUploaded) < 100 { return }
        savePending(location)
        Task { await flushPending() }
    }

    private func flushPending() async {
        guard isSharing, let tripID, let pending = loadPending() else { return }
        do {
            try await service.updateMyLocation(tripID: tripID, latitude: pending.coordinate.latitude, longitude: pending.coordinate.longitude,
                                               accuracy: pending.horizontalAccuracy >= 0 ? pending.horizontalAccuracy : nil,
                                               recordedAt: pending.timestamp)
            lastUploaded = pending
            if loadPending()?.timestamp == pending.timestamp { clearPending() }
        } catch {
            // Offline: keep it; the next resume/fix retries.
        }
    }

    private func savePending(_ location: CLLocation) {
        defaults.set([location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy,
                      location.timestamp.timeIntervalSince1970], forKey: "location.pending")
    }

    private func loadPending() -> CLLocation? {
        guard let v = defaults.array(forKey: "location.pending") as? [Double], v.count == 4 else { return nil }
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: v[0], longitude: v[1]), altitude: 0,
                          horizontalAccuracy: v[2], verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: v[3]))
    }

    private func clearPending() { defaults.removeObject(forKey: "location.pending") }
}

extension LocationSharing: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isSharing && status == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
            self.startUpdates()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.handle(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let continuations = self.oneShot
            self.oneShot = []
            continuations.forEach { $0.resume(returning: nil) }
        }
    }
}
