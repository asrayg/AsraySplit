import Foundation

/// Financial facts for one trip expressed in the trip's base currency (minor units).
/// Balances are always derived from these facts; nothing stores a running balance.
struct LedgerExpenseFact: Equatable, Sendable {
    var id: UUID
    var payments: [UUID: Int64]
    var allocations: [UUID: Int64]
}

struct LedgerSettlementFact: Equatable, Sendable {
    var id: UUID
    var from: UUID
    var to: UUID
    var amountMinor: Int64
}

struct ParticipantBalance: Equatable, Sendable, Identifiable {
    var id: UUID { participantID }
    let participantID: UUID
    var paidMinor: Int64 = 0
    var owedMinor: Int64 = 0
    var settlementsSentMinor: Int64 = 0
    var settlementsReceivedMinor: Int64 = 0

    /// Positive: the group owes this participant. Negative: this participant owes the group.
    ///
    /// net = funded expenses − consumed allocations + settlements sent − settlements received
    var netMinor: Int64 { paidMinor - owedMinor + settlementsSentMinor - settlementsReceivedMinor }
}

struct SuggestedTransfer: Equatable, Hashable, Codable, Sendable, Identifiable {
    var id: String { "\(from.sortKey)->\(to.sortKey)" }
    let from: UUID
    let to: UUID
    let amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case from = "fromParticipantId", to = "toParticipantId", amountMinor
    }
}

enum LedgerError: Error, Equatable {
    case unbalancedExpense(UUID)
    case invalidSettlement(UUID)
}

enum Ledger {
    static func balances(participants: [UUID], expenses: [LedgerExpenseFact], settlements: [LedgerSettlementFact]) throws -> [ParticipantBalance] {
        var table: [UUID: ParticipantBalance] = Dictionary(uniqueKeysWithValues: participants.map { ($0, ParticipantBalance(participantID: $0)) })
        func row(_ id: UUID) -> ParticipantBalance { table[id] ?? ParticipantBalance(participantID: id) }

        for expense in expenses {
            let paid = try Int64.checkedSum(expense.payments.values)
            let owed = try Int64.checkedSum(expense.allocations.values)
            guard paid == owed else { throw LedgerError.unbalancedExpense(expense.id) }
            for (id, amount) in expense.payments { var value = row(id); value.paidMinor += amount; table[id] = value }
            for (id, amount) in expense.allocations { var value = row(id); value.owedMinor += amount; table[id] = value }
        }
        for settlement in settlements {
            guard settlement.from != settlement.to, settlement.amountMinor > 0 else { throw LedgerError.invalidSettlement(settlement.id) }
            var sender = row(settlement.from); sender.settlementsSentMinor += settlement.amountMinor; table[settlement.from] = sender
            var receiver = row(settlement.to); receiver.settlementsReceivedMinor += settlement.amountMinor; table[settlement.to] = receiver
        }
        return table.values.sorted { $0.participantID.sortKey < $1.participantID.sortKey }
    }

    /// Greedy debt simplification: repeatedly settle the largest debtor against the largest creditor
    /// (ties by ascending participant ID). Produces at most n−1 transfers, never changes anyone's net,
    /// and matches `public.suggested_settlements` in the database exactly.
    static func simplify(_ balances: [ParticipantBalance]) -> [SuggestedTransfer] {
        var remaining: [UUID: Int64] = [:]
        for balance in balances where balance.netMinor != 0 { remaining[balance.participantID] = balance.netMinor }
        var transfers: [SuggestedTransfer] = []

        while true {
            let creditor = remaining.filter { $0.value > 0 }.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.sortKey > rhs.key.sortKey
            }
            let debtor = remaining.filter { $0.value < 0 }.min { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.sortKey < rhs.key.sortKey
            }
            guard let creditor, let debtor else { break }
            let amount = min(creditor.value, -debtor.value)
            transfers.append(SuggestedTransfer(from: debtor.key, to: creditor.key, amountMinor: amount))
            remaining[creditor.key] = creditor.value - amount
            remaining[debtor.key] = debtor.value + amount
            if remaining[creditor.key] == 0 { remaining[creditor.key] = nil }
            if remaining[debtor.key] == 0 { remaining[debtor.key] = nil }
        }
        return transfers
    }

    /// Transfers that involve `participant`, for "you owe / you are owed" summaries.
    static func transfers(involving participant: UUID, in transfers: [SuggestedTransfer]) -> [SuggestedTransfer] {
        transfers.filter { $0.from == participant || $0.to == participant }
    }
}
