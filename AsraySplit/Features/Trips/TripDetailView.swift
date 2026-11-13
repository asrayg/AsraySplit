import Charts
import SwiftUI

@MainActor
@Observable
final class TripDetailModel {
    let tripID: TripID
    private(set) var expenses: [CachedExpense] = []
    private(set) var balances: BalanceSnapshot = .empty
    private(set) var canLoadMore = false
    private(set) var totalCount = 0
    var filter = ExpenseFilter()
    private var pageSize = 50
    private var loadedPages = 1

    init(tripID: TripID) { self.tripID = tripID }

    func load(store: TripStore) async {
        guard let trip = store.trip(tripID) else { return }
        balances = await store.balances(for: trip)
        totalCount = (try? await store.local.expenseCount(tripID: tripID)) ?? 0
        if filter.isActive {
            let all = await store.allExpenses(tripID: tripID)
            expenses = all.reversed().filter { filter.matches($0, trip: trip) }
            canLoadMore = false
        } else {
            expenses = await store.expenses(tripID: tripID, query: ExpenseQuery(limit: pageSize * loadedPages, offset: 0))
            canLoadMore = expenses.count < totalCount
        }
    }

    func loadMore(store: TripStore) async {
        guard canLoadMore else { return }
        loadedPages += 1
        await load(store: store)
    }
}

@MainActor
struct TripDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    let tripID: TripID
    @State private var model: TripDetailModel
    @State private var showFilters = false

    init(tripID: TripID) {
        self.tripID = tripID
        _model = State(initialValue: TripDetailModel(tripID: tripID))
    }

    var body: some View {
        if let trip = store.trip(tripID) {
            content(trip)
        } else {
            ContentUnavailableView("Trip unavailable", systemImage: "suitcase", description: Text("It may have been deleted, or you were removed."))
        }
    }

    private func content(_ trip: Trip) -> some View {
        @Bindable var model = model
        return List {
            Section { TripHeader(trip: trip, balances: model.balances) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section {
                AdaptiveStack(spacing: 10) {
                    actionButton("Add", icon: "plus", id: "addExpense", primary: false) { app.sheet = .addExpense(trip.id) }
                    actionButton("Scan", icon: "doc.viewfinder", id: "scanReceipt", primary: true) { app.sheet = .scanReceipt(trip.id) }
                    actionButton("Settle", icon: "arrow.left.arrow.right.circle", id: "settleUp", primary: false) { app.sheet = .settleUp(trip.id, nil) }
                }
                .disabled(trip.isArchived)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))

            if trip.isArchived {
                Label("This trip is archived and read-only.", systemImage: "archivebox").foregroundStyle(.secondary)
            }

            Section {
                NavigationLink(value: Route.balances(trip.id)) {
                    Label("Balances & settle up", systemImage: "scalemass")
                }
                .accessibilityIdentifier("balancesLink")
                NavigationLink { TripGuideView(guide: .puertoRico) } label: { Label("Itinerary", systemImage: "map") }
                NavigationLink(value: Route.photos(trip.id)) { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                NavigationLink(value: Route.chat(trip.id)) { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                NavigationLink(value: Route.activity(trip.id)) { Label("Activity", systemImage: "clock.arrow.circlepath") }
                NavigationLink(value: Route.receipts(trip.id)) { Label("Receipts", systemImage: "doc.text.image") }
                NavigationLink { InsightsView(tripID: trip.id) } label: { Label("Insights", systemImage: "chart.pie") }
            }

            Section {
                if model.expenses.isEmpty {
                    if model.filter.isActive {
                        ContentUnavailableView.search(text: model.filter.query)
                    } else {
                        ContentUnavailableView("No expenses yet", systemImage: "receipt", description: Text("Scan a receipt or add an expense. It works offline too."))
                    }
                }
                ForEach(model.expenses) { cached in
                    NavigationLink(value: Route.expense(trip.id, cached.id)) {
                        ExpenseRow(expense: cached.expense, trip: trip, syncState: cached.syncState, me: store.me(in: trip)?.id)
                    }
                    .swipeActions(edge: .trailing) {
                        if !trip.isArchived {
                            Button(role: .destructive) { Task { await delete(cached.expense) } } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                if model.canLoadMore {
                    ProgressView().frame(maxWidth: .infinity).task { await model.loadMore(store: store) }
                }
            } header: {
                HStack {
                    Text(model.filter.isActive ? "Matching expenses" : "Expenses (\(model.totalCount))")
                    Spacer()
                    Button { showFilters = true } label: {
                        Label(model.filter.activeCount > 0 ? "Filters (\(model.filter.activeCount))" : "Filter", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline)
                    }
                    .textCase(nil)
                }
            }
        }
        .screenBackground()
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.filter.query, prompt: Text("Search description, person, tag or amount"))
        .refreshable { await store.refresh(tripID: trip.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.tripSettings(trip.id)) { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("Trip settings"))
            }
        }
        .sheet(isPresented: $showFilters) { ExpenseFilterView(filter: $model.filter, trip: trip) }
        .task(id: "\(store.version)-\(model.filter.hashValueKey)") { await model.load(store: store) }
    }

    private func actionButton(_ title: LocalizedStringKey, icon: String, id: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        }
        .buttonStyle(primary ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
        .accessibilityIdentifier(id)
    }

    private func delete(_ expense: Expense) async {
        do {
            try await store.deleteExpense(expense)
            app.show(Toast(message: String(localized: "Expense deleted"), style: .info, undo: { [store] in
                if let current = await store.expense(expense.id) { try? await store.restoreExpense(current.expense) }
            }))
        } catch {
            app.report(error)
        }
    }
}

extension ExpenseFilter {
    /// Stable key for `.task(id:)` reloads.
    var hashValueKey: String {
        "\(query)|\(payer?.uuidString ?? "")|\(participant?.uuidString ?? "")|\(category?.rawValue ?? "")|\(paymentMethod?.rawValue ?? "")|\(tag ?? "")|\(String(describing: hasReceipt))|\(onlyUnsynced)|\(from?.timeIntervalSince1970 ?? 0)|\(to?.timeIntervalSince1970 ?? 0)|\(minBaseMinor ?? -1)|\(maxBaseMinor ?? -1)"
    }
}

@MainActor
private struct TripHeader: View {
    @Environment(TripStore.self) private var store
    let trip: Trip
    let balances: BalanceSnapshot

    var body: some View {
        let summary = store.cachedTrip(trip.id)?.summary
        let me = store.me(in: trip)?.id
        let net = balances.net(for: me)
        VStack(alignment: .leading, spacing: 14) {
            AdaptiveStack(spacing: 12) {
                Text(trip.emoji).font(.largeTitle).accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(trip.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if let start = trip.startDate, let end = trip.endDate {
                        Text("\(start.shortDay) – \(end.shortDay) · \(trip.baseCurrency.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(net > 0 ? "You’re owed" : net < 0 ? "You owe" : "You’re settled up").font(.subheadline).foregroundStyle(.secondary)
                    BalanceText(minor: net, currency: trip.baseCurrency, font: .system(.title, design: .rounded).bold())
                }
                Spacer()
                if balances.isProjected {
                    Label("Includes unsynced changes", systemImage: "icloud.and.arrow.up").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    AdaptiveStack {
                        Text("Spent").font(.caption.bold())
                        Spacer()
                        Text(Money(minorUnits: summary.totalSpentMinor, currency: trip.baseCurrency).formatted())
                            .font(.caption.monospacedDigit())
                        if let budget = trip.budgetMinor, budget > 0 {
                            Text("of \(Money(minorUnits: budget, currency: trip.baseCurrency).formatted())").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let budget = trip.budgetMinor, budget > 0 {
                        ProgressView(value: min(Double(summary.totalSpentMinor) / Double(budget), 1))
                            .tint(summary.totalSpentMinor > budget ? Color.negative : Color.brand)
                            .accessibilityLabel(Text("Budget used"))
                            .accessibilityValue(Text("\(Int((Double(summary.totalSpentMinor) / Double(budget) * 100).rounded())) percent"))
                    }
                }
            }
        }
        .padding(18)
        .background(Color(hex: trip.colorHex).opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

@MainActor
struct ExpenseRow: View {
    let expense: Expense
    let trip: Trip
    var syncState: SyncState = .synced
    var me: ParticipantID?

    var body: some View {
        AdaptiveStack(spacing: 12) {
            Image(systemName: expense.category.icon)
                .font(.headline)
                .foregroundStyle(Color.brand)
                .frame(width: 40, height: 40)
                .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(expense.title).font(.subheadline.bold()).lineLimit(1)
                    SyncStateBadge(state: syncState)
                    if !expense.receiptIds.isEmpty { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary).accessibilityLabel(Text("Has receipt")) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(expense.original.formatted()).font(.subheadline.bold().monospacedDigit())
                if let me, let line = myLine(me) { Text(line.text).font(.caption2).foregroundStyle(line.color) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let payers = expense.payments.map { trip.name(of: $0.participantId) }.joined(separator: ", ")
        return String(localized: "\(payers) paid · \(expense.spentAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private func myLine(_ me: ParticipantID) -> (text: String, color: Color)? {
        let paid = expense.payments.first { $0.participantId == me }?.baseAmountMinor ?? 0
        let owed = expense.baseShare(for: me)
        let net = paid - owed
        guard net != 0 else { return owed == 0 && paid == 0 ? (String(localized: "not involved"), .secondary) : nil }
        let amount = Money(minorUnits: abs(net), currency: expense.baseCurrency).formatted()
        return net > 0 ? (String(localized: "you lent \(amount)"), .positive) : (String(localized: "you borrowed \(amount)"), .negative)
    }
}

@MainActor
struct ExpenseFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: ExpenseFilter
    let trip: Trip
    @State private var draft = ExpenseFilter()

    var body: some View {
        NavigationStack {
            Form {
                Section("People") {
                    Picker("Paid by", selection: $draft.payer) {
                        Text("Anyone").tag(ParticipantID?.none)
                        ForEach(trip.participants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                    }
                    Picker("Includes", selection: $draft.participant) {
                        Text("Anyone").tag(ParticipantID?.none)
                        ForEach(trip.participants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                    }
                }
                Section("Details") {
                    Picker("Category", selection: $draft.category) {
                        Text("Any").tag(ExpenseCategory?.none)
                        ForEach(ExpenseCategory.allCases) { Label($0.title, systemImage: $0.icon).tag(ExpenseCategory?.some($0)) }
                    }
                    Picker("Payment method", selection: $draft.paymentMethod) {
                        Text("Any").tag(PaymentMethod?.none)
                        ForEach(PaymentMethod.allCases) { Text($0.title).tag(PaymentMethod?.some($0)) }
                    }
                    Picker("Receipt", selection: $draft.hasReceipt) {
                        Text("Any").tag(Bool?.none)
                        Text("With receipt").tag(Bool?.some(true))
                        Text("Without receipt").tag(Bool?.some(false))
                    }
                    Toggle("Only unsynced changes", isOn: $draft.onlyUnsynced)
                }
                Section("Date") {
                    Toggle("From", isOn: Binding(get: { draft.from != nil }, set: { draft.from = $0 ? (trip.startDate ?? .now) : nil }))
                    if draft.from != nil { DatePicker("From", selection: Binding(get: { draft.from ?? .now }, set: { draft.from = $0 }), displayedComponents: .date) }
                    Toggle("To", isOn: Binding(get: { draft.to != nil }, set: { draft.to = $0 ? .now : nil }))
                    if draft.to != nil { DatePicker("To", selection: Binding(get: { draft.to ?? .now }, set: { draft.to = $0 }), displayedComponents: .date) }
                }
                Section("Amount (\(trip.baseCurrency.rawValue))") {
                    MoneyField(title: "Minimum", minorUnits: $draft.minBaseMinor, currency: trip.baseCurrency)
                    MoneyField(title: "Maximum", minorUnits: $draft.maxBaseMinor, currency: trip.baseCurrency)
                }
            }
            .screenBackground()
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { draft = ExpenseFilter(query: filter.query) } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { filter = draft; dismiss() } }
            }
            .onAppear { draft = filter }
        }
        .presentationDetents([.medium, .large])
    }
}
