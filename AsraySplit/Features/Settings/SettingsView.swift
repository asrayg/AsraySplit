import SwiftUI

/// Crew build settings: your display name and sync status. Nothing else to configure.
@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name).onSubmit(saveProfile)
                } header: { Text("You") } footer: { Text("Shown on expenses, chat and photos.") }

                Section {
                    NavigationLink { SyncIssuesView() } label: {
                        LabeledContent("Sync") {
                            if !store.isOnline { Text("Offline") }
                            else if !store.problemOperations.isEmpty { Text("\(store.problemOperations.count) issue(s)").foregroundStyle(Color.warning) }
                            else if !store.operations.isEmpty { Text("\(store.operations.count) pending") }
                            else { Text("Up to date") }
                        }
                    }
                    LabeledContent("Photos waiting for Wi-Fi", value: "\(app.env.photos.pendingUpload.count)")
                    LabeledContent("Messages waiting to send", value: "\(app.env.chat.unsent.count)")
                } footer: { Text("Everything is saved on this iPhone first and works offline. It syncs when you’re back online; photos wait for Wi-Fi.") }

                Section {
                    Text("AsraySplit \(Bundle.main.appVersion ?? "")").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { saveProfile(); dismiss() } } }
            .onAppear { name = app.profile?.displayName ?? "" }
        }
    }

    private func saveProfile() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != app.profile?.displayName else { return }
        Task { await app.completeProfile(name: trimmed, emoji: app.profile?.avatarEmoji, currency: .usd) }
    }
}
