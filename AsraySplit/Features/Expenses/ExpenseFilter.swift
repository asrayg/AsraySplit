import Foundation

/// Search and filter criteria for a trip's expenses. Pure and unit tested.
struct ExpenseFilter: Equatable, Sendable {
    var query = ""
    var payer: ParticipantID?
    var participant: ParticipantID?
    var category: ExpenseCategory?
    var paymentMethod: PaymentMethod?
    var tag: String?
    var hasReceipt: Bool?
    var onlyUnsynced = false
    var from: Date?
    var to: Date?
    var minBaseMinor: Int64?
    var maxBaseMinor: Int64?

    var isActive: Bool { self != ExpenseFilter() }

    var activeCount: Int {
        [payer != nil, participant != nil, category != nil, paymentMethod != nil, tag != nil, hasReceipt != nil, onlyUnsynced,
         from != nil || to != nil, minBaseMinor != nil || maxBaseMinor != nil].filter { $0 }.count
    }

    func matches(_ cached: CachedExpense, trip: Trip?) -> Bool {
        let expense = cached.expense
        if !query.isEmpty, !expense.matches(search: query, trip: trip) { return false }
        if let payer, !expense.payerIDs.contains(payer) { return false }
        if let participant, !expense.allocations.contains(where: { $0.participantId == participant && $0.amountMinor != 0 }) { return false }
        if let category, expense.category != category { return false }
        if let paymentMethod, expense.paymentMethod != paymentMethod { return false }
        if let tag, !expense.tags.contains(tag) { return false }
        if let hasReceipt, expense.receiptIds.isEmpty == hasReceipt { return false }
        if onlyUnsynced, cached.syncState == .synced { return false }
        if let from, expense.spentAt < from { return false }
        if let to, expense.spentAt > to { return false }
        if let minBaseMinor, expense.baseMinor < minBaseMinor { return false }
        if let maxBaseMinor, expense.baseMinor > maxBaseMinor { return false }
        return true
    }
}
