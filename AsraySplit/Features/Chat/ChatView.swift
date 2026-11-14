import SwiftUI

@MainActor
struct ChatView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var announce = false
    @State private var pinning = false

    /// Only Asray's phone gets the 📣 announcement button (the server enforces this too).
    private var canAnnounce: Bool { UserDefaults.standard.string(forKey: AppModel.crewNameKey) == "Asray" }

    private var chat: ChatStore { app.env.chat }
    private var nearby: NearbyMesh { app.env.nearby }

    var body: some View {
        let messages = chat.messages(for: tripID)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
                            .padding(.top, 60)
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .onAppear { if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
        .safeAreaInset(edge: .top) { nearbyBar }
        .safeAreaInset(edge: .bottom) { composer }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await chat.refresh(tripID: tripID) }
        .task { await chat.watch(tripID: tripID) }
    }

    private var nearbyBar: some View {
        HStack(spacing: 6) {
            Image(systemName: nearby.peers.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
            Text(nearby.peers.isEmpty ? "No phones nearby" : "Nearby: " + nearby.peers.map(\.name).joined(separator: ", "))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(nearby.peers.isEmpty ? Color.secondary : Color.brand)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button { Task { await sendPin() } } label: {
                if pinning { ProgressView() } else { Image(systemName: "mappin.circle.fill").font(.system(size: 28)) }
            }
            .disabled(pinning)
            .accessibilityLabel(Text("Share my location in chat"))
            if canAnnounce {
                Button { announce.toggle() } label: {
                    Image(systemName: announce ? "megaphone.fill" : "megaphone").font(.system(size: 22))
                        .foregroundStyle(announce ? Color.warning : Color.secondary)
                }
                .accessibilityLabel(Text(announce ? "Announcement on" : "Announcement off"))
            }
            TextField(announce ? "Announcement to everyone" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let text = draft
                draft = ""
                let loud = announce
                announce = false
                Task { await chat.send(text, tripID: tripID, announce: loud) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = chat.isMine(message)
        return HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine { Text(message.senderName).font(.caption.bold()).foregroundStyle(.secondary) }
                if let pin = message.pinnedCoordinate {
                    PinBubble(latitude: pin.latitude, longitude: pin.longitude, url: message.mapsURL)
                } else if message.isAnnouncement == true {
                    Label(message.body, systemImage: "megaphone.fill")
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundStyle(Color.primary)
                        .background(Color.warning.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.warning, lineWidth: 1))
                } else {
                    Text(message.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(mine ? Color.onBrand : Color.primary)
                        .background(mine ? Color.brand : Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                HStack(spacing: 4) {
                    Text(message.sentAt, style: .time)
                    if mine && chat.unsent.contains(message.id) {
                        Image(systemName: "clock").accessibilityLabel(Text("Not synced yet"))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }
}

extension ChatView {
    private func sendPin() async {
        pinning = true
        defer { pinning = false }
        guard let fix = await app.env.location.currentLocation() else {
            app.show(Toast(message: String(localized: "Couldn’t get your location. Check Location access in Settings."), style: .warning))
            return
        }
        let name = app.profile?.displayName ?? "Me"
        let body = ChatMessage.locationBody(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, label: "\(name) is here")
        await chat.send(body, tripID: tripID)
    }
}

import MapKit

/// Map snapshot-style bubble for a 📍 message; tap opens Apple Maps.
@MainActor
private struct PinBubble: View {
    let latitude: Double
    let longitude: Double
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Button { if let url { openURL(url) } } label: {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
                Marker("", systemImage: "mappin", coordinate: coordinate)
            }
            .frame(width: 220, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Label("Open in Maps", systemImage: "arrow.up.right.square").font(.caption2.bold())
                    .padding(6).background(.ultraThinMaterial, in: Capsule()).padding(6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Shared location. Opens in Maps."))
    }
}
