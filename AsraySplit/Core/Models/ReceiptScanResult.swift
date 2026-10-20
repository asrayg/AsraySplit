import Foundation

/// Normalized receipt extraction in minor units. Produced by the `scan-receipt` Edge Function or the
/// on-device OCR fallback. Always treated as untrusted: it pre-fills a review screen, never an expense.
struct ReceiptScanResult: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case ai, onDevice = "on_device", manual }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var id: UUID = UUID()
        var name: String
        @ExactDecimal var quantity: Decimal = 1
        var amountMinor: Int64
        var confidence: Double = 1

        init(id: UUID = UUID(), name: String, quantity: Decimal = 1, amountMinor: Int64, confidence: Double = 1) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.amountMinor = amountMinor
            self.confidence = confidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            quantity = try container.decodeIfPresent(ExactDecimal.self, forKey: .quantity)?.wrappedValue ?? 1
            amountMinor = try container.decode(Int64.self, forKey: .amountMinor)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        }
    }

    var merchant: String?
    var purchasedAt: Date?
    var currency: CurrencyCode?
    var items: [Item]
    var subtotalMinor: Int64?
    var taxMinor: Int64 = 0
    var serviceFeeMinor: Int64 = 0
    var tipMinor: Int64 = 0
    var discountMinor: Int64 = 0
    var totalMinor: Int64?
    var confidence: Double
    /// Per-field confidence (keys: merchant, date, currency, subtotal, tax, tip, total).
    var fieldConfidence: [String: Double] = [:]
    var source: Source
    var model: String?

    static let lowConfidenceThreshold = 0.7

    init(merchant: String? = nil, purchasedAt: Date? = nil, currency: CurrencyCode? = nil, items: [Item], subtotalMinor: Int64? = nil,
         taxMinor: Int64 = 0, serviceFeeMinor: Int64 = 0, tipMinor: Int64 = 0, discountMinor: Int64 = 0, totalMinor: Int64? = nil,
         confidence: Double, fieldConfidence: [String: Double] = [:], source: Source, model: String? = nil) {
        self.merchant = merchant
        self.purchasedAt = purchasedAt
        self.currency = currency
        self.items = items
        self.subtotalMinor = subtotalMinor
        self.taxMinor = taxMinor
        self.serviceFeeMinor = serviceFeeMinor
        self.tipMinor = tipMinor
        self.discountMinor = discountMinor
        self.totalMinor = totalMinor
        self.confidence = confidence
        self.fieldConfidence = fieldConfidence
        self.source = source
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        merchant = try container.decodeIfPresent(String.self, forKey: .merchant)
        purchasedAt = try? container.decodeIfPresent(Date.self, forKey: .purchasedAt)
        currency = try? container.decodeIfPresent(CurrencyCode.self, forKey: .currency)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        subtotalMinor = try container.decodeIfPresent(Int64.self, forKey: .subtotalMinor)
        taxMinor = try container.decodeIfPresent(Int64.self, forKey: .taxMinor) ?? 0
        serviceFeeMinor = try container.decodeIfPresent(Int64.self, forKey: .serviceFeeMinor) ?? 0
        tipMinor = try container.decodeIfPresent(Int64.self, forKey: .tipMinor) ?? 0
        discountMinor = try container.decodeIfPresent(Int64.self, forKey: .discountMinor) ?? 0
        totalMinor = try container.decodeIfPresent(Int64.self, forKey: .totalMinor)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        fieldConfidence = try container.decodeIfPresent([String: Double].self, forKey: .fieldConfidence) ?? [:]
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .ai
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    func isLowConfidence(_ field: String) -> Bool { (fieldConfidence[field] ?? confidence) < Self.lowConfidenceThreshold }

    var totals: ReceiptTotals {
        ReceiptTotals(itemsMinor: items.map(\.amountMinor), subtotalMinor: subtotalMinor, taxMinor: taxMinor,
                      serviceFeeMinor: serviceFeeMinor, tipMinor: tipMinor, discountMinor: discountMinor, declaredTotalMinor: totalMinor)
    }
}

enum ScanValidationError: Error, Equatable {
    case malformed
    case outOfBounds(String)
}

/// Enforces business invariants on AI output before it is shown for review.
enum ScanResultValidator {
    static let maxItems = 300
    static let maxAmountMinor: Int64 = 10_000_000_000

    static func validate(_ result: ReceiptScanResult) throws -> ReceiptScanResult {
        var clean = result
        guard result.items.count <= maxItems else { throw ScanValidationError.outOfBounds("items") }
        let amounts = [result.subtotalMinor, result.totalMinor].compactMap { $0 } + [result.taxMinor, result.serviceFeeMinor, result.tipMinor, result.discountMinor]
        guard amounts.allSatisfy({ (0...maxAmountMinor).contains($0) }) else { throw ScanValidationError.outOfBounds("totals") }
        guard result.items.allSatisfy({ abs($0.amountMinor) <= maxAmountMinor && $0.quantity > 0 && $0.quantity < 10_000 }) else {
            throw ScanValidationError.outOfBounds("item")
        }
        clean.items = result.items.map { item in
            var item = item
            item.name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            if item.name.isEmpty { item.name = String(localized: "Item") }
            item.confidence = min(max(item.confidence, 0), 1)
            return item
        }
        clean.merchant = result.merchant.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
        clean.confidence = min(max(result.confidence, 0), 1)
        clean.fieldConfidence = result.fieldConfidence.mapValues { min(max($0, 0), 1) }
        if let date = result.purchasedAt, date > Date().addingTimeInterval(86_400 * 2) || date < Date(timeIntervalSince1970: 946_684_800) {
            clean.purchasedAt = nil
        }
        return clean
    }

    static func decode(_ data: Data) throws -> ReceiptScanResult {
        do { return try validate(JSONCoding.decoder.decode(ReceiptScanResult.self, from: data)) }
        catch let error as ScanValidationError { throw error }
        catch { throw ScanValidationError.malformed }
    }
}
