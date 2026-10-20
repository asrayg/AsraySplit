import Foundation

/// Checks that a receipt's parts add up exactly before it can become an expense.
struct ReceiptTotals: Equatable, Sendable {
    var itemsMinor: [Int64]
    var subtotalMinor: Int64?
    var taxMinor: Int64 = 0
    var serviceFeeMinor: Int64 = 0
    var tipMinor: Int64 = 0
    var discountMinor: Int64 = 0
    var declaredTotalMinor: Int64?

    var itemsSum: Int64 { itemsMinor.reduce(0, +) }
    var computedTotal: Int64 { (subtotalMinor ?? itemsSum) + taxMinor + serviceFeeMinor + tipMinor - discountMinor }
}

enum ReceiptDiscrepancy: Equatable, Sendable {
    /// Line items do not add up to the printed subtotal.
    case itemsDoNotMatchSubtotal(itemsSum: Int64, subtotal: Int64)
    /// Subtotal + tax + fees + tip − discount does not equal the printed total.
    case totalMismatch(computed: Int64, declared: Int64)
    case negativeComponent
    case empty

    var message: String {
        switch self {
        case .itemsDoNotMatchSubtotal: String(localized: "Items don’t add up to the subtotal.")
        case .totalMismatch: String(localized: "Subtotal, tax, tip and discounts don’t match the receipt total.")
        case .negativeComponent: String(localized: "Tax, tip, fees and discounts can’t be negative.")
        case .empty: String(localized: "Add at least one item.")
        }
    }
}

enum ReceiptReconciler {
    static func discrepancies(_ totals: ReceiptTotals) -> [ReceiptDiscrepancy] {
        var issues: [ReceiptDiscrepancy] = []
        if totals.itemsMinor.isEmpty { issues.append(.empty) }
        if [totals.taxMinor, totals.serviceFeeMinor, totals.tipMinor, totals.discountMinor].contains(where: { $0 < 0 }) {
            issues.append(.negativeComponent)
        }
        if let subtotal = totals.subtotalMinor, subtotal != totals.itemsSum {
            issues.append(.itemsDoNotMatchSubtotal(itemsSum: totals.itemsSum, subtotal: subtotal))
        }
        if let declared = totals.declaredTotalMinor, declared != totals.computedTotal {
            issues.append(.totalMismatch(computed: totals.computedTotal, declared: declared))
        }
        return issues
    }

    static func isReconciled(_ totals: ReceiptTotals) -> Bool { discrepancies(totals).isEmpty }
}
