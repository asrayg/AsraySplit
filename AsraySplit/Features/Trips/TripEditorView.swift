import SwiftUI

/// Create or edit a trip. Creation requires a connection (the server assigns membership).
@MainActor
struct TripEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: Trip?

    @State private var draft = TripDraft()
    @State private var hasDates = true
    @State private var budget: Int64?
    @State private var guestName = ""
    @State private var saving = false
    @State private var error: AppError?

    private let emojis = ["✈️", "🏝️", "⛷️", "🚗", "🏕️", "🏙️", "🎉", "🏠", "🚆", "🗺️"]
    private let colors = ["23C58A", "786EF2", "F5A34A", "EF6A6A", "3BA7F0", "C46FE0"]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { ErrorBanner(error: error) }.listRowBackground(Color.clear) }
                Section("Trip") {
                    TextField("Trip name", text: $draft.name).accessibilityIdentifier("tripName")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(emojis, id: \.self) { value in
                                Button(value) { draft.emoji = value }
                                    .font(.title2).padding(8)
                                    .background(draft.emoji == value ? Color.brand.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel(Text("Icon \(value)"))
                                    .accessibilityAddTraits(draft.emoji == value ? .isSelected : [])
                            }
                        }
                    }
                    HStack {
                        ForEach(colors, id: \.self) { hex in
                            Button { draft.colorHex = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: draft.colorHex == hex ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(Text("Color"))
                            .accessibilityAddTraits(draft.colorHex == hex ? .isSelected : [])
                        }
                    }
                }
                Section("Dates") {
                    Toggle("Set trip dates", isOn: $hasDates)
                    if hasDates {
                        DatePicker("Starts", selection: Binding(get: { draft.startDate ?? .now }, set: { draft.startDate = $0 }), displayedComponents: .date)
                        DatePicker("Ends", selection: Binding(get: { draft.endDate ?? .now }, set: { draft.endDate = $0 }), in: (draft.startDate ?? .distantPast)..., displayedComponents: .date)
                    }
                    Picker("Time zone", selection: $draft.timezone) {
                        ForEach(Self.timezones(including: draft.timezone), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }
                }
                Section {
                    CurrencyPicker(selection: $draft.baseCurrency, title: "Trip currency")
                        .disabled(existing != nil && !(existing?.canManage(.admin) ?? false))
                    MoneyField(title: "Budget (optional)", minorUnits: $budget, currency: draft.baseCurrency)
                } header: { Text("Money") } footer: {
                    Text("Balances are shown in the trip currency. Expenses in other currencies are converted with the rate saved on each expense.")
                }
                if existing == nil {
                    Section {
                        ForEach(draft.guestNames, id: \.self) { Text($0) }
                            .onDelete { draft.guestNames.remove(atOffsets: $0) }
                        HStack {
                            TextField("Add a traveler’s name", text: $guestName).onSubmit(addGuest)
                            Button("Add", action: addGuest).disabled(guestName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: { Text("Travelers") } footer: {
                        Text("Add people now even if they never install the app. Anyone you invite later can claim their name.")
                    }
                }
            }
            .screenBackground()
            .navigationTitle(existing == nil ? "New trip" : "Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(!draft.isValid || saving)
                        .accessibilityIdentifier("saveTrip")
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let existing, draft.name.isEmpty else { return }
        draft = TripDraft(trip: existing)
        hasDates = existing.startDate != nil
        budget = existing.budgetMinor
    }

    private func addGuest() {
        let name = guestName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !draft.guestNames.contains(name) else { return }
        draft.guestNames.append(name)
        guestName = ""
    }

    private func save() async {
        addGuest()
        saving = true
        defer { saving = false }
        var final = draft
        final.budgetMinor = budget
        if !hasDates { final.startDate = nil; final.endDate = nil }
        do {
            if let existing {
                try await store.updateTrip(final, expectedRevision: existing.revision)
            } else {
                let trip = try await store.createTrip(final)
                app.path = [.trip(trip.id)]
                app.show(Toast(message: String(localized: "\(trip.name) created"), style: .success))
                if app.env.notifications.authorization == .notDetermined { await app.env.notifications.requestPermission() }
            }
            dismiss()
        } catch {
            self.error = error.asAppError
        }
    }

    static func timezones(including current: String) -> [String] {
        Array(Set(TimeZone.knownTimeZoneIdentifiers + [current])).sorted()
    }
}
