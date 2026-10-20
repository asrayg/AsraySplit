import AuthenticationServices
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var currency: CurrencyCode = .usd
    @State private var preferences = NotificationPreferences()
    @State private var loadedPreferences = false
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmSignOut = false
    @State private var unsynced = 0
    @State private var confirmDelete = false
    @State private var deleteText = ""
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Display name", text: $name).onSubmit(saveProfile)
                    CurrencyPicker(selection: $currency, title: "Default currency")
                    if app.isDemo { Label("Demo mode · data stays on this iPhone", systemImage: "theatermasks").foregroundStyle(.secondary) }
                }

                Section {
                    NavigationLink { SyncIssuesView() } label: {
                        LabeledContent("Sync") {
                            if !store.isOnline { Text("Offline") }
                            else if !store.problemOperations.isEmpty { Text("\(store.problemOperations.count) issue(s)").foregroundStyle(Color.warning) }
                            else if !store.operations.isEmpty { Text("\(store.operations.count) pending") }
                            else { Text("Up to date") }
                        }
                    }
                } footer: { Text("Changes are saved on this iPhone first and synced to your trips automatically.") }

                Section {
                    Toggle("Push notifications", isOn: $preferences.pushEnabled)
                    if preferences.pushEnabled {
                        Toggle("Expenses added or changed", isOn: $preferences.expenseChanges)
                        Toggle("Payments recorded", isOn: $preferences.settlements)
                        Toggle("People joining or leaving", isOn: $preferences.membership)
                        Toggle("Receipt scans finished", isOn: $preferences.receiptScans)
                        Toggle("Show amounts on lock screen", isOn: $preferences.showDetailsOnLockScreen)
                    }
                    Toggle("Daily “log today’s spending” reminder", isOn: $preferences.dailyReminder)
                    Toggle("Email me settle-up reminders", isOn: $preferences.emailReminders)
                    if app.env.notifications.authorization == .denied {
                        Button("Notifications are off in Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            .font(.footnote)
                    }
                } header: { Text("Notifications") } footer: {
                    Text("Notifications never include amounts or merchants unless you allow lock-screen details. You can mute individual trips in trip settings. Settle-up emails are sent after a trip ends, or when someone you owe taps Remind.")
                }
                .onChange(of: preferences) { _, value in
                    guard loadedPreferences else { return }
                    Task {
                        if value.pushEnabled || value.dailyReminder, app.env.notifications.authorization == .notDetermined { await app.env.notifications.requestPermission() }
                        try? await app.env.backend.account.saveNotificationPreferences(value)
                        await app.env.notifications.scheduleDailyReminders(for: store.activeTrips, enabled: value.dailyReminder)
                    }
                }

                Section("Your data") {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share data export", systemImage: "square.and.arrow.up") }
                    } else {
                        Button { Task { await export() } } label: {
                            HStack { Label("Export my data", systemImage: "arrow.down.doc"); if exporting { Spacer(); ProgressView() } }
                        }
                    }
                    Link(destination: app.env.config.privacyURL) { Label("Privacy policy", systemImage: "hand.raised") }
                    Link(destination: app.env.config.termsURL) { Label("Terms of service", systemImage: "doc.plaintext") }
                    Link(destination: app.env.config.supportURL) { Label("Help & support", systemImage: "questionmark.circle") }
                    NavigationLink { ScanPrivacyView() } label: { Label("How receipt scanning works", systemImage: "sparkles") }
                }

                Section {
                    Button("Sign out") { Task { unsynced = await store.unsyncedCount(); confirmSignOut = true } }
                        .accessibilityIdentifier("signOut")
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deleting your account removes your profile, devices, receipt images you uploaded and trips only you belong to. Shared trips are handed to another member and your name is replaced with “Former traveler”.")
                }

                Section {
                    Text("Asray Split \(Bundle.main.appVersion ?? "")").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { saveProfile(); dismiss() } } }
            .task { await load() }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(unsynced > 0 ? "Sign out and discard \(unsynced) change(s)" : "Sign out", role: .destructive) {
                    Task { dismiss(); await app.signOut() }
                }
            } message: {
                Text(unsynced > 0 ? "\(unsynced) change(s) haven’t synced yet and will be lost. Connect to the internet first to keep them." : "Trip data cached on this iPhone will be removed.")
            }
            .sheet(isPresented: $confirmDelete) { deleteSheet }
        }
    }

    private var deleteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes your Asray Split account. It can’t be undone.").font(.headline)
                    Text("Type DELETE to confirm.")
                    TextField("DELETE", text: $deleteText).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                Section {
                    if app.env.backend.kind == .supabase {
                        SignInWithAppleButton(.continue) { request in request.requestedScopes = [] } onCompletion: { result in
                            let code = (try? result.get()).flatMap { ($0.credential as? ASAuthorizationAppleIDCredential)?.authorizationCode }.flatMap { String(data: $0, encoding: .utf8) }
                            Task { await deleteAccount(appleCode: code) }
                        }
                        .frame(height: 48)
                        .disabled(deleteText != "DELETE" || deleting)
                        Button("I didn’t use Sign in with Apple — delete", role: .destructive) { Task { await deleteAccount(appleCode: nil) } }
                            .disabled(deleteText != "DELETE" || deleting)
                    } else {
                        Button("Delete demo account", role: .destructive) { Task { await deleteAccount(appleCode: nil) } }
                            .disabled(deleteText != "DELETE" || deleting)
                    }
                } footer: { Text("If you signed in with Apple, confirm with Apple so we can revoke the app’s access to your Apple ID.") }
                if deleting { ProgressView("Deleting…") }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmDelete = false } } }
        }
    }

    private func load() async {
        name = app.profile?.displayName ?? ""
        currency = app.profile?.defaultCurrency ?? .usd
        if let remote = try? await app.env.backend.account.fetchNotificationPreferences() { preferences = remote }
        loadedPreferences = true
    }

    private func saveProfile() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != app.profile?.displayName || currency != app.profile?.defaultCurrency else { return }
        Task { await app.completeProfile(name: trimmed, emoji: app.profile?.avatarEmoji, currency: currency) }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await app.env.backend.account.exportData()
            let url = FileManager.default.temporaryDirectory.appending(path: "asray-split-export.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { app.report(error) }
    }

    private func deleteAccount(appleCode: String?) async {
        deleting = true
        defer { deleting = false }
        do {
            try await app.deleteAccount(appleAuthorizationCode: appleCode)
            confirmDelete = false
            dismiss()
        } catch { app.report(error) }
    }
}

@MainActor
struct ScanPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Receipt scanning").font(.title.bold())
                Text("When you scan a receipt, the photo is resized on your iPhone and its location and camera metadata are removed. It’s uploaded to private storage that only members of that trip can access, using links that expire within minutes.")
                Text("To read the items, the image is sent from our server to an AI provider. The provider processes it to return structured text and does not receive your name, email or trip details. We record only usage metadata (time, model, success) — never the receipt contents — in our logs.")
                Text("AI results are suggestions. Nothing is saved until you review and confirm every amount. If the AI is unavailable or you’re offline, your iPhone reads the receipt itself, and you can always type items manually.")
                Text("You can delete a receipt image at any time from the expense or the trip’s Receipts screen. Deleting your account deletes the images you uploaded.")
            }
            .padding(20)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Scanning & privacy")
    }
}
