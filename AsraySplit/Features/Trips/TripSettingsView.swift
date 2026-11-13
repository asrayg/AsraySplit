import SwiftUI

@MainActor
struct TripSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    let tripID: TripID

    @State private var renaming: Participant?
    @State private var renameText = ""
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
        List {
            Section("People") {
                ForEach(trip.activeParticipants) { person in
                    HStack {
                        Avatar(name: person.displayName, size: 30)
                        Text(person.displayName)
                        if person.userId == store.currentUserID { Text("you").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Rename") { renameText = person.displayName; renaming = person }.font(.subheadline)
                    }
                }
            }

            Section("Export") {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Export CSV", systemImage: "tablecells") }
                }
                ShareLink(item: summaryText) { Label("Share summary", systemImage: "text.alignleft") }
            }
        }
        .screenBackground()
        .navigationTitle("Trip settings")
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renaming { Task { do { try await store.renameParticipant(renaming, name: renameText) } catch { app.report(error) } } }
            }
        }
        .task(id: store.version) { await prepareExport(trip) }
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

