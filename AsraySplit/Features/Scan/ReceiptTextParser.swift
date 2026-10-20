import Foundation
import UIKit
import Vision

/// On-device OCR fallback (no network, no AI). Produces a low-confidence draft in exact minor units
/// that the user must review, exactly like an AI result.
enum ReceiptTextParser {
    /// Trailing amount on a line. Currencies with minor units require the fraction ("12" alone is
    /// usually a table number or quantity, not a price).
    private static func amountPattern(for currency: CurrencyCode) -> NSRegularExpression {
        let fraction = currency.fractionDigits == 0 ? "" : "[.,]\\d{\(currency.fractionDigits)}"
        return try! NSRegularExpression(pattern: "(-?\\(?[$€£¥₹]?\\s?\\d{1,3}(?:[.,\\s]?\\d{3})*\(fraction)\\)?)\\s*[A-Z]{0,3}\\s*$")
    }
    private static let quantityPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})\s*[xX@]\s+"#)

    static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw ReceiptImageError.unreadable }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Group observations into visual lines (same baseline), left to right.
                let sorted = observations.sorted { lhs, rhs in
                    abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.008 ? lhs.boundingBox.minX < rhs.boundingBox.minX : lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                var lines: [(y: CGFloat, text: String)] = []
                for observation in sorted {
                    guard let text = observation.topCandidates(1).first?.string else { continue }
                    if let last = lines.last, abs(last.y - observation.boundingBox.midY) < 0.008 {
                        lines[lines.count - 1].text += " " + text
                    } else {
                        lines.append((observation.boundingBox.midY, text))
                    }
                }
                continuation.resume(returning: lines.map(\.text))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    struct AmountLine: Equatable {
        var label: String
        /// Magnitude in minor units; see `negative`.
        var minor: Int64
        var negative: Bool
    }

    /// Splits "Booking Fee $2.75" into label + exact amount. Nil when the line has no trailing amount.
    static func amountLine(_ line: String, currency: CurrencyCode, locale: Locale = .current) -> AmountLine? {
        amountLine(line, pattern: amountPattern(for: currency), parser: MoneyParser(locale: locale), currency: currency)
    }

    private static func amountLine(_ line: String, pattern: NSRegularExpression, parser: MoneyParser, currency: CurrencyCode) -> AmountLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range), let amountRange = Range(match.range(at: 1), in: line) else { return nil }
        var amountText = String(line[amountRange])
        let negative = amountText.contains("-") || amountText.contains("(") || amountText.contains("−")
        amountText = amountText.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "−", with: "")
        guard let money = try? parser.parse(amountText, currency: currency) else { return nil }
        var label = String(line[..<amountRange.lowerBound])
        // "−$2.00" puts the minus before the symbol, outside the match.
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let leadingMinus = trimmedLabel.hasSuffix("-") || trimmedLabel.hasSuffix("−")
        label = label.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "−")))
        return AmountLine(label: label, minor: money.minorUnits, negative: negative || leadingMinus)
    }

    static func scan(image: UIImage, currency: CurrencyCode, locale: Locale = .current) async throws -> ReceiptScanResult {
        parse(lines: try await recognizeText(in: image), currency: currency, locale: locale)
    }

    static func parse(_ text: String, currency: CurrencyCode, locale: Locale = .current) -> ReceiptScanResult {
        parse(lines: text.components(separatedBy: .newlines), currency: currency, locale: locale)
    }

    static func parse(lines rawLines: [String], currency: CurrencyCode, locale: Locale = .current) -> ReceiptScanResult {
        let parser = MoneyParser(locale: locale)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var items: [ReceiptScanResult.Item] = []
        var subtotal: Int64?, tax: Int64 = 0, tip: Int64 = 0, fee: Int64 = 0, discount: Int64 = 0, total: Int64?
        var merchant: String?
        let pattern = amountPattern(for: currency)

        for line in lines {
            guard let parsed = amountLine(line, pattern: pattern, parser: parser, currency: currency) else {
                if merchant == nil, line.rangeOfCharacter(from: .letters) != nil, line.count >= 3 { merchant = line.capitalized }
                continue
            }
            let amount = parsed.minor, negative = parsed.negative
            var label = parsed.label
            let lower = label.lowercased()

            if lower.contains("subtotal") || lower.contains("sub total") || lower.contains("net amount") { subtotal = amount }
            else if lower.contains("tax") || lower.contains("vat") || lower.contains("gst") || lower.contains("iva") || lower.contains("mwst") { tax += amount }
            else if lower.contains("tip") || lower.contains("gratuity") || lower.contains("pourboire") { tip += amount }
            else if lower.contains("service") || lower.contains("fee") || lower.contains("cover") { fee += amount }
            else if lower.contains("discount") || lower.contains("coupon") || lower.contains("promo") || negative { discount += amount }
            else if lower.contains("total") || lower.contains("amount due") || lower.contains("balance due") || lower == "due" { total = amount }
            else if lower.contains("change") || lower.contains("cash") || lower.contains("visa") || lower.contains("mastercard") || lower.contains("card") { continue }
            else if !label.isEmpty, amount > 0 {
                var quantity = Decimal(1)
                let labelRange = NSRange(label.startIndex..., in: label)
                if let q = quantityPattern.firstMatch(in: label, range: labelRange), let qRange = Range(q.range(at: 1), in: label), let value = Int(label[qRange]) {
                    quantity = Decimal(value)
                    label = quantityPattern.stringByReplacingMatches(in: label, range: labelRange, withTemplate: "")
                }
                items.append(.init(name: label.capitalized, quantity: quantity, amountMinor: amount, confidence: 0.5))
            }
        }

        let itemsSum = items.reduce(0) { $0 + $1.amountMinor }
        let reconciles = (subtotal ?? itemsSum) == itemsSum && total.map { $0 == (subtotal ?? itemsSum) + tax + fee + tip - discount } ?? false
        return ReceiptScanResult(merchant: merchant, purchasedAt: nil, currency: currency, items: items, subtotalMinor: subtotal,
                                 taxMinor: tax, serviceFeeMinor: fee, tipMinor: tip, discountMinor: discount, totalMinor: total,
                                 confidence: items.isEmpty ? 0.2 : (reconciles ? 0.65 : 0.4), fieldConfidence: ["merchant": 0.4],
                                 source: .onDevice, model: "vision")
    }
}
