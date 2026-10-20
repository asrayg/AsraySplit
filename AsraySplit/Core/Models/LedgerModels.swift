import Foundation

typealias ExpenseID = UUID

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, groceries, drinks, lodging, transport, flights, activities, shopping, fees, health, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: String(localized: "Food")
        case .groceries: String(localized: "Groceries")
        case .drinks: String(localized: "Drinks")
        case .lodging: String(localized: "Lodging")
        case .transport: String(localized: "Transport")
        case .flights: String(localized: "Flights")
        case .activities: String(localized: "Activities")
        case .shopping: String(localized: "Shopping")
        case .fees: String(localized: "Fees")
        case .health: String(localized: "Health")
        case .other: String(localized: "Other")
        }
    }

    var icon: String {
        switch self {
        case .food: "fork.knife"
        case .groceries: "cart.fill"
        case .drinks: "wineglass.fill"
        case .lodging: "bed.double.fill"
        case .transport: "car.fill"
        case .flights: "airplane"
        case .activities: "ticket.fill"
        case .shopping: "bag.fill"
        case .fees: "building.columns.fill"
        case .health: "cross.case.fill"
        case .other: "square.grid.2x2.fill"
        }
    }
}

enum PaymentMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case cash, card, bankTransfer = "bank_transfer", venmo, paypal, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: String(localized: "Cash")
        case .card: String(localized: "Card")
        case .bankTransfer: String(localized: "Bank transfer")
        case .venmo: "Venmo"
        case .paypal: "PayPal"
        case .other: String(localized: "Other")
        }
    }

    var icon: String {
        switch self {
        case .cash: "banknote.fill"
        case .card: "creditcard.fill"
        case .bankTransfer: "building.columns.fill"
        case .venmo, .paypal: "arrow.left.arrow.right.circle.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}

struct ExpenseShare: Codable, Hashable, Sendable {
    var participantId: ParticipantID
    var amountMinor: Int64
    var baseAmountMinor: Int64?
    @OptionalExactDecimal var inputValue: Decimal?

    init(participantId: ParticipantID, amountMinor: Int64, baseAmountMinor: Int64? = nil, inputValue: Decimal? = nil) {
        self.participantId = participantId
        self.amountMinor = amountMinor
        self.baseAmountMinor = baseAmountMinor
        self.inputValue = inputValue
    }
}

struct ItemAssignee: Codable, Hashable, Sendable {
    var participantId: ParticipantID
    @ExactDecimal var weight: Decimal

    init(participantId: ParticipantID, weight: Decimal = 1) {
        self.participantId = participantId
        self.weight = weight
    }
}

struct ExpenseItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    @ExactDecimal var quantity: Decimal
    var amountMinor: Int64
    var assignees: [ItemAssignee]

    init(id: UUID = UUID(), name: String, quantity: Decimal = 1, amountMinor: Int64, assignees: [ItemAssignee] = []) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.amountMinor = amountMinor
        self.assignees = assignees
    }
}

/// Canonical expense as returned by `public.expense_json`.
struct Expense: Identifiable, Codable, Hashable, Sendable {
    var id: ExpenseID
    var tripId: TripID
    var title: String
    var merchant: String?
    var notes: String?
    var category: ExpenseCategory
    var paymentMethod: PaymentMethod
    var spentAt: Date
    var splitMethod: SplitMethod
    var originalMinor: Int64
    var originalCurrency: CurrencyCode
    var baseMinor: Int64
    var baseCurrency: CurrencyCode
    @ExactDecimal var exchangeRate: Decimal
    var rateProvider: String?
    var rateDate: Date?
    var taxMinor: Int64?
    var serviceFeeMinor: Int64?
    var tipMinor: Int64?
    var discountMinor: Int64?
    var revision: Int
    var idempotencyKey: UUID
    var createdBy: UserID?
    var updatedBy: UserID?
    var deletedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    var payments: [ExpenseShare]
    var allocations: [ExpenseShare]
    var items: [ExpenseItem]
    var tags: [String]
    var receiptIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, tripId, title = "description", merchant, notes, category, paymentMethod, spentAt, splitMethod
        case originalMinor, originalCurrency, baseMinor, baseCurrency, exchangeRate, rateProvider, rateDate
        case taxMinor, serviceFeeMinor, tipMinor, discountMinor, revision, idempotencyKey, createdBy, updatedBy
        case deletedAt, createdAt, updatedAt, payments, allocations, items, tags, receiptIds
    }

    var original: Money { Money(minorUnits: originalMinor, currency: originalCurrency) }
    var base: Money { Money(minorUnits: baseMinor, currency: baseCurrency) }
    var isDeleted: Bool { deletedAt != nil }
    var isForeignCurrency: Bool { originalCurrency != baseCurrency }
    var payerIDs: [ParticipantID] { payments.map(\.participantId) }

    func baseShare(for participant: ParticipantID) -> Int64 {
        allocations.first { $0.participantId == participant }?.baseAmountMinor ?? 0
    }

    var ledgerFact: LedgerExpenseFact {
        LedgerExpenseFact(
            id: id,
            payments: Dictionary(payments.map { ($0.participantId, $0.baseAmountMinor ?? $0.amountMinor) }, uniquingKeysWith: +),
            allocations: Dictionary(allocations.map { ($0.participantId, $0.baseAmountMinor ?? $0.amountMinor) }, uniquingKeysWith: +))
    }

    func matches(search query: String, trip: Trip?) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let names = (payments + allocations).compactMap { trip?.participant($0.participantId)?.displayName.lowercased() }
        let haystack = [title, merchant ?? "", notes ?? "", category.title, tags.joined(separator: " ")].map { $0.lowercased() } + names
        if haystack.contains(where: { $0.contains(needle) }) { return true }
        if let amount = try? MoneyParser().parseDecimal(needle), amount == original.decimalValue || amount == base.decimalValue { return true }
        return false
    }
}

struct Settlement: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var tripId: TripID
    var fromParticipantId: ParticipantID
    var toParticipantId: ParticipantID
    var amountMinor: Int64
    var currency: CurrencyCode
    var baseAmountMinor: Int64
    @ExactDecimal var exchangeRate: Decimal
    var method: PaymentMethod
    var reference: String?
    var note: String?
    var settledAt: Date
    var revision: Int
    var idempotencyKey: UUID
    var createdBy: UserID?
    var deletedAt: Date?

    var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
    var isDeleted: Bool { deletedAt != nil }
    var ledgerFact: LedgerSettlementFact {
        LedgerSettlementFact(id: id, from: fromParticipantId, to: toParticipantId, amountMinor: baseAmountMinor)
    }
}

struct ServerBalance: Codable, Hashable, Sendable {
    var participantId: ParticipantID
    var paidMinor: Int64
    var owedMinor: Int64
    var sentMinor: Int64
    var receivedMinor: Int64
    var netMinor: Int64

    var participantBalance: ParticipantBalance {
        ParticipantBalance(participantID: participantId, paidMinor: paidMinor, owedMinor: owedMinor,
                           settlementsSentMinor: sentMinor, settlementsReceivedMinor: receivedMinor)
    }
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    var id: Int64
    var tripId: TripID
    var actorId: UserID?
    var kind: String
    var entityId: UUID?
    var data: [String: JSONValue]
    var createdAt: Date

    /// Looks up a data field by its snake_case server key. Some Foundation versions apply the
    /// decoder's key strategy to dictionary keys, so the camelCase form is accepted too.
    func value(_ key: String) -> JSONValue? {
        if let value = data[key] { return value }
        let parts = key.split(separator: "_")
        let camel = (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return data[camel]
    }
}

struct TripSummary: Codable, Hashable, Sendable {
    struct CategoryTotal: Codable, Hashable, Sendable { var category: ExpenseCategory; var totalMinor: Int64; var count: Int }
    struct DayTotal: Codable, Hashable, Sendable { var day: Date; var totalMinor: Int64 }
    struct ParticipantTotal: Codable, Hashable, Sendable { var participantId: ParticipantID; var consumedMinor: Int64; var paidMinor: Int64 }

    var tripId: TripID
    var baseCurrency: CurrencyCode
    var budgetMinor: Int64?
    var totalSpentMinor: Int64
    var expenseCount: Int
    var byCategory: [CategoryTotal]
    var byDay: [DayTotal]
    var byParticipant: [ParticipantTotal]
}
