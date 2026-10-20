import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct TripSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    let tripID: TripID

    @State private var showEdit = false
    @State private var showInvite = false
    @State private var newGuest = ""
    @State private var renaming: Participant?
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var leaveNeedsAck = false
    @State private var muted = false
    @State private var exportURL: URL?
    @State private var summaryText = ""

    var body: some View {
        if let trip = store.trip(tripID) {
            form(trip)
        } else {
            ContentUnavailableView("Trip unavailable", systemImage: "suitcase")
        }
    }

    private func form(_ trip: Trip) -> some View {
        let canAdmin = trip.canManage(.admin)
        let isOwner = trip.canManage(.owner)
        return List {
            Section {
                if canAdmin && !trip.isArchived {
                    Button { showInvite = true } label: { Label("Invite people", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("invitePeople")
                }
                if canAdmin { Button { showEdit = true } label: { Label("Edit trip details", systemImage: "pencil") } }
            }

            Section {
                ForEach(trip.participants) { person in
                    HStack {
                        Avatar(name: person.displayName, size: 30)
                        VStack(alignment: .leading) {
                            Text(person.displayName)
                            Text(role(of: person, in: trip)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        memberMenu(person, trip: trip, isOwner: isOwner, canAdmin: canAdmin)
                    }
                }
                if !trip.isArchived {
                    HStack {
                        TextField("Add a traveler", text: $newGuest)
                        Button("Add") {
                            let name = newGuest.trimmingCharacters(in: .whitespaces)
                            newGuest = ""
                            Task { do { try await store.addParticipant(to: trip, name: name) } catch { app.report(error) } }
                        }
                        .disabled(newGuest.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: { Text("People") } footer: {
                Text("Guests can be added without an account and claimed later when they join. Removed members lose access immediately; their past expenses keep their name.")
            }

            Section("Notifications") {
                Toggle("Mute this trip", isOn: $muted)
                    .onChange(of: muted) { _, value in Task { try? await app.env.backend.account.setTripMuted(trip.id, muted: value) } }
            }

            Section("Export") {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Export CSV", systemImage: "tablecells") }
                }
                ShareLink(item: summaryText) { Label("Share summary", systemImage: "text.alignleft") }
            }

            Section {
                if canAdmin {
                    Button { Task { do { try await store.setArchived(trip, archived: !trip.isArchived) } catch { app.report(error) } } } label: {
                        Label(trip.isArchived ? "Unarchive trip" : "Archive trip", systemImage: "archivebox")
                    }
                }
                if !isOwner {
                    Button(role: .destructive) { confirmLeave = true } label: { Label("Leave trip", systemImage: "rectangle.portrait.and.arrow.right") }
                }
                if isOwner {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete trip", systemImage: "trash") }
                }
            } footer: {
                if isOwner { Text("To leave a trip you own, transfer ownership to another member first.") }
            }
        }
        .screenBackground()
        .navigationTitle("Trip settings")
        .sheet(isPresented: $showEdit) { TripEditorView(existing: trip) }
        .sheet(isPresented: $showInvite) { InviteView(trip: trip) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renaming { Task { do { try await store.renameParticipant(renaming, name: renameText) } catch { app.report(error) } } }
            }
        }
        .confirmationDialog("Delete \(trip.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) {
                Task {
                    do { try await store.deleteTrip(trip); app.path = [] } catch { app.report(error) }
                }
            }
        } message: { Text("All expenses, payments and receipts are permanently deleted for every member. This can’t be undone.") }
        .confirmationDialog("Leave \(trip.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(leaveNeedsAck ? "Leave with unsettled balance" : "Leave", role: .destructive) { Task { await leave(trip) } }
        } message: {
            Text(leaveNeedsAck ? "You still have an unsettled balance. Others will keep seeing it under your name." : "You’ll lose access to this trip. Your past expenses stay in the ledger.")
        }
        .task(id: store.version) { await prepareExport(trip) }
    }

    @ViewBuilder
    private func memberMenu(_ person: Participant, trip: Trip, isOwner: Bool, canAdmin: Bool) -> some View {
        let member = trip.members.first { $0.participantId == person.id && $0.status == .active }
        Menu {
            Button("Rename") { renameText = person.displayName; renaming = person }
            if let member, member.userId != store.currentUserID {
                if isOwner {
                    if member.role == .member { Button("Make admin") { Task { await run { try await store.setRole(.admin, for: member, in: trip) } } } }
                    if member.role == .admin { Button("Make member") { Task { await run { try await store.setRole(.member, for: member, in: trip) } } } }
                    Button("Transfer ownership") { Task { await run { try await store.transferOwnership(of: trip, to: member) } } }
                }
                if canAdmin && member.role != .owner && (isOwner || member.role == .member) {
                    Button("Remove from trip", role: .destructive) { Task { await run { try await store.removeMember(member, from: trip) } } }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel(Text("Options for \(person.displayName)"))
    }

    private func role(of person: Participant, in trip: Trip) -> String {
        if let member = trip.members.first(where: { $0.participantId == person.id }) {
            switch member.status {
            case .active: return member.userId == store.currentUserID ? String(localized: "\(member.role.title) · you") : member.role.title
            case .left: return String(localized: "Left the trip")
            case .removed: return String(localized: "Removed")
            }
        }
        return person.userId == nil ? String(localized: "Guest (no account)") : String(localized: "Former member")
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { app.report(error) }
    }

    private func leave(_ trip: Trip) async {
        do {
            try await store.leaveTrip(trip, acknowledgeUnsettled: leaveNeedsAck)
            app.path = []
        } catch let error as AppError where error == .conflict(code: "unsettled_balance", currentRevision: nil) {
            leaveNeedsAck = true
            confirmLeave = true
        } catch {
            app.report(error)
        }
    }

    private func prepareExport(_ trip: Trip) async {
        let expenses = await store.allExpenses(tripID: trip.id).map(\.expense)
        let settlements = await store.settlements(tripID: trip.id).map(\.settlement)
        let csv = TripExporter.csv(trip: trip, expenses: expenses, settlements: settlements)
        let safeName = trip.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName.isEmpty ? "trip" : safeName).csv")
        try? Data(csv.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        exportURL = url
        let snapshot = await store.balances(for: trip)
        summaryText = TripExporter.summary(trip: trip, expenses: expenses, balances: snapshot.balances, transfers: snapshot.suggestions)
    }
}

@MainActor
struct InviteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let trip: Trip

    @State private var invite: TripInvite?
    @State private var role: TripRole = .member
    @State private var reservedFor: ParticipantID?
    @State private var expiresInHours = 168
    @State private var error: AppError?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { ErrorBanner(error: error) }.listRowBackground(Color.clear) }
                if let invite {
                    let url = DeepLink.inviteURL(token: invite.token, host: app.env.config.inviteHost)
                    Section {
                        VStack(spacing: 14) {
                            QRCodeView(text: url.absoluteString).frame(width: 200, height: 200)
                                .accessibilityLabel(Text("QR code for the invite link"))
                            Text(invite.displayCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                                .accessibilityLabel(Text("Invite code \(invite.displayCode.map(String.init).joined(separator: " "))"))
                            Text("Expires \(invite.expiresAt.formatted(date: .abbreviated, time: .shortened)) · up to \(invite.maxUses) use(s)")
                                .font(.caption).foregroundStyle(.secondary)
                            ShareLink(item: url, subject: Text("Join \(trip.name)"), message: Text("Join “\(trip.name)” on Asray Split: \(url.absoluteString) — or enter code \(invite.displayCode)")) {
                                Label("Share invite link", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                    } footer: { Text("Anyone with this link or code can join until it expires. You can revoke it at any time.") }
                    Section {
                        Button("Revoke invite", role: .destructive) {
                            Task {
                                do { try await app.env.backend.trips.revokeInvite(invite.id); self.invite = nil; app.show(Toast(message: String(localized: "Invite revoked"))) }
                                catch { self.error = error.asAppError }
                            }
                        }
                    }
                } else {
                    Section("Access") {
                        Picker("Role", selection: $role) {
                            Text("Member").tag(TripRole.member)
                            Text("Admin").tag(TripRole.admin)
                        }
                        Picker("Expires", selection: $expiresInHours) {
                            Text("1 day").tag(24); Text("1 week").tag(168); Text("30 days").tag(720)
                        }
                    }
                    let guests = trip.activeParticipants.filter(\.isGuest)
                    if !guests.isEmpty {
                        Section {
                            Picker("For", selection: $reservedFor) {
                                Text("Anyone").tag(ParticipantID?.none)
                                ForEach(guests) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                            }
                        } footer: { Text("Reserve the invite for a specific traveler so their existing expenses link to their account.") }
                    }
                    Section {
                        Button { Task { await create() } } label: {
                            if working { ProgressView() } else { Text("Create invite") }
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(working).listRowBackground(Color.clear)
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            invite = try await app.env.backend.trips.createInvite(tripID: trip.id, role: role, expiresInHours: expiresInHours,
                                                                  maxUses: reservedFor == nil ? 20 : 1, participantID: reservedFor)
            error = nil
        } catch {
            self.error = error.asAppError
        }
    }
}

@MainActor
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
