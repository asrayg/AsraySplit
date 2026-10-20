import Foundation

/// Write payload for `create_expense` / `update_expense`. Encoded once and stored verbatim in the
/// outbox so retries send byte-identical requests (the server fingerprints payloads per idempotency key).
struct ExpensePayload: Codable, Equatable, Sendable {
    struct Share: Codable, Equatable, Sendable {
        var participantId: ParticipantID
        var amountMinor: Int64
        @OptionalExactDecimal var inputValue: Decimal?

        init(participantId: ParticipantID, amountMinor: Int64, inputValue: Decimal? = nil) {
            self.participantId = participantId
            self.amountMinor = amountMinor
            self.inputValue = inputValue
        }
    }

    var id: ExpenseID
    var idempotencyKey: UUID
    var title: String
    var merchant: String?
    var notes: String?
    var category: ExpenseCategory
    var paymentMethod: PaymentMethod
    var spentAt: Date
    var splitMethod: SplitMethod
    var amountMinor: Int64
    var currency: CurrencyCode
    @OptionalExactDecimal var exchangeRate: Decimal?
    var rateProvider: String?
    var rateDate: Date?
    var payments: [Share]
    var allocations: [Share]
    var items: [ExpenseItem]
    var taxMinor: Int64?
    var serviceFeeMinor: Int64?
    var tipMinor: Int64?
    var discountMinor: Int64?
    var tags: [String]
    var receiptIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, idempotencyKey, title = "description", merchant, notes, category, paymentMethod, spentAt, splitMethod
        case amountMinor, currency, exchangeRate, rateProvider, rateDate, payments, allocations, items
        case taxMinor, serviceFeeMinor, tipMinor, discountMinor, tags, receiptIds
    }

    var money: Money { Money(minorUnits: amountMinor, currency: currency) }

    /// Mirrors server validation so most errors surface before saving (the server re-validates).
    func validate(baseCurrency: CurrencyCode, participants: Set<ParticipantID>) throws {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError.validation(code: "description_required", message: nil) }
        guard amountMinor != 0 else { throw AppError.validation(code: "invalid_amount", message: nil) }
        guard !payments.isEmpty else { throw AppError.validation(code: "payments_mismatch", message: nil) }
        guard !allocations.isEmpty else { throw AppError.validation(code: "allocations_mismatch", message: nil) }
        guard try Int64.checkedSum(payments.map(\.amountMinor)) == amountMinor else { throw AppError.validation(code: "payments_mismatch", message: nil) }
        guard try Int64.checkedSum(allocations.map(\.amountMinor)) == amountMinor else { throw AppError.validation(code: "allocations_mismatch", message: nil) }
        let referenced = Set(payments.map(\.participantId) + allocations.map(\.participantId) + items.flatMap { $0.assignees.map(\.participantId) })
        guard referenced.isSubset(of: participants) else { throw AppError.validation(code: "unknown_participant", message: nil) }
        if (payments + allocations).contains(where: { $0.amountMinor != 0 && ($0.amountMinor < 0) != (amountMinor < 0) }) {
            throw AppError.validation(code: "mixed_signs", message: nil)
        }
        if currency != baseCurrency, (exchangeRate ?? 0) <= 0 { throw AppError.validation(code: "exchange_rate_required", message: nil) }
        if !items.isEmpty {
            let extras = (taxMinor ?? 0) + (serviceFeeMinor ?? 0) + (tipMinor ?? 0) - (discountMinor ?? 0)
            guard try Int64.checkedSum(items.map(\.amountMinor)) + extras == amountMinor else { throw AppError.validation(code: "receipt_unreconciled", message: nil) }
            guard !items.contains(where: { $0.amountMinor != 0 && $0.assignees.isEmpty }) else { throw AppError.validation(code: "unassigned_items", message: nil) }
        }
    }

    /// The expense as it will look once the server accepts it, for immediate offline display.
    /// Base-currency math is identical to `private.write_expense`.
    func optimisticExpense(tripID: TripID, baseCurrency: CurrencyCode, revision: Int, createdBy: UserID?, now: Date = .now) throws -> Expense {
        let rate = currency == baseCurrency ? 1 : (exchangeRate ?? 1)
        let baseTotal = try CurrencyConversion.convert(amountMinor, from: currency, to: baseCurrency, rate: rate)
        func rebase(_ shares: [Share]) throws -> [ExpenseShare] {
            let original = Dictionary(shares.map { ($0.participantId, $0.amountMinor) }, uniquingKeysWith: +)
            let converted = try CurrencyConversion.convertShares(original, total: amountMinor, from: currency, to: baseCurrency, rate: rate)
            return shares.map {
                ExpenseShare(participantId: $0.participantId, amountMinor: $0.amountMinor, baseAmountMinor: converted[$0.participantId], inputValue: $0.inputValue)
            }
        }
        return Expense(
            id: id, tripId: tripID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), merchant: merchant, notes: notes,
            category: category, paymentMethod: paymentMethod, spentAt: spentAt, splitMethod: splitMethod,
            originalMinor: amountMinor, originalCurrency: currency, baseMinor: baseTotal, baseCurrency: baseCurrency,
            exchangeRate: rate, rateProvider: rateProvider, rateDate: rateDate,
            taxMinor: taxMinor, serviceFeeMinor: serviceFeeMinor, tipMinor: tipMinor, discountMinor: discountMinor,
            revision: revision, idempotencyKey: idempotencyKey, createdBy: createdBy, updatedBy: createdBy,
            deletedAt: nil, createdAt: now, updatedAt: now,
            payments: try rebase(payments), allocations: try rebase(allocations), items: items,
            tags: Array(Set(tags.map { $0.lowercased() })).sorted(), receiptIds: receiptIds)
    }

    init(id: ExpenseID = UUID(), idempotencyKey: UUID = UUID(), title: String, merchant: String? = nil, notes: String? = nil,
         category: ExpenseCategory, paymentMethod: PaymentMethod, spentAt: Date, splitMethod: SplitMethod,
         amountMinor: Int64, currency: CurrencyCode, exchangeRate: Decimal? = nil, rateProvider: String? = nil, rateDate: Date? = nil,
         payments: [Share], allocations: [Share], items: [ExpenseItem] = [], taxMinor: Int64? = nil, serviceFeeMinor: Int64? = nil,
         tipMinor: Int64? = nil, discountMinor: Int64? = nil, tags: [String] = [], receiptIds: [UUID] = []) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.merchant = merchant
        self.notes = notes
        self.category = category
        self.paymentMethod = paymentMethod
        self.spentAt = spentAt
        self.splitMethod = splitMethod
        self.amountMinor = amountMinor
        self.currency = currency
        self.exchangeRate = exchangeRate
        self.rateProvider = rateProvider
        self.rateDate = rateDate
        self.payments = payments
        self.allocations = allocations
        self.items = items
        self.taxMinor = taxMinor
        self.serviceFeeMinor = serviceFeeMinor
        self.tipMinor = tipMinor
        self.discountMinor = discountMinor
        self.tags = tags
        self.receiptIds = receiptIds
    }

    /// Builds an edit payload from a canonical expense (keeps the original idempotency key semantics:
    /// updates are guarded by revision, not by key).
    init(expense: Expense) {
        self.init(id: expense.id, idempotencyKey: expense.idempotencyKey, title: expense.title, merchant: expense.merchant,
                  notes: expense.notes, category: expense.category, paymentMethod: expense.paymentMethod, spentAt: expense.spentAt,
                  splitMethod: expense.splitMethod, amountMinor: expense.originalMinor, currency: expense.originalCurrency,
                  exchangeRate: expense.isForeignCurrency ? expense.exchangeRate : nil, rateProvider: expense.rateProvider,
                  rateDate: expense.rateDate,
                  payments: expense.payments.map { Share(participantId: $0.participantId, amountMinor: $0.amountMinor) },
                  allocations: expense.allocations.map { Share(participantId: $0.participantId, amountMinor: $0.amountMinor, inputValue: $0.inputValue) },
                  items: expense.items, taxMinor: expense.taxMinor, serviceFeeMinor: expense.serviceFeeMinor, tipMinor: expense.tipMinor,
                  discountMinor: expense.discountMinor, tags: expense.tags, receiptIds: expense.receiptIds)
    }
}

struct SettlementPayload: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var idempotencyKey: UUID = UUID()
    var fromParticipantId: ParticipantID
    var toParticipantId: ParticipantID
    var amountMinor: Int64
    var currency: CurrencyCode
    @OptionalExactDecimal var exchangeRate: Decimal?
    var rateProvider: String?
    var rateDate: Date?
    var method: PaymentMethod
    var reference: String?
    var note: String?
    var settledAt: Date
    var receiptIds: [UUID] = []

    func optimisticSettlement(tripID: TripID, baseCurrency: CurrencyCode, createdBy: UserID?) throws -> Settlement {
        let rate = currency == baseCurrency ? 1 : (exchangeRate ?? 1)
        return Settlement(id: id, tripId: tripID, fromParticipantId: fromParticipantId, toParticipantId: toParticipantId,
                          amountMinor: amountMinor, currency: currency,
                          baseAmountMinor: try CurrencyConversion.convert(amountMinor, from: currency, to: baseCurrency, rate: rate),
                          exchangeRate: rate, method: method, reference: reference, note: note, settledAt: settledAt, revision: 1,
                          idempotencyKey: idempotencyKey, createdBy: createdBy, deletedAt: nil)
    }
}
