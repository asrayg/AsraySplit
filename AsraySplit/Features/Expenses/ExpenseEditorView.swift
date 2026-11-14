import SwiftUI

@MainActor
struct ExpenseEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: TripID
    let editing: Expense?
    var duplicating: Expense?

    @State private var model: ExpenseEditorModel?
    @State private var saving = false
    @State private var customTag = ""
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            Group {
                if let model { form(model) } else { ProgressView() }
            }
            .navigationTitle(editing == nil ? (duplicating == nil ? "Add expense" : "Duplicate expense") : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!(model?.canSave ?? false) || saving)
                        .accessibilityIdentifier("saveExpense")
                }
            }
        }
        .task { await setUp() }
    }

    private func setUp() async {
        guard model == nil, let trip = store.trip(tripID) else { return }
        let defaults = try? await store.local.value(DefaultSplit.self, forKey: ExpenseEditorModel.defaultsKey(tripID))
        model = ExpenseEditorModel(trip: trip, editing: editing, duplicating: duplicating, defaults: defaults, me: store.me(in: trip)?.id)
    }

    @ViewBuilder
    private func form(_ model: ExpenseEditorModel) -> some View {
        @Bindable var model = model
        Form {
            if let error { Section { ErrorBanner(error: error) }.listRowBackground(Color.clear) }
            Section {
                TextField("What was it for?", text: $model.title).accessibilityIdentifier("expenseTitle")
                HStack(alignment: .firstTextBaseline) {
                    Menu {
                        ForEach(Array(Set(CurrencyCode.common + [model.trip.baseCurrency, model.currency])).sorted(), id: \.self) { code in
                            Button(code.rawValue) { model.setCurrency(code); Task { await model.loadRate(using: app.env.backend.rates) } }
                        }
                    } label: {
                        Text(model.currency.rawValue).font(.headline).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.surfaceRaised, in: Capsule())
                    }
                    .accessibilityLabel(Text("Currency \(model.currency.rawValue)"))
                    MoneyField(title: "0", minorUnits: $model.amountMinor, currency: model.currency, allowNegative: true,
                               font: .system(size: 34, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("expenseAmount")
                }
                if model.needsRate { rateRow(model) }
                DatePicker("Date", selection: $model.spentAt)
            }

            Section("Paid by") {
                Picker("Paid by", selection: $model.payerID) {
                    ForEach(model.trip.activeParticipants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                }
                Picker("Method", selection: $model.paymentMethod) {
                    ForEach(PaymentMethod.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }

            splitSection(model)

            Section("Category") {
                Picker("Category", selection: $model.category) {
                    ForEach(ExpenseCategory.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }

            Section("Tags & notes") {
                if !model.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(model.tags, id: \.self) { tag in
                                Button { model.tags.removeAll { $0 == tag } } label: {
                                    Text("#\(tag)")
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.brand.opacity(0.15), in: Capsule())
                                }
                                .accessibilityLabel(Text("Remove tag \(tag)"))
                            }
                        }
                    }
                }
                HStack {
                    TextField("Add tag (e.g. reimbursable)", text: $customTag)
                        .textInputAutocapitalization(.never)
                        .onSubmit { model.addTag(customTag); customTag = "" }
                    Button("Add") { model.addTag(customTag); customTag = "" }.disabled(customTag.isEmpty)
                }
                TextField("Merchant (optional)", text: $model.merchant)
                TextField("Notes", text: $model.notes, axis: .vertical).lineLimit(1...4)
            }

            if let message = model.validationMessage {
                Section { Label(message, systemImage: "info.circle").foregroundStyle(.secondary).font(.footnote) }
            }
        }
        .screenBackground()
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func rateRow(_ model: ExpenseEditorModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("1 \(model.currency.rawValue) =")
                DecimalField(title: "Rate", value: $model.exchangeRate, maxFractionDigits: 8)
                    .multilineTextAlignment(.trailing)
                Text(model.trip.baseCurrency.rawValue)
                Button { Task { await model.loadRate(using: app.env.backend.rates) } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(Text("Fetch exchange rate"))
            }
            Group {
                switch model.rateStatus {
                case .loading: Text("Fetching rate…")
                case .loaded(let provider, let asOf): Text("Rate from \(provider) for \(asOf.formatted(date: .abbreviated, time: .omitted)). Saved with this expense.")
                case .failed(let message): Text(message).foregroundStyle(Color.warning)
                case .manual: Text("Manual rate. It’s saved with this expense and never recalculated.")
                case .notNeeded: EmptyView()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let base = model.baseAmount { Text("≈ \(base.formatted()) in trip currency").font(.caption.bold()) }
        }
        .task { if model.exchangeRate == nil { await model.loadRate(using: app.env.backend.rates) } }
    }

    @ViewBuilder
    private func splitSection(_ model: ExpenseEditorModel) -> some View {
        Section {
            Picker("Split", selection: Binding(get: { model.splitMethod }, set: { model.setSplitMethod($0) })) {
                ForEach(model.splitMethod == .itemized ? SplitMethod.manual + [.itemized] : SplitMethod.manual) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("splitMethod")
            if model.splitMethod == .itemized {
            }
            let shares = (try? model.allocation.get()) ?? [:]
            ForEach(model.participants) { person in
                SplitRow(model: model, person: person, share: shares[person.id])
            }
            if let remaining = model.remainingExactMinor, remaining != 0 {
                Label("\(Money(minorUnits: remaining, currency: model.currency).formatted()) left to assign", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Color.warning)
            }
            if let remaining = model.remainingPercent, remaining != 0 {
                Label("\(NSDecimalNumber(decimal: remaining).stringValue)% left to assign", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Color.warning)
            }
        } header: {
            Text("Split")
        }
    }

    private func save() async {
        guard let model else { return }
        saving = true
        defer { saving = false }
        do {
            let payload = try model.makePayload()
            try await store.saveExpense(payload, in: model.trip, editing: editing)
            try? await store.local.setValue(model.defaultSplit, forKey: ExpenseEditorModel.defaultsKey(model.trip.id))
            app.show(Toast(message: store.isOnline ? String(localized: "Expense saved") : String(localized: "Saved offline — will sync later"), style: .success))
            dismiss()
        } catch {
            self.error = error.asAppError
        }
    }
}

@MainActor
private struct SplitRow: View {
    @Bindable var model: ExpenseEditorModel
    let person: Participant
    let share: Int64?

    var body: some View {
        let included = model.included.contains(person.id)
        HStack(spacing: 10) {
            Button { model.toggle(person.id) } label: {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(included ? Color.brand : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(person.displayName))
            .accessibilityValue(Text(included ? "Included" : "Not included"))
            .disabled(model.splitMethod == .itemized)
            Text(person.displayName).lineLimit(1)
            Spacer()
            if included {
                input
                if model.splitMethod != .exact, let share {
                    Text(Money(minorUnits: share, currency: model.currency).formatted())
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        switch model.splitMethod {
        case .exact:
            MoneyField(title: "0", minorUnits: Binding(get: { model.exactValues[person.id] }, set: { model.exactValues[person.id] = $0 }), currency: model.currency, allowNegative: true)
                .multilineTextAlignment(.trailing).frame(maxWidth: 110)
        case .percentage:
            HStack(spacing: 2) {
                DecimalField(title: "0", value: Binding(get: { model.percentValues[person.id] }, set: { model.percentValues[person.id] = $0 }), maxFractionDigits: 4)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 70)
                Text("%").foregroundStyle(.secondary)
            }
        case .shares:
            DecimalField(title: "1", value: Binding(get: { model.shareValues[person.id] }, set: { model.shareValues[person.id] = $0 }), maxFractionDigits: 3)
                .multilineTextAlignment(.trailing).frame(maxWidth: 60)
                .accessibilityLabel(Text("Shares for \(person.displayName)"))
        case .adjustment:
            MoneyField(title: "+0", minorUnits: Binding(get: { model.adjustmentValues[person.id] }, set: { model.adjustmentValues[person.id] = $0 }), currency: model.currency, allowNegative: true)
                .multilineTextAlignment(.trailing).frame(maxWidth: 90)
                .accessibilityLabel(Text("Adjustment for \(person.displayName)"))
        case .equal, .itemized:
            EmptyView()
        }
    }
}
