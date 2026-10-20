import SwiftUI

@MainActor
struct TripsHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @State private var showJoin = false
    @State private var joinCode = ""
    @State private var showSettings = false
    @State private var showArchived = false

    var body: some View {
        List {
            if !store.isOnline {
                ErrorBanner(error: .offline).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            } else if let error = store.lastSyncError, error != .offline {
                ErrorBanner(error: error) { Task { await store.syncNow() } }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if !store.problemOperations.isEmpty {
                NavigationLink {
                    SyncIssuesView()
                } label: {
                    Label("\(store.problemOperations.count) change(s) need attention", systemImage: "exclamationmark.icloud.fill")
                        .foregroundStyle(Color.warning)
                }
            }

            if store.trips.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "suitcase.rolling.fill").font(.largeTitle).foregroundStyle(Color.brand)
                        Text("No trips yet").font(.title3.bold())
                        Text("Create a trip, then invite friends with a link, QR code or short code.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Create a trip") { app.sheet = .createTrip }.buttonStyle(PrimaryButtonStyle())
                        Button("Join with a code") { showJoin = true }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.activeTrips) { trip in
                        NavigationLink(value: Route.trip(trip.id)) { TripRow(trip: trip) }
                    }
                }
                if !store.archivedTrips.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showArchived) {
                            ForEach(store.archivedTrips) { trip in
                                NavigationLink(value: Route.trip(trip.id)) { TripRow(trip: trip) }
                            }
                        } label: {
                            Text("Archived (\(store.archivedTrips.count))")
                        }
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle("Trips")
        .refreshable { await store.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Avatar(name: app.profile?.displayName ?? "?", size: 30)
                }
                .accessibilityLabel(Text("Settings"))
                .accessibilityIdentifier("settingsButton")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { app.sheet = .createTrip } label: { Label("New trip", systemImage: "plus") }
                    Button { showJoin = true } label: { Label("Join with code", systemImage: "person.badge.plus") }
                    Button { app.sheet = .scanReceipt(nil) } label: { Label("Scan receipt", systemImage: "doc.viewfinder") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .accessibilityLabel(Text("Add"))
                .accessibilityIdentifier("addMenu")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Join a trip", isPresented: $showJoin) {
            TextField("Code, e.g. ABCD-EFGH", text: $joinCode).textInputAutocapitalization(.characters)
            Button("Cancel", role: .cancel) { joinCode = "" }
            Button("Continue") {
                let code = joinCode.trimmingCharacters(in: .whitespaces)
                joinCode = ""
                if DeepLink.isValidSecret(code) { app.sheet = .join(secret: code) }
                else { app.show(Toast(message: String(localized: "That code doesn’t look right."), style: .warning)) }
            }
        } message: {
            Text("Enter the 8-character code a trip member shared with you.")
        }
    }
}

@MainActor
struct TripRow: View {
    @Environment(TripStore.self) private var store
    let trip: Trip
    @State private var net: Int64 = 0

    var body: some View {
        HStack(spacing: 14) {
            Text(trip.emoji)
                .font(.title)
                .frame(width: 52, height: 52)
                .background(Color(hex: trip.colorHex).opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(trip.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(net > 0 ? "you’re owed" : net < 0 ? "you owe" : "settled").font(.caption2).foregroundStyle(.secondary)
                if net != 0 { BalanceText(minor: net, currency: trip.baseCurrency, font: .subheadline.bold()) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .task(id: store.version) {
            let snapshot = await store.balances(for: trip)
            net = snapshot.net(for: store.me(in: trip)?.id)
        }
    }

    private var subtitle: String {
        var parts = ["\(trip.activeParticipants.count) " + String(localized: "people")]
        if let start = trip.startDate, let end = trip.endDate { parts.append("\(start.shortDay) – \(end.shortDay)") }
        if trip.isArchived { parts.append(String(localized: "Archived")) }
        return parts.joined(separator: " · ")
    }
}
