import Foundation
import Observation

/// Editable receipt review: items, per-person assignment with weights, extras, reconciliation.
/// Converts the reviewed receipt into an itemized expense payload. AI output only pre-fills this.
@MainActor
@Observable
final class ScanReviewModel {
    struct Line: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var quantity: Decimal = 1
        var amountMinor: Int64?
        var assignees: [ParticipantID: Decimal] = [:]
        var confidence: Double = 1
        var isLowConfidence: Bool { confidence < ReceiptScanResult.lowConfidenceThreshold }
    }

    let trip: Trip
    var merchant: String
    var spentAt: Date
    var currency: CurrencyCode
    var exchangeRate: Decimal?
    var category: ExpenseCategory = .food
    var payerID: ParticipantID?
    var lines: [Line]
    var subtotalMinor: Int64?
    var taxMinor: Int64?
    var serviceFeeMinor: Int64?
    var tipMinor: Int64?
    var discountMinor: Int64?
    var declaredTotalMinor: Int64?
    var receiptID: UUID?
    let source: ReceiptScanResult.Source
    let fieldConfidence: [String: Double]
    let overallConfidence: Double
    /// User acknowledged that the printed total differs and wants to save anyway.
    var acceptDiscrepancy = false

    init(trip: Trip, result: ReceiptScanResult, receiptID: UUID?, me: ParticipantID?) {
        self.trip = trip
        merchant = result.merchant ?? ""
        spentAt = result.purchasedAt ?? .now
        currency = result.currency ?? trip.baseCurrency
        lines = result.items.map { Line(id: $0.id, name: $0.name, quantity: $0.quantity, amountMinor: $0.amountMinor, confidence: $0.confidence) }
        subtotalMinor = result.subtotalMinor
        taxMinor = result.taxMinor == 0 ? nil : result.taxMinor
        serviceFeeMinor = result.serviceFeeMinor == 0 ? nil : result.serviceFeeMinor
        tipMinor = result.tipMinor == 0 ? nil : result.tipMinor
        discountMinor = result.discountMinor == 0 ? nil : result.discountMinor
        declaredTotalMinor = result.totalMinor
        self.receiptID = receiptID
        source = result.source
        fieldConfidence = result.fieldConfidence
        overallConfidence = result.confidence
        payerID = me ?? trip.activeParticipants.first?.id
    }

    var itemsSum: Int64 { lines.reduce(0) { $0 + ($1.amountMinor ?? 0) } }
    var extras: Int64 { (taxMinor ?? 0) + (serviceFeeMinor ?? 0) + (tipMinor ?? 0) - (discountMinor ?? 0) }
    var computedTotal: Int64 { itemsSum + extras }

    var totals: ReceiptTotals {
        ReceiptTotals(itemsMinor: lines.map { $0.amountMinor ?? 0 }, subtotalMinor: subtotalMinor, taxMinor: taxMinor ?? 0,
                      serviceFeeMinor: serviceFeeMinor ?? 0, tipMinor: tipMinor ?? 0, discountMinor: discountMinor ?? 0, declaredTotalMinor: declaredTotalMinor)
    }

    var discrepancies: [ReceiptDiscrepancy] { ReceiptReconciler.discrepancies(totals) }
    var unassignedLines: [Line] { lines.filter { ($0.amountMinor ?? 0) != 0 && !$0.assignees.values.contains { $0 > 0 } } }
    var needsRate: Bool { currency != trip.baseCurrency }

    func toggle(_ participant: ParticipantID, on lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        if lines[index].assignees[participant] != nil { lines[index].assignees[participant] = nil }
        else { lines[index].assignees[participant] = 1 }
    }

    func assignAll(_ lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].assignees = Dictionary(uniqueKeysWithValues: trip.activeParticipants.map { ($0.id, Decimal(1)) })
    }

    func assignUnassigned(to participant: ParticipantID) {
        for index in lines.indices where lines[index].assignees.isEmpty { lines[index].assignees[participant] = 1 }
    }

    var split: ItemizedSplit {
        ItemizedSplit(items: lines.map { .init(id: $0.id, amountMinor: $0.amountMinor ?? 0, assignees: $0.assignees) },
                      taxMinor: taxMinor ?? 0, serviceFeeMinor: serviceFeeMinor ?? 0, tipMinor: tipMinor ?? 0, discountMinor: discountMinor ?? 0)
    }

    var perPerson: [ParticipantID: Int64] { (try? split.allocate()) ?? [:] }

    var blockingIssue: String? {
        if lines.isEmpty { return String(localized: "Add at least one item.") }
        if lines.contains(where: { $0.amountMinor == nil }) { return String(localized: "Every item needs a price.") }
        if !unassignedLines.isEmpty { return String(localized: "Assign \(unassignedLines.count) item(s) to someone.") }
        if computedTotal == 0 { return String(localized: "The total can’t be zero.") }
        if [taxMinor, serviceFeeMinor, tipMinor, discountMinor].contains(where: { ($0 ?? 0) < 0 }) { return ReceiptDiscrepancy.negativeComponent.message }
        if payerID == nil { return String(localized: "Choose who paid.") }
        if needsRate && (exchangeRate ?? 0) <= 0 { return String(localized: "Add an exchange rate to \(trip.baseCurrency.rawValue).") }
        if !discrepancies.isEmpty && !acceptDiscrepancy { return String(localized: "Fix the totals or confirm the difference.") }
        do { _ = try split.allocate() } catch let error as SplitError { return error.userMessage } catch { return error.localizedDescription }
        return nil
    }

    func makePayload() throws -> ExpensePayload {
        if let issue = blockingIssue { throw AppError.validation(code: "receipt_review", message: issue) }
        guard let payerID else { throw AppError.validation(code: "payer_required", message: nil) }
        let shares = try split.allocate()
        let total = computedTotal
        let items = lines.map { line in
            ExpenseItem(id: line.id, name: line.name.isEmpty ? String(localized: "Item") : line.name, quantity: line.quantity, amountMinor: line.amountMinor ?? 0,
                        assignees: line.assignees.filter { $0.value > 0 }.sorted { $0.key.sortKey < $1.key.sortKey }.map { ItemAssignee(participantId: $0.key, weight: $0.value) })
        }
        let title = merchant.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Receipt") : merchant
        var notes: String?
        if !discrepancies.isEmpty, let declared = declaredTotalMinor {
            notes = String(localized: "Printed total \(Money(minorUnits: declared, currency: currency).formatted()) differs from items; saved as reviewed.")
        }
        return ExpensePayload(title: title, merchant: merchant.isEmpty ? nil : merchant, notes: notes, category: category, paymentMethod: .card,
                              spentAt: spentAt, splitMethod: .itemized, amountMinor: total, currency: currency,
                              exchangeRate: needsRate ? exchangeRate : nil, rateProvider: needsRate ? "manual" : nil, rateDate: needsRate ? spentAt : nil,
                              payments: [.init(participantId: payerID, amountMinor: total)],
                              allocations: shares.sorted { $0.key.sortKey < $1.key.sortKey }.map { .init(participantId: $0.key, amountMinor: $0.value) },
                              items: items, taxMinor: taxMinor, serviceFeeMinor: serviceFeeMinor, tipMinor: tipMinor, discountMinor: discountMinor,
                              tags: source == .ai ? ["receipt", "scanned"] : ["receipt"], receiptIds: receiptID.map { [$0] } ?? [])
    }
}
