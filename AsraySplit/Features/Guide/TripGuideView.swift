import SwiftUI

/// Itinerary, food, packing and info for the crew trip. Checklist ticks are stored on this iPhone only.
@MainActor
struct TripGuideView: View {
    let guide: TripGuide
    /// Remembered across launches: reopening the itinerary returns to the last tab.
    @AppStorage("guide.tab") private var tab: Tab = .plan

    enum Tab: String, CaseIterable, Identifiable { case plan = "Plan", food = "Food", pack = "Pack", info = "Info"; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if tab == .plan {
                DayPager(guide: guide)
            } else {
                List {
                    switch tab {
                    case .food: food
                    case .pack: pack
                    default: info
                    }
                }
                .screenBackground()
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var flightsSection: some View {
        Section("Flights") {
            ForEach(guide.flights) { flight in
                VStack(alignment: .leading, spacing: 4) {
                    Text(flight.person).font(.headline)
                    Text(flight.from).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Label(flight.arrives, systemImage: "airplane.arrival")
                        Spacer()
                        Label(flight.returns, systemImage: "airplane.departure")
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var food: some View {
        Section("Restaurants") { ForEach(guide.restaurants) { row($0) } }
        Section("Must try") { ChecklistRows(key: "food", items: guide.foodChecklist) }
        Section("Cocktails & local alcohol") { ForEach(guide.drinks) { row($0) } }
        Section("Non-alcoholic") { ForEach(guide.softDrinks) { row($0) } }
        Section {
            Text(guide.allergyMessage).textSelection(.enabled)
            ShareLink(item: guide.allergyMessage) { Label("Share", systemImage: "square.and.arrow.up") }
        } header: { Text("Allergy message (Spanish)") } footer: { Text("Show this to staff when ordering.") }
    }

    @ViewBuilder private var pack: some View {
        ForEach(guide.packing) { section in
            Section(section.title) { ChecklistRows(key: "pack.\(section.title)", items: section.items) }
        }
        Section("Outfits by day") { ForEach(guide.outfits) { row($0) } }
    }

    @ViewBuilder private var info: some View {
        flightsSection
        Section("Stay") {
            Link(destination: URL(string: "https://maps.apple.com/?q=\(guide.airbnb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                Label(guide.airbnb, systemImage: "house")
            }
            Label(guide.airport, systemImage: "airplane")
        }
        Section("Before the trip") { ChecklistRows(key: "booking", items: guide.bookingChecklist) }
        Section("Getting around") { ForEach(guide.transport) { row($0) } }
        Section("Good to know") { ForEach(guide.info) { row($0) } }
    }

    private func row(_ pick: TripGuide.Pick) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pick.name)
            Text(pick.note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Tickable list persisted in UserDefaults (per device, per list key).
@MainActor
private struct ChecklistRows: View {
    let key: String
    let items: [String]
    @AppStorage private var stored: String

    init(key: String, items: [String]) {
        self.key = key
        self.items = items
        _stored = AppStorage(wrappedValue: "", "guide.check.\(key)")
    }

    private var checked: Set<String> { Set(stored.split(separator: "\n").map(String.init)) }

    var body: some View {
        ForEach(items, id: \.self) { item in
            let done = checked.contains(item)
            Button {
                var set = checked
                if done { set.remove(item) } else { set.insert(item) }
                stored = set.sorted().joined(separator: "\n")
            } label: {
                HStack {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.brand : .secondary)
                    Text(item).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(done ? .isSelected : [])
        }
    }
}
