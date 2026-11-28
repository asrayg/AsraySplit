import PhotosUI
import SwiftUI

@MainActor
struct ChatView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var announce = false
    @State private var pinning = false
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var reactingTo: UUID?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var viewingPhoto: TripPhoto?
    static let quickReactions = ["❤️", "😂", "🔥", "👍", "😮", "🇵🇷"]
    @FocusState private var typing: Bool

    /// Everyone on the trip can send a 📣 announcement.
    private var canAnnounce: Bool { true }

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
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { typing = false }
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
        .onAppear { if app.tab == .chat { chat.markRead(tripID) } }
        .onChange(of: app.tab) { old, new in if old == .chat || new == .chat { chat.markRead(tripID) } }
        .onChange(of: messages.count) { _, _ in if app.tab == .chat { chat.markRead(tripID) } }
        .task { await chat.watch(tripID: tripID) }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await sendPhotos(items) }
        }
        .fullScreenCover(item: $viewingPhoto) { photo in
            PhotoViewer(photos: app.env.photos.photos(for: tripID), start: photo)
        }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var datas: [Data] = []
        for item in items { if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) } }
        let ids = await app.env.photos.addReturningIDs(datas, tripID: tripID)
        for id in ids { await chat.send(ChatMessage.photoBody(id), tripID: tripID) }
        if ids.count < items.count { app.show(Toast(message: String(localized: "Some photos couldn’t be added."), style: .warning)) }
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
        VStack(spacing: 0) {
            if let replyingTo, editing == nil {
                HStack {
                    Label("Replying to \(replyingTo.senderName)", systemImage: "arrowshape.turn.up.left.fill").font(.caption.bold())
                    Text(replyingTo.body).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(Text("Cancel reply"))
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            if let editing {
                HStack {
                    Label("Editing", systemImage: "pencil").font(.caption.bold())
                    Text(editing.body).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.editing = nil; draft = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(Text("Cancel editing"))
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            composerRow
        }
        .background(.bar)
    }

    private var composerRow: some View {
        HStack(spacing: 10) {
            Button { Task { await sendPin() } } label: {
                if pinning { ProgressView() } else { Image(systemName: "mappin.circle.fill").font(.system(size: 28)) }
            }
            .disabled(pinning)
            .accessibilityLabel(Text("Share my location in chat"))
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 10, selectionBehavior: .ordered, matching: .images) {
                Image(systemName: "photo.circle.fill").font(.system(size: 28))
            }
            .accessibilityLabel(Text("Send photos"))
            if canAnnounce {
                Button { announce.toggle() } label: {
                    Image(systemName: announce ? "megaphone.fill" : "megaphone").font(.system(size: 22))
                        .foregroundStyle(announce ? Color.warning : Color.secondary)
                }
                .accessibilityLabel(Text(announce ? "Announcement on" : "Announcement off"))
            }
            TextField(announce ? "Announcement to everyone" : "Message", text: $draft, axis: .vertical)
                .focused($typing)
                .submitLabel(.done)
                .onChange(of: draft) { _, value in
                    // The keyboard's Done key closes the keyboard (no newlines in chat).
                    if value.contains("\n") { draft = value.replacingOccurrences(of: "\n", with: ""); typing = false }
                }
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let text = draft
                draft = ""
                if let original = editing {
                    editing = nil
                    Task { await chat.edit(original, to: text) }
                    return
                }
                let loud = announce
                announce = false
                let reply = replyingTo?.id
                replyingTo = nil
                Task { await chat.send(text, tripID: tripID, announce: loud, replyTo: reply) }
                app.eggs.chatSent(text)
            } label: {
                Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = chat.isMine(message)
        return HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine { Text(message.senderName).font(.caption.bold()).foregroundStyle(.secondary) }
                if let replyID = message.replyTo {
                    let original = chat.message(replyID, in: tripID)
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.brand).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(original?.senderName ?? "Message").font(.caption2.bold())
                            Text(original.map { $0.deletedAt == nil ? $0.body : "Deleted message" } ?? "…").font(.caption2).lineLimit(2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let photoID = message.photoID {
                    ChatPhotoBubble(photoID: photoID, tripID: tripID) { viewingPhoto = $0 }
                } else if let pin = message.pinnedCoordinate {
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
                if let reactions = message.reactions, !reactions.isEmpty { reactionChips(message, reactions) }
                if reactingTo == message.id { reactionBar(message) }
                HStack(spacing: 4) {
                    if message.editedAt != nil { Text("edited") }
                    Text(message.sentAt, style: .time)
                    if mine && chat.unsent.contains(message.id) {
                        Image(systemName: "clock").accessibilityLabel(Text("Not synced yet"))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !mine { Spacer(minLength: 48) }
        }
        .onTapGesture(count: 2) { Task { await chat.toggleReaction("❤️", on: message) } }
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { reactingTo = reactingTo == message.id ? nil : message.id } }
        .contextMenu {
            Button { replyingTo = message; editing = nil; typing = true } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            if mine {
                if message.pinnedCoordinate == nil && message.photoID == nil {
                    Button { editing = message; draft = message.body; typing = true } label: { Label("Edit", systemImage: "pencil") }
                }
                Button(role: .destructive) { Task { await chat.delete(message) } } label: { Label("Delete", systemImage: "trash") }
            }
            Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }
}

extension ChatView {
    /// Tap a message to react: one horizontal row of emoji.
    private func reactionBar(_ message: ChatMessage) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button {
                    Task { await chat.toggleReaction(emoji, on: message) }
                    withAnimation { reactingTo = nil }
                } label: { Text(emoji).font(.title3).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("React \(emoji)"))
            }
        }
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func reactionChips(_ message: ChatMessage, _ reactions: [ChatReaction]) -> some View {
        let grouped = Dictionary(grouping: reactions, by: \.emoji).sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
        return HStack(spacing: 4) {
            ForEach(grouped, id: \.key) { emoji, people in
                let mineToo = people.contains { $0.userId == chat.userID }
                Button { Task { await chat.toggleReaction(emoji, on: message) } } label: {
                    Text(people.count > 1 ? "\(emoji) \(people.count)" : emoji)
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(mineToo ? Color.brand.opacity(0.25) : Color.surface, in: Capsule())
                        .overlay(Capsule().stroke(mineToo ? Color.brand : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(emoji) from \(people.map(\.displayName).joined(separator: ", "))"))
            }
        }
    }

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


/// Photo message: shows the album photo (it may still be arriving over Bluetooth or from the server).
@MainActor
private struct ChatPhotoBubble: View {
    let photoID: UUID
    let tripID: TripID
    let open: (TripPhoto) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let album = app.env.photos
        Group {
            if let photo = album.photos[photoID], let image = album.thumbnail(photoID, size: 240), album.hasFile(photoID) {
                Button { open(photo) } label: {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 220, height: 220 * min(1.5, max(0.6, CGFloat(photo.height) / CGFloat(max(photo.width, 1)))))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Photo from \(photo.uploaderName)"))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.surface)
                    .frame(width: 220, height: 160)
                    .overlay { VStack(spacing: 6) { ProgressView(); Text("Photo arriving…").font(.caption).foregroundStyle(.secondary) } }
                    .task { await album.sync(tripIDs: [tripID], allowCellular: true) }
            }
        }
    }
}
