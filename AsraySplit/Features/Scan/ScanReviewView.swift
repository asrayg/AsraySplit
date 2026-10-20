import SwiftUI

@MainActor
struct ScanReviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store
    @Bindable var model: ScanReviewModel
    let image: UIImage?
    let duplicates: [ReceiptDuplicate]
    let fallbackReason: String?
    var onSaved: () -> Void

    @State private var saving = false
    @State private var error: AppError?
    @State private var showImage = false

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(error: error) }.listRowBackground(Color.clear) }
            if !duplicates.isEmpty {
                Section {
                    Label(duplicates.contains(where: \.exact) ? "This exact receipt was already uploaded to this trip." : "This looks like a receipt already in this trip.",
                          systemImage: "doc.on.doc.fill").foregroundStyle(Color.warning)
                    Text("Check the existing expense before saving a duplicate.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack(spacing: 12) {
                    if let image {
                        Button { showImage = true } label: {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 70).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel(Text("View receipt photo"))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Merchant", text: $model.merchant).font(.headline)
                            .background(lowConfidence("merchant"))
                        Label(sourceText, systemImage: model.source == .ai ? "sparkles" : "text.viewfinder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let fallbackReason { Text(fallbackReason).font(.footnote).foregroundStyle(.secondary) }
                DatePicker("Date", selection: $model.spentAt).background(lowConfidence("date"))
                Picker("Paid by", selection: $model.payerID) {
                    ForEach(model.trip.activeParticipants) { Text($0.displayName).tag(ParticipantID?.some($0.id)) }
                }
                Picker("Category", selection: $model.category) {
                    ForEach(ExpenseCategory.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                if model.needsRate {
                    HStack {
                        Text("1 \(model.currency.rawValue) =")
                        DecimalField(title: "Rate", value: $model.exchangeRate, maxFractionDigits: 8).multilineTextAlignment(.trailing)
                        Text(model.trip.baseCurrency.rawValue)
                    }
                    .task {
                        if model.exchangeRate == nil, let quote = try? await app.env.backend.rates.rate(from: model.currency, to: model.trip.baseCurrency, on: model.spentAt) {
                            model.exchangeRate = quote.rate
                        }
                    }
                }
            } header: { Text("Receipt") } footer: {
                Text("Highlighted fields were hard to read. Nothing is saved until you tap Save.")
            }

            Section {
                ForEach($model.lines) { $line in
                    LineEditor(line: $line, currency: model.currency, people: model.trip.activeParticipants,
                               toggle: { model.toggle($0, on: line.id) }, everyone: { model.assignAll(line.id) })
                }
                .onDelete { model.lines.remove(atOffsets: $0) }
                Button { model.lines.append(.init(name: "")) } label: { Label("Add item", systemImage: "plus.circle.fill") }
                if !model.unassignedLines.isEmpty {
                    Menu {
                        ForEach(model.trip.activeParticipants) { person in
                            Button(person.displayName) { model.assignUnassigned(to: person.id) }
                        }
                    } label: {
                        Label("\(model.unassignedLines.count) unassigned — assign all to…", systemImage: "exclamationmark.circle").foregroundStyle(Color.warning)
                    }
                }
            } header: { Text("Items — tap who had each") }

            Section("Totals") {
                extra("Subtotal (printed)", $model.subtotalMinor, field: "subtotal")
                extra("Tax / VAT", $model.taxMinor, field: "tax")
                extra("Service fee", $model.serviceFeeMinor, field: "service_fee")
                extra("Tip", $model.tipMinor, field: "tip")
                extra("Discount", $model.discountMinor, field: "discount")
                extra("Total (printed)", $model.declaredTotalMinor, field: "total")
                LabeledContent("Calculated total") { Text(Money(minorUnits: model.computedTotal, currency: model.currency).formatted()).bold().monospacedDigit() }
                ForEach(Array(model.discrepancies.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warning).font(.footnote)
                }
                if !model.discrepancies.isEmpty {
                    Toggle("Save with the calculated total anyway", isOn: $model.acceptDiscrepancy).font(.footnote)
                }
            }

            Section {
                ForEach(model.trip.activeParticipants) { person in
                    if let share = model.perPerson[person.id], share != 0 {
                        LabeledContent(person.displayName) { Text(Money(minorUnits: share, currency: model.currency).formatted()).monospacedDigit() }
                    }
                }
            } header: { Text("Everyone’s share") } footer: {
                Text("Tax, fees, tip and discounts are shared in proportion to each person’s items.")
            }

            Section {
                Button { Task { await save() } } label: {
                    if saving { ProgressView().frame(maxWidth: .infinity) } else { Text("Save \(Money(minorUnits: model.computedTotal, currency: model.currency).formatted())") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.blockingIssue != nil || saving)
                .listRowBackground(Color.clear)
                if let issue = model.blockingIssue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .screenBackground()
        .navigationTitle("Review receipt")
        .sheet(isPresented: $showImage) {
            if let image { ZoomableImage(image: image) }
        }
    }

    private var sourceText: String {
        switch model.source {
        case .ai: String(localized: "AI read · \(Int(model.overallConfidence * 100))% confident · please check")
        case .onDevice: String(localized: "Read on this iPhone · please check carefully")
        case .manual: String(localized: "Manual entry")
        }
    }

    @ViewBuilder
    private func lowConfidence(_ field: String) -> some View {
        if (model.fieldConfidence[field] ?? model.overallConfidence) < ReceiptScanResult.lowConfidenceThreshold && model.source != .manual {
            RoundedRectangle(cornerRadius: 6).fill(Color.warning.opacity(0.15))
        }
    }

    private func extra(_ title: LocalizedStringKey, _ value: Binding<Int64?>, field: String) -> some View {
        LabeledContent(title) {
            MoneyField(title: "0", minorUnits: value, currency: model.currency).multilineTextAlignment(.trailing).frame(maxWidth: 120)
        }
        .listRowBackground(lowConfidence(field).opacity(0.8))
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await store.saveExpense(try model.makePayload(), in: model.trip)
            app.show(Toast(message: String(localized: "Receipt saved"), style: .success))
            onSaved()
        } catch {
            self.error = error.asAppError
        }
    }
}

@MainActor
private struct LineEditor: View {
    @Binding var line: ScanReviewModel.Line
    let currency: CurrencyCode
    let people: [Participant]
    var toggle: (ParticipantID) -> Void
    var everyone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Item", text: $line.name).font(.headline)
                MoneyField(title: "0.00", minorUnits: $line.amountMinor, currency: currency, allowNegative: true)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 100).font(.headline)
            }
            .padding(4)
            .background(line.isLowConfidence ? Color.warning.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(people) { person in
                        let selected = line.assignees[person.id] != nil
                        Button { toggle(person.id) } label: {
                            Text(person.displayName.split(separator: " ").first.map(String.init) ?? person.displayName)
                                .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(selected ? Color.brand.opacity(0.2) : Color.surfaceRaised, in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.brand : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(person.displayName))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    Button("Everyone", action: everyone).font(.caption.bold()).padding(.horizontal, 8)
                }
            }
            if line.assignees.count > 1 {
                ForEach(people.filter { line.assignees[$0.id] != nil }) { person in
                    Stepper(value: Binding(get: { NSDecimalNumber(decimal: line.assignees[person.id] ?? 1).intValue },
                                           set: { line.assignees[person.id] = Decimal(max($0, 1)) }), in: 1...10) {
                        Text("\(person.displayName): \(NSDecimalNumber(decimal: line.assignees[person.id] ?? 1).intValue) share(s)").font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: UIScreen.main.bounds.width * scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1, min($0, 5)) })
        }
        .accessibilityLabel(Text("Receipt image"))
    }
}
