import SwiftUI

/// Invite landing: preview the trip, optionally claim a guest name, then join.
@MainActor
struct JoinTripView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let secret: String

    @State private var preview: InvitePreview?
    @State private var error: AppError?
    @State private var claim: ParticipantID?
    @State private var joining = false

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    content(preview)
                } else if let error {
                    VStack(spacing: 16) {
                        ErrorBanner(error: error) { Task { await load() } }
                        Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding()
                } else {
                    ProgressView("Checking invite…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Join trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func content(_ preview: InvitePreview) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(preview.emoji).font(.system(size: 56)).accessibilityHidden(true)
                Text(preview.name).font(.title.bold()).multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    if let inviter = preview.invitedBy { Text("Invited by \(inviter)").foregroundStyle(.secondary) }
                    Text("\(preview.memberCount) member(s) · \(preview.baseCurrency.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                    if let start = preview.startDate, let end = preview.endDate { Text("\(start.shortDay) – \(end.shortDay)").font(.subheadline).foregroundStyle(.secondary) }
                }
                if preview.alreadyMember {
                    Label("You’re already in this trip", systemImage: "checkmark.seal.fill").foregroundStyle(Color.brand)
                    Button("Open trip") { open(preview.tripId) }.buttonStyle(PrimaryButtonStyle())
                } else if preview.exhausted {
                    ErrorBanner(error: .invite(.exhausted))
                } else {
                    if !preview.claimableParticipants.isEmpty {
                        Card {
                            Text("Are you one of these travelers?").font(.headline)
                            Text("Pick your name so expenses already recorded for you count toward your balance.")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(preview.claimableParticipants) { person in
                                Button {
                                    claim = claim == person.id ? nil : person.id
                                } label: {
                                    HStack {
                                        Avatar(name: person.displayName, size: 30)
                                        Text(person.displayName).foregroundStyle(Color.primary)
                                        Spacer()
                                        Image(systemName: claim == person.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(claim == person.id ? Color.brand : Color.secondary)
                                    }
                                    .frame(minHeight: 44)
                                }
                                .accessibilityAddTraits(claim == person.id ? .isSelected : [])
                            }
                            if preview.reservedParticipantId == nil {
                                Button { claim = nil } label: {
                                    HStack {
                                        Text("I’m someone new").foregroundStyle(Color.primary)
                                        Spacer()
                                        Image(systemName: claim == nil ? "checkmark.circle.fill" : "circle").foregroundStyle(claim == nil ? Color.brand : Color.secondary)
                                    }
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                    }
                    if let error { ErrorBanner(error: error) }
                    Button { Task { await join() } } label: {
                        if joining { ProgressView() } else { Text("Join \(preview.name)") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(joining)
                    .accessibilityIdentifier("joinTrip")
                    Text("Members can see the trip’s expenses, receipts and balances.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func load() async {
        error = nil
        do {
            let result = try await app.env.backend.trips.previewInvite(secret: secret)
            preview = result
            claim = result.reservedParticipantId
        } catch {
            self.error = error.asAppError
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            let trip = try await store.acceptInvite(secret: secret, claim: claim)
            app.show(Toast(message: String(localized: "Joined \(trip.name)"), style: .success))
            open(trip.id)
        } catch {
            self.error = error.asAppError
        }
    }

    private func open(_ tripID: TripID) {
        dismiss()
        app.path = [.trip(tripID)]
    }
}
