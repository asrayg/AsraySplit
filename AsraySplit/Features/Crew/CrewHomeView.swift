import SwiftUI

/// Root screen for the crew build: straight into the hard-coded Puerto Rico trip. No trip list,
/// creation or invites.
@MainActor
struct CrewHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        Group {
            if store.trip(CrewMember.tripID) != nil {
                TripDetailView(tripID: CrewMember.tripID)
            } else {
                VStack(spacing: 18) {
                    if let error = app.crewJoinError {
                        ContentUnavailableView("Couldn’t open the trip", systemImage: "wifi.exclamationmark", description: Text(error))
                        Button("Try again") { Task { await app.joinCrewTrip() } }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        ProgressView()
                        Text("Opening Puerto Rico trip…").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas.ignoresSafeArea())
                .navigationTitle("🇵🇷 Puerto Rico")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Avatar(name: app.profile?.displayName ?? "?", size: 30) }
                    .accessibilityLabel(Text("Settings"))
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            await app.joinCrewTrip()
            #if DEBUG
            // Debug-only shortcut for screenshots: launch with -openGuide.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-openGuide") { app.tab = .plan }
            if let i = args.firstIndex(of: "-openTab"), i + 1 < args.count, let tab = AppTab(rawValue: args[i + 1]) { app.tab = tab }
            #endif
        }

    }
}
