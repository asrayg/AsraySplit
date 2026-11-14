import SwiftUI

@MainActor
struct BalancesView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    let tripID: TripID
    @State private var snapshot: BalanceSnapshot = .empty
    @State private var settlements: [CachedSettlement] = []

    var body: some View {
        if let trip = store.trip(tripID) {
            List {
                if snapshot.isProjected {
                    Label("Includes changes not yet confirmed by the server.", systemImage: "icloud.and.arrow.up")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if snapshot.suggestions.isEmpty {
                        Label("Everyone is settled up", systemImage: "checkmark.seal.fill").foregroundStyle(Color.positive)
                    }
                    ForEach(snapshot.suggestions) { transfer in
                        Button { app.sheet = .settleUp(trip.id, transfer) } label: {
                            AdaptiveStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trip.transferSentence(from: transfer.from, to: transfer.to, me: store.me(in: trip)?.id)).foregroundStyle(Color.primary)
                                    Text("Tap to record").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Money(minorUnits: transfer.amountMinor, currency: trip.baseCurrency).formatted()).bold().monospacedDigit()
                            }
                        }
                        .disabled(trip.isArchived)
                        .swipeActions {
                            if canRemind(transfer, in: trip) {
                                Button { Task { await remind(transfer, in: trip) } } label: { Label("Remind", systemImage: "envelope") }
                                    .tint(Color.brand)
                            }
                        }
                        .contextMenu {
                            if canRemind(transfer, in: trip) {
                                Button { Task { await remind(transfer, in: trip) } } label: { Label("Send reminder email", systemImage: "envelope") }
                            }
                        }
                    }
                } header: { Text("Suggested payments") }

                Section {
                    ForEach(snapshot.balances) { balance in
                        DisclosureGroup {
                            explanation(balance, currency: trip.baseCurrency)
                        } label: {
                            AdaptiveStack {
                                Avatar(name: trip.name(of: balance.participantID), size: 32)
                                Text(trip.name(of: balance.participantID))
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(balance.netMinor > 0 ? "is owed" : balance.netMinor < 0 ? "owes" : "settled").font(.caption).foregroundStyle(.secondary)
                                    BalanceText(minor: balance.netMinor, currency: trip.baseCurrency, font: .subheadline.bold())
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: { Text("Balances") }

                if !settlements.isEmpty {
                    Section("Recorded payments") {
                        ForEach(settlements) { cached in
                            let settlement = cached.settlement
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("\(trip.name(of: settlement.fromParticipantId)) → \(trip.name(of: settlement.toParticipantId))")
                                        SyncStateBadge(state: cached.syncState)
                                    }
                                    Text("\(settlement.method.title) · \(settlement.settledAt.formatted(date: .abbreviated, time: .omitted))\(settlement.reference.map { " · \($0)" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(settlement.amount.formatted()).monospacedDigit()
                            }
                            .swipeActions {
                                if !trip.isArchived {
                                    Button(role: .destructive) { Task { do { try await store.deleteSettlement(settlement) } catch { app.report(error) } } } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Balances")
            .toolbar {
                if !trip.isArchived {
                    Button("Record payment") { app.sheet = .settleUp(trip.id, nil) }
                }
            }
            .refreshable { await store.refresh(tripID: tripID) }
            .task(id: store.version) {
                snapshot = await store.balances(for: trip)
                settlements = await store.settlements(tripID: tripID)
            }
        } else {
            ContentUnavailableView("Trip unavailable", systemImage: "suitcase")
        }
    }

    /// The person owed (or an admin) can email a member with an account who owes money.
    private func canRemind(_ transfer: SuggestedTransfer, in trip: Trip) -> Bool {
        let me = store.me(in: trip)?.id
        let debtorIsMember = trip.activeMembers.contains { $0.participantId == transfer.from }
        return debtorIsMember && transfer.from != me && (transfer.to == me || trip.canManage(.admin))
    }

    private func remind(_ transfer: SuggestedTransfer, in trip: Trip) async {
        do {
            let result = try await app.env.backend.ledger.requestPaymentReminder(tripID: trip.id, debtor: transfer.from)
            let name = trip.name(of: transfer.from)
            let message: String = switch (result.queued, result.reason) {
            case (true, _): String(localized: "Reminder sent to \(name)")
            case (_, "already_reminded_today"): String(localized: "\(name) was already reminded today")
            case (_, "opted_out"): String(localized: "\(name) has turned off reminder emails")
            case (_, "no_account"): String(localized: "\(name) doesn’t have an account to email")
            default: String(localized: "\(name) is already settled up")
            }
            app.show(Toast(message: message, style: result.queued ? .success : .info))
        } catch {
            app.report(error)
        }
    }

    private func explanation(_ balance: ParticipantBalance, currency: CurrencyCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Paid for the group", balance.paidMinor, currency)
            row("Own share of expenses", -balance.owedMinor, currency)
            row("Payments sent", balance.settlementsSentMinor, currency)
            row("Payments received", -balance.settlementsReceivedMinor, currency)
            Divider()
            row("Net", balance.netMinor, currency).bold()
        }
        .font(.footnote)
    }

    private func row(_ title: LocalizedStringKey, _ minor: Int64, _ currency: CurrencyCode) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text((minor < 0 ? "−" : "+") + Money(minorUnits: abs(minor), currency: currency).formatted()).monospacedDigit()
        }
    }
}

@MainActor
struct SettleUpView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: TripID
    let suggestion: SuggestedTransfer?

    @State private var from: ParticipantID?
    @State private var to: ParticipantID?
    @State private var amount: Int64?
    @State private var method: PaymentMethod = .cash
    @State private var reference = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var suggested: [SuggestedTransfer] = []
    @State private var error: AppError?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            if let trip = store.trip(tripID) {
                Form {
                    if let error { Section { ErrorBanner(error: error) }.listRowBackground(Color.clear) }
                    Section {
                        Picker("From", selection: $from) {
                            Text("Choose").tag(ParticipantID?.none)
                            ForEach(trip.participants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                        }
                        Picker("To", selection: $to) {
                            Text("Choose").tag(ParticipantID?.none)
                            ForEach(trip.participants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                        }
                        MoneyField(title: "Amount", minorUnits: $amount, currency: trip.baseCurrency, font: .title2.bold())
                        if let owed = suggested.first(where: { $0.from == from && $0.to == to }) {
                            Button("Full amount: \(Money(minorUnits: owed.amountMinor, currency: trip.baseCurrency).formatted())") { amount = owed.amountMinor }
                                .font(.footnote)
                        }
                    }
                    Section("How") {
                        Picker("Method", selection: $method) { ForEach(PaymentMethod.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                        TextField("Reference (optional)", text: $reference)
                        TextField("Note (optional)", text: $note)
                        DatePicker("Date", selection: $date)
                        if let link = paymentAppLink(trip: trip) {
                            Link(destination: link) { Label("Open \(method.title)", systemImage: "arrow.up.forward.app") }
                        }
                    }
                }
                .screenBackground()
                .navigationTitle("Record payment")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Record") { Task { await save(trip) } }
                            .disabled(from == nil || to == nil || from == to || (amount ?? 0) <= 0 || saving)
                    }
                }
                .task {
                    suggested = await store.balances(for: trip).suggestions
                    if let suggestion { from = suggestion.from; to = suggestion.to; amount = suggestion.amountMinor }
                    else if let mine = suggested.first(where: { $0.from == store.me(in: trip)?.id }) ?? suggested.first {
                        from = mine.from; to = mine.to; amount = mine.amountMinor
                    }
                }
            }
        }
    }

    /// Payment apps are opened by deep link only; nothing is paid in-app.
    private func paymentAppLink(trip: Trip) -> URL? {
        guard let amount else { return nil }
        let value = Money(minorUnits: amount, currency: trip.baseCurrency).decimalValue
        switch method {
        case .venmo where trip.baseCurrency == .usd:
            return URL(string: "venmo://paycharge?txn=pay&amount=\(value)&note=\(trip.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        case .paypal:
            return URL(string: "https://www.paypal.com/myaccount/transfer/homepage/pay")
        default:
            return nil
        }
    }

    private func save(_ trip: Trip) async {
        guard let from, let to, let amount else { return }
        saving = true
        defer { saving = false }
        let payload = SettlementPayload(fromParticipantId: from, toParticipantId: to, amountMinor: amount, currency: trip.baseCurrency,
                                        method: method, reference: reference.isEmpty ? nil : reference, note: note.isEmpty ? nil : note, settledAt: date)
        do {
            try await store.recordSettlement(payload, in: trip)
            app.show(Toast(message: String(localized: "Payment recorded"), style: .success))
            dismiss()
        } catch {
            self.error = error.asAppError
        }
    }
}
