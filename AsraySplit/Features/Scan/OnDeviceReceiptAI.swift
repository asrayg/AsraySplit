import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns OCR lines into a structured receipt with Apple's on-device language model (iOS 26 + Apple
/// Intelligence). Free, offline, no API key. Output is untrusted and always validated.
///
/// The FoundationModels framework only exists in the iOS 26 SDK (Xcode 26+). Built with an older Xcode,
/// this compiles to "unavailable" and the app falls back to nearby helpers or the regex parser.
enum OnDeviceReceiptAI {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static func structure(lines: [String], currency: CurrencyCode) async -> ReceiptScanResult? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable { return await FoundationReceiptParser.parse(lines: lines, currency: currency) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedReceiptItem {
    @Guide(description: "Item name as printed, cleaned up")
    var name: String
    @Guide(description: "Quantity purchased, 1 if not shown")
    var quantity: Int
    @Guide(description: "Line price in minor units (cents), i.e. quantity times unit price")
    var amountMinor: Int
}

@available(iOS 26.0, *)
@Generable
struct GeneratedReceipt {
    @Guide(description: "Store or restaurant name, if printed")
    var merchant: String?
    @Guide(description: "Purchased line items only. Exclude subtotal, tax, tip, fees, discounts, totals and payment lines")
    var items: [GeneratedReceiptItem]
    @Guide(description: "Subtotal in minor units, if printed")
    var subtotalMinor: Int?
    @Guide(description: "Total tax in minor units, 0 if none")
    var taxMinor: Int
    @Guide(description: "Tip or gratuity in minor units, 0 if none")
    var tipMinor: Int
    @Guide(description: "Service charges or fees in minor units, 0 if none")
    var serviceFeeMinor: Int
    @Guide(description: "Discounts as a positive number in minor units, 0 if none")
    var discountMinor: Int
    @Guide(description: "Final total charged in minor units, if printed")
    var totalMinor: Int?
}

@available(iOS 26.0, *)
enum FoundationReceiptParser {
    static func parse(lines: [String], currency: CurrencyCode) async -> ReceiptScanResult? {
        let text = lines.prefix(300).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You read OCR text from a single shopping or restaurant receipt and extract it exactly. \
            Amounts are integers in minor units of \(currency.rawValue) (for USD, $12.50 is 1250). \
            Never invent items or amounts that are not in the text.
            """)
        do {
            let response = try await session.respond(to: "Receipt OCR text:\n\(text)", generating: GeneratedReceipt.self)
            let r = response.content
            let items = r.items.filter { $0.amountMinor != 0 }.map {
                ReceiptScanResult.Item(name: $0.name, quantity: Decimal(max($0.quantity, 1)), amountMinor: Int64($0.amountMinor), confidence: 0.8)
            }
            let itemsSum = items.reduce(Int64(0)) { $0 + $1.amountMinor }
            let total = r.totalMinor.map(Int64.init)
            let reconciles = total == (r.subtotalMinor.map(Int64.init) ?? itemsSum) + Int64(r.taxMinor + r.serviceFeeMinor + r.tipMinor - r.discountMinor)
            let result = ReceiptScanResult(
                merchant: r.merchant, currency: currency, items: items, subtotalMinor: r.subtotalMinor.map(Int64.init),
                taxMinor: Int64(max(r.taxMinor, 0)), serviceFeeMinor: Int64(max(r.serviceFeeMinor, 0)), tipMinor: Int64(max(r.tipMinor, 0)),
                discountMinor: Int64(max(r.discountMinor, 0)), totalMinor: total,
                confidence: reconciles ? 0.85 : 0.6, fieldConfidence: ["merchant": 0.7], source: .ai, model: "apple-on-device")
            return try ScanResultValidator.validate(result)
        } catch {
            Log.scan.notice("On-device model failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
}
#endif
