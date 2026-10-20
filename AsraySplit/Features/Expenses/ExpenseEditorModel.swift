import Foundation
import Observation

/// Remembered per-trip split preferences ("default trip split").
struct DefaultSplit: Codable, Equatable, Sendable {
    var method: SplitMethod
    var included: [ParticipantID]
    var shares: [ParticipantID: Decimal]
    var payer: ParticipantID?
    var currency: CurrencyCode?
}

/// State and validation for adding, editing or duplicating an expense. Pure logic; no UI.
@MainActor
@Observable
final class ExpenseEditorModel {
    enum RateStatus: Equatable { case notNeeded, loading, loaded(provider: String, asOf: Date), manual, failed(String) }

    let trip: Trip
    let editing: Expense?

    var title = ""
    var merchant = ""
    var notes = ""
    var category: ExpenseCategory = .food
    var paymentMethod: PaymentMethod = .card
    var spentAt = Date()
    var amountMinor: Int64?
    private(set) var currency: CurrencyCode
    var exchangeRate: Decimal?
    var rateStatus: RateStatus = .notNeeded
    var payerID: ParticipantID?
    var splitMethod: SplitMethod = .equal
    var included: Set<ParticipantID> = []
    var exactValues: [ParticipantID: Int64] = [:]
    var percentValues: [ParticipantID: Decimal] = [:]
    var shareValues: [ParticipantID: Decimal] = [:]
    var adjustmentValues: [ParticipantID: Int64] = [:]
    var tags: [String] = []
    var receiptIDs: [UUID] = []
    /// Preserved when editing an itemized expense without changing its split.
    private var itemizedSource: (items: [ExpenseItem], tax: Int64?, fee: Int64?, tip: Int64?, discount: Int64?)?
    private let expenseID: ExpenseID
    private let idempotencyKey: UUID

    init(trip: Trip, editing: Expense? = nil, duplicating: Expense? = nil, defaults: DefaultSplit? = nil, me: ParticipantID?, now: Date = .now) {
        self.trip = trip
        self.editing = editing
        currency = trip.baseCurrency
        expenseID = editing?.id ?? UUID()
        idempotencyKey = editing?.idempotencyKey ?? UUID()
        let participants = trip.activeParticipants.map(\.id)

        if let source = editing ?? duplicating {
            title = source.title
            merchant = source.merchant ?? ""
            notes = source.notes ?? ""
            category = source.category
            paymentMethod = source.paymentMethod
            spentAt = editing == nil ? now : source.spentAt
            amountMinor = source.originalMinor
            currency = source.originalCurrency
            exchangeRate = source.isForeignCurrency ? source.exchangeRate : nil
            rateStatus = source.isForeignCurrency ? .loaded(provider: source.rateProvider ?? "saved", asOf: source.rateDate ?? source.spentAt) : .notNeeded
            payerID = source.payments.first?.participantId
            splitMethod = source.splitMethod
            included = Set(source.allocations.filter { $0.amountMinor != 0 || source.splitMethod != .equal }.map(\.participantId))
            tags = source.tags
            receiptIDs = editing == nil ? [] : source.receiptIds
            for share in source.allocations {
                exactValues[share.participantId] = share.amountMinor
                switch source.splitMethod {
                case .percentage: percentValues[share.participantId] = share.inputValue
                case .shares: shareValues[share.participantId] = share.inputValue
                case .adjustment: adjustmentValues[share.participantId] = share.inputValue.map { NSDecimalNumber(decimal: $0).int64Value }
                default: break
                }
            }
            if source.splitMethod == .itemized {
                itemizedSource = (source.items, source.taxMinor, source.serviceFeeMinor, source.tipMinor, source.discountMinor)
            }
        } else {
            payerID = defaults?.payer.flatMap { id in participants.contains(id) ? id : nil } ?? me ?? participants.first
            splitMethod = defaults?.method == .itemized ? .equal : (defaults?.method ?? .equal)
            let remembered = Set(defaults?.included ?? []).intersection(participants)
            included = remembered.isEmpty ? Set(participants) : remembered
            shareValues = defaults?.shares ?? [:]
            if let preferred = defaults?.currency { currency = preferred }
            if currency != trip.baseCurrency { rateStatus = .manual }
        }
    }

    var isEditing: Bool { editing != nil }
    var participants: [Participant] { trip.activeParticipants + trip.participants.filter { $0.archivedAt != nil && included.contains($0.id) } }
    var orderedIncluded: [ParticipantID] { participants.map(\.id).filter(included.contains) }
    var needsRate: Bool { currency != trip.baseCurrency }

    // MARK: Split computation

    var rule: SplitRule? {
        let ids = orderedIncluded
        guard !ids.isEmpty else { return nil }
        switch splitMethod {
        case .equal: return .equal(ids)
        case .exact: return .exact(Dictionary(uniqueKeysWithValues: ids.map { ($0, exactValues[$0] ?? 0) }))
        case .percentage: return .percentage(Dictionary(uniqueKeysWithValues: ids.map { ($0, percentValues[$0] ?? 0) }))
        case .shares: return .shares(Dictionary(uniqueKeysWithValues: ids.map { ($0, shareValues[$0] ?? 1) }))
        case .adjustment: return .adjustment(Dictionary(uniqueKeysWithValues: ids.map { ($0, adjustmentValues[$0] ?? 0) }))
        case .itemized:
            guard let itemizedSource else { return nil }
            return .itemized(ItemizedSplit(
                items: itemizedSource.items.map { .init(id: $0.id, amountMinor: $0.amountMinor, assignees: Dictionary($0.assignees.map { ($0.participantId, $0.weight) }, uniquingKeysWith: +)) },
                taxMinor: itemizedSource.tax ?? 0, serviceFeeMinor: itemizedSource.fee ?? 0, tipMinor: itemizedSource.tip ?? 0, discountMinor: itemizedSource.discount ?? 0))
        }
    }

    var allocation: Result<[ParticipantID: Int64], SplitError> {
        guard let amountMinor, amountMinor != 0 else { return .failure(.zeroAmount) }
        guard let rule else { return .failure(.noParticipants) }
        do { return .success(try rule.allocate(total: amountMinor)) }
        catch let error as SplitError { return .failure(error) }
        catch { return .failure(.overflow) }
    }

    /// Remaining amount (exact) or percentage (percent) still to assign, for live feedback.
    var remainingExactMinor: Int64? {
        guard splitMethod == .exact, let amountMinor else { return nil }
        return amountMinor - orderedIncluded.reduce(0) { $0 + (exactValues[$1] ?? 0) }
    }

    var remainingPercent: Decimal? {
        guard splitMethod == .percentage else { return nil }
        return 100 - orderedIncluded.reduce(Decimal(0)) { $0 + (percentValues[$1] ?? 0) }
    }

    /// Converted base-currency amount for display (the server recomputes identically).
    var baseAmount: Money? {
        guard let amountMinor else { return nil }
        guard needsRate else { return Money(minorUnits: amountMinor, currency: trip.baseCurrency) }
        guard let exchangeRate, exchangeRate > 0, let value = try? CurrencyConversion.convert(amountMinor, from: currency, to: trip.baseCurrency, rate: exchangeRate) else { return nil }
        return Money(minorUnits: value, currency: trip.baseCurrency)
    }

    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Add a description.") }
        guard let amountMinor, amountMinor != 0 else { return String(localized: "Enter an amount.") }
        if payerID == nil { return String(localized: "Choose who paid.") }
        if needsRate && (exchangeRate ?? 0) <= 0 { return String(localized: "Add an exchange rate to \(trip.baseCurrency.rawValue).") }
        if case .failure(let error) = allocation { return error.userMessage }
        return nil
    }

    var canSave: Bool { validationMessage == nil }

    // MARK: Inputs

    func setCurrency(_ newValue: CurrencyCode) {
        guard newValue != currency else { return }
        currency = newValue
        exchangeRate = nil
        rateStatus = newValue == trip.baseCurrency ? .notNeeded : .manual
    }

    func toggle(_ participant: ParticipantID) {
        if included.contains(participant) { included.remove(participant) } else { included.insert(participant) }
    }

    func setSplitMethod(_ method: SplitMethod) {
        guard method != splitMethod else { return }
        // Seed the new mode from the current allocation so switching doesn't lose work.
        if case .success(let shares) = allocation, let amountMinor, amountMinor != 0 {
            switch method {
            case .exact: exactValues = shares
            case .percentage:
                let percents = shares.mapValues { Decimal($0) * 100 / Decimal(amountMinor) }
                percentValues = percents.mapValues { value in
                    var input = value, rounded = Decimal()
                    NSDecimalRound(&rounded, &input, 2, .plain)
                    return rounded
                }
                // Make percentages total exactly 100 by adjusting the first person.
                if let first = orderedIncluded.first {
                    let sum = orderedIncluded.reduce(Decimal(0)) { $0 + (percentValues[$1] ?? 0) }
                    percentValues[first, default: 0] += 100 - sum
                }
            case .adjustment: adjustmentValues = [:]
            default: break
            }
        }
        if method != .itemized { itemizedSource = nil }
        splitMethod = method
    }

    func addTag(_ raw: String) {
        let tag = raw.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !tag.isEmpty, tag.count <= 32, !tags.contains(tag), tags.count < 20 else { return }
        tags.append(tag)
    }

    func loadRate(using service: any ExchangeRateService) async {
        guard needsRate else { rateStatus = .notNeeded; return }
        rateStatus = .loading
        do {
            let quote = try await service.rate(from: currency, to: trip.baseCurrency, on: spentAt)
            exchangeRate = quote.rate
            rateStatus = .loaded(provider: quote.provider, asOf: quote.asOf)
        } catch {
            rateStatus = .failed(error.asAppError == .offline ? String(localized: "Offline — enter the rate manually.") : String(localized: "Couldn’t fetch a rate — enter it manually."))
        }
    }

    // MARK: Output

    func makePayload() throws -> ExpensePayload {
        if let message = validationMessage { throw AppError.validation(code: "editor", message: message) }
        guard let amountMinor, let payerID, case .success(let shares) = allocation else { throw AppError.validation(code: "editor", message: nil) }
        let inputs: [ParticipantID: Decimal?] = Dictionary(uniqueKeysWithValues: orderedIncluded.map { id in
            switch splitMethod {
            case .percentage: (id, percentValues[id] ?? 0)
            case .shares: (id, shareValues[id] ?? 1)
            case .adjustment: (id, Decimal(adjustmentValues[id] ?? 0))
            default: (id, nil)
            }
        })
        var tags = tags
        if paymentMethod == .cash, !tags.contains("cash") { tags.append("cash") }
        let rateProvider: String? = {
            switch rateStatus {
            case .loaded(let provider, _): provider
            case .manual, .failed: "manual"
            default: nil
            }
        }()
        let rateDate: Date? = { if case .loaded(_, let asOf) = rateStatus { return asOf }; return needsRate ? spentAt : nil }()
        return ExpensePayload(
            id: expenseID, idempotencyKey: idempotencyKey, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant: merchant.isEmpty ? nil : merchant, notes: notes.isEmpty ? nil : notes,
            category: category, paymentMethod: paymentMethod, spentAt: spentAt, splitMethod: splitMethod,
            amountMinor: amountMinor, currency: currency,
            exchangeRate: needsRate ? exchangeRate : nil, rateProvider: needsRate ? rateProvider : nil, rateDate: needsRate ? rateDate : nil,
            payments: [.init(participantId: payerID, amountMinor: amountMinor)],
            allocations: orderedIncluded.map { .init(participantId: $0, amountMinor: shares[$0] ?? 0, inputValue: inputs[$0] ?? nil) },
            items: splitMethod == .itemized ? itemizedSource?.items ?? [] : [],
            taxMinor: splitMethod == .itemized ? itemizedSource?.tax : nil,
            serviceFeeMinor: splitMethod == .itemized ? itemizedSource?.fee : nil,
            tipMinor: splitMethod == .itemized ? itemizedSource?.tip : nil,
            discountMinor: splitMethod == .itemized ? itemizedSource?.discount : nil,
            tags: tags, receiptIds: receiptIDs)
    }

    var defaultSplit: DefaultSplit {
        DefaultSplit(method: splitMethod, included: orderedIncluded, shares: splitMethod == .shares ? shareValues : [:], payer: payerID,
                     currency: currency == trip.baseCurrency ? nil : currency)
    }

    static func defaultsKey(_ tripID: TripID) -> String { "default-split-\(tripID.sortKey)" }
}
