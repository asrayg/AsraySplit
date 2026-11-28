import SwiftUI

/// Itinerary, food, packing and info for the crew trip. Checklist ticks are stored on this iPhone only.
@MainActor
struct TripGuideView: View {
    let guide: TripGuide
    @Environment(AppModel.self) private var app
    /// Remembered across launches: reopening the itinerary returns to the last tab.
    @AppStorage("guide.tab") private var tab: Tab = .plan
    @AppStorage("trip.wakeReminders") private var wakeReminders = true
    @State private var showAllergy = false

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
        .fullScreenCover(isPresented: $showAllergy) { AllergyAlertView(message: guide.allergyMessage) }
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(guide.title).font(.headline)
                    .onTapGesture { if app.eggs.tap("coqui", needed: 7) { app.eggs.trigger(.coqui, "🐸 Coquí! Coquí!", rain: ["🐸", "🌿", "🌧️"]) } }
            }
        }
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
            Button { showAllergy = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label("🚨 Show to the server", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                    Text(guide.allergyMessage).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                }
            }
            ShareLink(item: guide.allergyMessage) { Label("Share", systemImage: "square.and.arrow.up") }
        } header: { Text("Allergy message (Spanish)") }
    }

    @ViewBuilder private var pack: some View {
        ForEach(guide.packing) { section in
            Section(section.title) { ChecklistRows(key: "pack.\(section.title)", items: section.items) }
        }
        Section("Outfits by day") { ForEach(guide.outfits) { row($0) } }
    }

    @ViewBuilder private var info: some View {
        Section {
            Toggle("Alarm & wake-up reminders", isOn: $wakeReminders)
                .onChange(of: wakeReminders) { _, on in
                    Task {
                        if on { await app.env.notifications.requestPermission() }
                        await app.env.notifications.scheduleWakeReminders(enabled: on)
                    }
                }
        } footer: {
            Text("Night-before “set your alarm” nudges and morning wake-ups for Sat, Sun and the Dec 1 departures. These are notifications, not alarms — still set a real alarm.")
        }
        Section("🔑 Important codes") {
            ForEach(guide.codes) { code in
                HStack {
                    Text(code.name)
                    Spacer()
                    Text(code.note).font(.title3.monospaced().bold()).textSelection(.enabled)
                }
            }
        }
        flightsSection
        Section("Stay") {
            Link(destination: URL(string: "https://maps.apple.com/?q=\(guide.airbnb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                Label(guide.airbnb, systemImage: "house")
            }
            Label(guide.airport, systemImage: "airplane")
        }
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


/// Full-screen, impossible-to-miss allergy warning to show restaurant staff.
@MainActor
private struct AllergyAlertView: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.red.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Text("🚨⚠️🚨").font(.system(size: 44))
                    Text("ALERGIA / ALLERGY").font(.system(size: 34, weight: .black)).multilineTextAlignment(.center)
                    HStack(spacing: 14) {
                        Text("🥜 MANÍ\nPEANUTS")
                        Text("🥚 HUEVO\nEGGS")
                    }
                    .font(.system(size: 24, weight: .heavy)).multilineTextAlignment(.center)
                    .padding(14).frame(maxWidth: .infinity)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("⚠️ " + message + " ⚠️")
                        .font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.red)
                    Text("No cross-contamination · Sin contaminación cruzada ❌").font(.headline).multilineTextAlignment(.center)
                    Text("🚨⚠️🚨").font(.system(size: 44))
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            VStack {
                HStack { Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 34)).foregroundStyle(.white) }.accessibilityLabel(Text("Close")) }
                Spacer()
            }.padding()
        }
        .onAppear { UIScreen.main.brightness = max(UIScreen.main.brightness, 0.9) }
    }
}
