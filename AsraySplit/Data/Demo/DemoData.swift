import Foundation

/// Sample content for demo mode (App Review, previews, first-run exploration).
/// It is written only into an `InMemoryServer`; there is no code path that uploads it to Supabase.
enum DemoData {
    static let demoUserID = UUID(uuidString: "00000000-DE30-4000-8000-000000000001")!

    static func seed(_ server: InMemoryServer, user: UserID = demoUserID, now: Date = .now) async {
        await server.ensureProfile(user, name: String(localized: "You"))
        guard (try? await server.trips(for: user).isEmpty) == true else { return }

        var draft = TripDraft()
        draft.name = "Lisbon Escape"
        draft.emoji = "🌊"
        draft.baseCurrency = .eur
        draft.timezone = "Europe/Lisbon"
        draft.startDate = now.addingTimeInterval(-3 * 86_400)
        draft.endDate = now.addingTimeInterval(4 * 86_400)
        draft.budgetMinor = 200_000
        draft.guestNames = ["Sam", "Maya", "Jordan"]
        guard let trip = try? await server.createTrip(draft, by: user) else { return }
        let ids = trip.participants.map(\.id)
        let me = trip.participant(forUser: user)!.id

        func equal(_ title: String, _ amount: Int64, payer: ParticipantID, category: ExpenseCategory, hoursAgo: Double, method: PaymentMethod = .card) async {
            guard let shares = try? SplitRule.equal(ids).allocate(total: amount) else { return }
            let payload = ExpensePayload(title: title, category: category, paymentMethod: method, spentAt: now.addingTimeInterval(-hoursAgo * 3600),
                                         splitMethod: .equal, amountMinor: amount, currency: .eur,
                                         payments: [.init(participantId: payer, amountMinor: amount)],
                                         allocations: shares.map { .init(participantId: $0.key, amountMinor: $0.value) },
                                         tags: method == .cash ? ["cash"] : [])
            if let data = try? JSONCoding.encoder.encode(payload) { _ = try? await server.createExpense(trip.id, payload: data, by: user) }
        }
        await equal("Taberna da Rua", 18_640, payer: me, category: .food, hoursAgo: 2)
        await equal("Airport transfer", 5_400, payer: ids[1], category: .transport, hoursAgo: 50)
        await equal("Alfama apartment", 96_000, payer: ids[2], category: .lodging, hoursAgo: 70)
        await equal("Pastéis de Belém", 1_260, payer: ids[3], category: .food, hoursAgo: 26, method: .cash)
        await equal("Tram 28 tickets", 1_200, payer: me, category: .transport, hoursAgo: 24, method: .cash)
    }
}
