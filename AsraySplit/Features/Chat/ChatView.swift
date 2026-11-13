import SwiftUI

@MainActor
struct ChatView: View {
    let tripID: TripID
    @Environment(AppModel.self) private var app
    @State private var draft = ""

    private var chat: ChatStore { app.env.chat }
    private var nearby: NearbyMesh { app.env.nearby }

    var body: some View {
        let messages = chat.messages(for: tripID)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Messages reach nearby phones over Bluetooth even without signal, and sync when you’re online."))
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
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let text = draft
                draft = ""
                Task { await chat.send(text, tripID: tripID) }
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
                Text(message.body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(mine ? Color.onBrand : Color.primary)
                    .background(mine ? Color.brand : Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
