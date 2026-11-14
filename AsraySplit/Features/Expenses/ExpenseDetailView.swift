import SwiftUI

@MainActor
struct ExpenseDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: TripID
    let expenseID: ExpenseID

    @State private var cached: CachedExpense?
    @State private var loaded = false
    @State private var editing = false
    @State private var duplicating = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let cached, let trip = store.trip(tripID) {
                content(cached, trip: trip)
            } else if loaded {
                ContentUnavailableView("Expense unavailable", systemImage: "receipt", description: Text("It may have been deleted on another device."))
            } else {
                ProgressView()
            }
        }
        .task(id: store.version) {
            cached = await store.expense(expenseID)
            loaded = true
        }
    }

    private func content(_ cached: CachedExpense, trip: Trip) -> some View {
        let expense = cached.expense
        let operation = store.operation(for: expense.id)
        return List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: expense.category.icon).font(.largeTitle).foregroundStyle(Color.brand)
                        .frame(width: 70, height: 70).background(Color.brand.opacity(0.12), in: Circle()).accessibilityHidden(true)
                    Text(expense.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(expense.original.formatted()).font(.system(.largeTitle, design: .rounded).bold().monospacedDigit())
                    if expense.isForeignCurrency {
                        Text("\(expense.base.formatted()) at 1 \(expense.originalCurrency.rawValue) = \(NSDecimalNumber(decimal: expense.exchangeRate).stringValue) \(expense.baseCurrency.rawValue)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Rate: \(expense.rateProvider ?? "manual")\(expense.rateDate.map { ", " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(expense.spentAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if expense.isDeleted { Label("Deleted", systemImage: "trash").foregroundStyle(Color.negative).font(.subheadline.bold()) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            if let operation, operation.state != .pending {
                Section { SyncProblemView(operation: operation) }
            } else if cached.syncState == .pending {
                Section { Label("Saved on this iPhone. Waiting to sync.", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary) }
            }

            Section("Details") {
                LabeledContent("Paid by", value: expense.payments.map { trip.name(of: $0.participantId) }.joined(separator: ", "))
                LabeledContent("Method") { Label(expense.paymentMethod.title, systemImage: expense.paymentMethod.icon) }
                LabeledContent("Split", value: expense.splitMethod.title)
                LabeledContent("Category", value: expense.category.title)
                if let merchant = expense.merchant { LabeledContent("Merchant", value: merchant) }
                if !expense.tags.isEmpty { LabeledContent("Tags", value: expense.tags.map { "#\($0)" }.joined(separator: " ")) }
                if let notes = expense.notes { Text(notes).font(.callout) }
            }

            if !expense.items.isEmpty {
                Section("Items") {
                    ForEach(expense.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.quantity == 1 ? item.name : "\(NSDecimalNumber(decimal: item.quantity).stringValue)× \(item.name)")
                                Spacer()
                                Text(Money(minorUnits: item.amountMinor, currency: expense.originalCurrency).formatted()).monospacedDigit()
                            }
                            Text(item.assignees.map { trip.name(of: $0.participantId) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    extrasRow("Tax", expense.taxMinor, expense)
                    extrasRow("Service fee", expense.serviceFeeMinor, expense)
                    extrasRow("Tip", expense.tipMinor, expense)
                    extrasRow("Discount", expense.discountMinor.map { -$0 }, expense)
                }
            }

            Section {
                ForEach(expense.allocations, id: \.participantId) { share in
                    HStack {
                        Avatar(name: trip.name(of: share.participantId), size: 30)
                        VStack(alignment: .leading) {
                            Text(trip.name(of: share.participantId))
                            if let input = share.inputValue, expense.splitMethod == .percentage || expense.splitMethod == .shares {
                                Text(expense.splitMethod == .percentage ? "\(NSDecimalNumber(decimal: input).stringValue)%" : "\(NSDecimalNumber(decimal: input).stringValue) share(s)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(Money(minorUnits: share.amountMinor, currency: expense.originalCurrency).formatted()).bold().monospacedDigit()
                            if expense.isForeignCurrency, let base = share.baseAmountMinor {
                                Text(Money(minorUnits: base, currency: expense.baseCurrency).formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("Who owes what") }

            if !expense.receiptIds.isEmpty {
                Section("Receipt") {
                    ForEach(expense.receiptIds, id: \.self) { id in ReceiptThumbnailRow(receiptID: id, tripID: tripID) }
                }
            }

            if !trip.isArchived {
                Section {
                    if expense.isDeleted {
                        Button { Task { await restore(expense) } } label: { Label("Restore expense", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }.accessibilityIdentifier("editExpense")
                        Button { duplicating = true } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete expense", systemImage: "trash") }
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle("Expense")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { ExpenseEditorView(tripID: tripID, editing: expense) }
        .sheet(isPresented: $duplicating) { ExpenseEditorView(tripID: tripID, editing: nil, duplicating: expense) }
        .confirmationDialog("Delete this expense?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(expense) } }
        } message: {
            Text("Balances update for everyone. The expense stays in the activity history and can be restored.")
        }
    }

    @ViewBuilder
    private func extrasRow(_ title: LocalizedStringKey, _ minor: Int64?, _ expense: Expense) -> some View {
        if let minor, minor != 0 {
            LabeledContent(title) { Text(Money(minorUnits: minor, currency: expense.originalCurrency).formatted()).monospacedDigit() }
        }
    }

    private func delete(_ expense: Expense) async {
        do {
            try await store.deleteExpense(expense)
            app.show(Toast(message: String(localized: "Expense deleted"), undo: { [store] in
                if let current = await store.expense(expense.id) { try? await store.restoreExpense(current.expense) }
            }))
            dismiss()
        } catch { app.report(error) }
    }

    private func restore(_ expense: Expense) async {
        do { try await store.restoreExpense(expense) } catch { app.report(error) }
    }
}

/// Explains a failed or conflicting change and offers the user's choices.
@MainActor
struct SyncProblemView: View {
    @Environment(TripStore.self) private var store
    let operation: OutboxOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if operation.state == .conflict {
                Label("Changed on another device", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(Color.warning)
                Text("Someone saved a newer version while your edit was waiting. Choose which version to keep.").font(.footnote)
                HStack {
                    Button("Keep theirs") { Task { await store.discard(operation) } }.buttonStyle(SecondaryButtonStyle())
                    Button("Keep mine") { Task { await store.keepMine(operation) } }.buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Label("Couldn’t sync this change", systemImage: "exclamationmark.icloud.fill").font(.headline).foregroundStyle(Color.negative)
                Text(operation.errorMessage ?? String(localized: "The server rejected this change.")).font(.footnote)
                HStack {
                    Button("Discard", role: .destructive) { Task { await store.discard(operation) } }.buttonStyle(SecondaryButtonStyle())
                    Button("Retry") { Task { await store.retry(operation) } }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

@MainActor
struct SyncIssuesView: View {
    @Environment(TripStore.self) private var store

    var body: some View {
        List {
            if store.problemOperations.isEmpty {
                ContentUnavailableView("All changes synced", systemImage: "checkmark.icloud")
            }
            ForEach(store.problemOperations) { operation in
                Section(store.trip(operation.tripID)?.name ?? String(localized: "Trip")) {
                    Text(operation.kind.title).font(.subheadline.bold())
                    SyncProblemView(operation: operation)
                }
            }
        }
        .screenBackground()
        .navigationTitle("Sync issues")
    }
}

extension OutboxKind {
    var title: String {
        switch self {
        case .createExpense: String(localized: "New expense")
        case .updateExpense: String(localized: "Expense edit")
        case .deleteExpense: String(localized: "Expense deletion")
        case .restoreExpense: String(localized: "Expense restore")
        case .recordSettlement: String(localized: "Payment")
        case .deleteSettlement: String(localized: "Payment deletion")
        }
    }
}
