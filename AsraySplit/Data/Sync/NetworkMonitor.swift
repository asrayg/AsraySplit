import Foundation
import Network

/// NWPathMonitor wrapper. Reachability is a hint; the sync engine still handles request failures.
final class NetworkMonitor: NetworkStatusProviding, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.asray.split.network")
    private let lock = NSLock()
    private var online = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    private func update(_ value: Bool) {
        lock.lock()
        let changed = value != online
        online = value
        let targets = Array(continuations.values)
        lock.unlock()
        if changed { targets.forEach { $0.yield(value) } }
    }

    var isOnline: Bool {
        get async { lock.lock(); defer { lock.unlock() }; return online }
    }

    func onlineChanges() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock(); continuations[id] = continuation; lock.unlock()
        continuation.onTermination = { [weak self] _ in self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock() }
        return stream
    }
}

/// Controllable network status for tests and UI tests.
final class ManualNetworkStatus: NetworkStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var online: Bool
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init(online: Bool = true) { self.online = online }

    func set(online value: Bool) {
        lock.lock(); online = value; let targets = Array(continuations.values); lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    var isOnline: Bool { get async { lock.lock(); defer { lock.unlock() }; return online } }

    func onlineChanges() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock(); continuations[id] = continuation; lock.unlock()
        continuation.onTermination = { [weak self] _ in self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock() }
        return stream
    }
}
