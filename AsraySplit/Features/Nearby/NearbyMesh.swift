import Foundation
import MultipeerConnectivity
import Observation

/// Phone-to-phone link over Bluetooth / peer-to-peer Wi-Fi (MultipeerConnectivity). No internet needed.
/// Carries trip chat and "please read this receipt" requests to a phone that has Apple Intelligence.
///
/// Limits (iOS): only works while the app is open on both phones; range is roughly a room to a restaurant;
/// no multi-hop relaying. Sessions are encrypted. Anyone running this app nearby can connect — fine for a
/// private TestFlight build, and the server still enforces trip membership for everything durable.
@MainActor
@Observable
final class NearbyMesh: NSObject {
    enum Envelope: Codable {
        case hello(canParse: Bool, name: String)
        case chat(ChatMessage)
        case parseRequest(id: UUID, lines: [String], currency: String)
        case parseResponse(id: UUID, result: ReceiptScanResult?)
        /// Photo ids this phone already has, so peers only send what's missing.
        case photoInventory(ids: [UUID])
        /// Metadata for a photo file that follows as a resource named with the photo id.
        case photoMeta(TripPhoto)
    }

    struct Peer: Identifiable, Hashable { let id: MCPeerID; var name: String; var canParse: Bool }

    static let serviceType = "asraysplit"   // ≤15 chars; matches NSBonjourServices in Info.plist

    private(set) var peers: [Peer] = []
    private(set) var isRunning = false
    var helperAvailable: Bool { peers.contains(where: \.canParse) }

    /// Incoming chat from a nearby phone.
    var onChat: ((ChatMessage) -> Void)?
    /// Answers parse requests from nearby phones (set when this phone can run the on-device model).
    var parseHandler: (([String], CurrencyCode) async -> ReceiptScanResult?)?
    var canParse: Bool { parseHandler != nil }
    /// Photo sharing hooks (set by TripPhotoStore).
    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPhotoInventory: ((MCPeerID, Set<UUID>) -> Void)?
    var onPhotoMeta: ((TripPhoto) -> Void)?
    var onPhotoFile: ((UUID, URL) -> Void)?
    private(set) var photosInFlight = 0

    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Random per-launch token: the side with the smaller token sends the invitation (avoids double invites).
    private let token = UUID().uuidString
    private var pendingParses: [UUID: CheckedContinuation<ReceiptScanResult?, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func start(displayName: String) {
        guard !isRunning else { return }
        let peer = MCPeerID(displayName: String(displayName.prefix(60)).isEmpty ? "Phone" : String(displayName.prefix(60)))
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["t": token], serviceType: Self.serviceType)
        advertiser.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        browser.delegate = self
        (self.peerID, self.session, self.advertiser, self.browser) = (peer, session, advertiser, browser)
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isRunning = true
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        (peerID, session, advertiser, browser) = (nil, nil, nil, nil)
        peers = []
        isRunning = false
        for continuation in pendingParses.values { continuation.resume(returning: nil) }
        pendingParses = [:]
    }

    // MARK: Sending

    func broadcast(_ message: ChatMessage) {
        send(.chat(message), to: peers.map(\.id))
    }

    /// Asks a nearby Apple Intelligence phone to structure OCR text. Returns nil if none answers in time.
    func requestParse(lines: [String], currency: CurrencyCode, timeout: Duration = .seconds(25)) async -> ReceiptScanResult? {
        guard let helper = peers.first(where: \.canParse) else { return nil }
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishParse(id, nil)
        }
        return await withCheckedContinuation { continuation in
            // The body runs synchronously on the caller's executor (the main actor).
            MainActor.assumeIsolated {
                pendingParses[id] = continuation
                send(.parseRequest(id: id, lines: Array(lines.prefix(400)), currency: currency.rawValue), to: [helper.id])
            }
        }
    }

    private func finishParse(_ id: UUID, _ result: ReceiptScanResult?) {
        pendingParses.removeValue(forKey: id)?.resume(returning: result)
    }

    private func send(_ envelope: Envelope, to targets: [MCPeerID]) {
        guard let session, !targets.isEmpty, let data = try? encoder.encode(envelope) else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    func sendPhotoInventory(_ ids: [UUID], to peer: MCPeerID) {
        send(.photoInventory(ids: ids), to: [peer])
    }

    /// Sends one photo: metadata first, then the file. Returns when the transfer finishes or fails.
    func sendPhoto(_ photo: TripPhoto, fileURL: URL, to peer: MCPeerID) async -> Bool {
        guard let session, session.connectedPeers.contains(peer) else { return false }
        send(.photoMeta(photo), to: [peer])
        photosInFlight += 1
        defer { photosInFlight -= 1 }
        return await withCheckedContinuation { continuation in
            session.sendResource(at: fileURL, withName: photo.id.uuidString, toPeer: peer) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func sayHello(to peer: MCPeerID) {
        send(.hello(canParse: canParse, name: peerID?.displayName ?? ""), to: [peer])
    }

    /// Call when parse capability changes so peers learn about it.
    func announce() { for peer in peers { sayHello(to: peer.id) } }

    // MARK: Receiving

    private func handle(_ data: Data, from peer: MCPeerID) {
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return }
        switch envelope {
        case .hello(let canParse, let name):
            if let index = peers.firstIndex(where: { $0.id == peer }) {
                peers[index].canParse = canParse
                peers[index].name = name
            }
        case .chat(let message):
            onChat?(message)
        case .parseRequest(let id, let lines, let currencyCode):
            guard let handler = parseHandler, let currency = CurrencyCode(currencyCode) else {
                send(.parseResponse(id: id, result: nil), to: [peer])
                return
            }
            Task {
                let result = await handler(lines, currency)
                send(.parseResponse(id: id, result: result), to: [peer])
            }
        case .photoInventory(let ids):
            onPhotoInventory?(peer, Set(ids))
        case .photoMeta(let photo):
            onPhotoMeta?(photo)
        case .parseResponse(let id, let result):
            // Untrusted: validate before it reaches the review screen.
            finishParse(id, result.flatMap { try? ScanResultValidator.validate($0) })
        }
    }

    private func connected(_ peer: MCPeerID) {
        if !peers.contains(where: { $0.id == peer }) { peers.append(Peer(id: peer, name: peer.displayName, canParse: false)) }
        sayHello(to: peer)
        onPeerConnected?(peer)
    }

    private func disconnected(_ peer: MCPeerID) {
        peers.removeAll { $0.id == peer }
    }
}

extension NearbyMesh: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected: self.connected(peerID)
            case .notConnected: self.disconnected(peerID)
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handle(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The system deletes localURL when this returns, so move it synchronously first.
        guard error == nil, let localURL, let id = UUID(uuidString: resourceName) else { return }
        let kept = FileManager.default.temporaryDirectory.appending(path: "incoming-\(id.uuidString).jpg")
        try? FileManager.default.removeItem(at: kept)
        guard (try? FileManager.default.moveItem(at: localURL, to: kept)) != nil else { return }
        Task { @MainActor in self.onPhotoFile?(id, kept) }
    }
}

extension NearbyMesh: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(self.session != nil, self.session) }
    }
}

extension NearbyMesh: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session, peerID != self.peerID, !session.connectedPeers.contains(peerID) else { return }
            // Only one side invites; the other waits for the invitation.
            if let theirs = info?["t"], self.token > theirs { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
