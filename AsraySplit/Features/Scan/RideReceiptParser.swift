import Foundation

/// Parses Uber and Lyft receipts. Neither company offers ride-history APIs to new third-party apps,
/// so rides are imported from receipts riders already have (screenshots, PDFs, shared text).
enum RideReceiptParser {
    private static let timePrefix = try! NSRegularExpression(pattern: #"^(\d{1,2}[:.]\d{2})\s*([AaPp]\.?[Mm]\.?)?\s+(.{4,})$"#)
    private static let tripStats = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*(mi|miles|km|kilometers)\b.*?(\d+\s*(?:min|m)\b(?:\s*\d+\s*s)?)"#, options: [.caseInsensitive])
    private static let lyftFare = try! NSRegularExpression(pattern: #"\((\d+(?:\.\d+)?\s*mi),\s*([\dhms\s]+)\)"#, options: [.caseInsensitive])
    private static let products = ["UberX Share", "UberXL", "UberX", "Uber Comfort", "Comfort Electric", "Comfort", "Uber Black SUV", "Uber Black", "Uber Green", "Uber Pet",
                                   "Lyft XL", "Lyft Lux Black XL", "Lyft Lux Black", "Lyft Lux", "Extra Comfort", "Lyft Pink", "Priority Pickup", "Wait & Save", "Shared"]

    /// Returns the provider if the text looks like an Uber or Lyft ride receipt.
    static func detect(_ lines: [String]) -> RideDetails.Provider? {
        let text = lines.joined(separator: "\n").lowercased()
        let rideWords = ["trip fare", "booking fee", "lyft fare", "thanks for riding", "your ride", "pickup", "drop-off", "dropoff", "your trip", "ride with"]
        guard rideWords.contains(where: text.contains) else { return nil }
        let uber = text.components(separatedBy: "uber").count - 1
        let lyft = text.components(separatedBy: "lyft").count - 1
        if uber == 0 && lyft == 0 { return nil }
        return uber >= lyft ? .uber : .lyft
    }

    static func parse(_ text: String, currency: CurrencyCode, locale: Locale = .current, now: Date = .now) -> (ReceiptScanResult, RideDetails)? {
        parse(lines: text.components(separatedBy: .newlines), currency: currency, locale: locale, now: now)
    }

    /// Builds a single-fare receipt: the fare is one item shared by everyone in the ride, with booking/
    /// service fees, tolls and surcharges as fees, the tip as tip, and promotions as a discount.
    static func parse(lines rawLines: [String], currency: CurrencyCode, locale: Locale = .current, now: Date = .now) -> (ReceiptScanResult, RideDetails)? {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let provider = detect(lines) else { return nil }
        var ride = RideDetails(provider: provider)
        var fare: Int64 = 0, fees: Int64 = 0, tip: Int64 = 0, discount: Int64 = 0
        var total: Int64?
        var stops: [String] = []
        var date: Date?
        var fareLines = 0

        for line in lines {
            let lower = line.lowercased()
            if ride.product == nil, let product = products.first(where: { lower.contains($0.lowercased()) }) {
                ride.product = product
            }
            if let stats = match(tripStats, in: line) { ride.distance = stats[1] + " " + stats[2]; ride.duration = stats[3] }
            if let lyftStats = match(lyftFare, in: line) { ride.distance = lyftStats[1]; ride.duration = lyftStats[2].trimmingCharacters(in: .whitespaces) }
            if date == nil { date = parseDate(line, now: now) }
            if ride.driverName == nil, let range = lower.range(of: "riding with ") ?? lower.range(of: "your driver ") {
                let name = line[range.upperBound...].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                if !name.isEmpty, name.count <= 30 { ride.driverName = name }
            }

            if let stop = stopAddress(line) { stops.append(stop); continue }

            guard let amount = ReceiptTextParser.amountLine(line, currency: currency, locale: locale) else { continue }
            let label = amount.label.lowercased()
            let isPayment = ["visa", "mastercard", "amex", "american express", "discover", "apple pay", "google pay", "paypal", "cash", "••", "****", "*", "card ending", "uber cash", "lyft cash", "charged", "payments"]
                .contains(where: { label.contains($0) }) && !label.contains("total")
            if label.contains("total") || label.hasPrefix("you paid") || label == "amount" {
                total = total ?? amount.minor
            } else if label.contains("tip") || label.contains("gratuity") {
                tip += amount.minor
            } else if isPayment {
                continue
            } else if amount.negative || label.contains("promo") || label.contains("discount") || label.contains("credit") || label.contains("savings") || label.contains("offer") || label.contains("membership") {
                discount += amount.minor
            } else if label.contains("subtotal") {
                continue
            } else if label.contains("fee") || label.contains("surcharge") || label.contains("toll") || label.contains("tax") || label.contains("airport") || label.contains("cancellation") || label.contains("wait time") {
                fees += amount.minor
            } else if label.contains("fare") || label.contains("distance") || label.contains("time") || label.contains("base") || label.contains("minimum") || label.contains("ride") || label.contains("trip") || label.contains("per mile") || label.contains("per minute") {
                fare += amount.minor
                fareLines += 1
            }
        }

        // Without itemized fare lines, the fare is whatever the total leaves after fees and tip.
        if fareLines == 0, let total { fare = total - fees - tip + discount }
        guard fare > 0 else { return nil }
        if stops.count >= 2 { ride.pickup = stops[0]; ride.dropoff = stops[stops.count - 1] }
        else if stops.count == 1 { ride.dropoff = stops[0] }

        let computed = fare + fees + tip - discount
        let reconciled = total == nil || total == computed
        let itemName: String
        if let product = ride.product {
            itemName = product.hasPrefix(provider.displayName) ? product : "\(provider.displayName) \(product)"
        } else {
            itemName = "\(provider.displayName) ride"
        }
        var result = ReceiptScanResult(
            merchant: provider.displayName, purchasedAt: date, currency: currency,
            items: [.init(name: itemName, amountMinor: fare, confidence: fareLines > 0 ? 0.85 : 0.7)],
            subtotalMinor: nil, taxMinor: 0, serviceFeeMinor: fees, tipMinor: tip, discountMinor: discount, totalMinor: total ?? computed,
            confidence: reconciled ? 0.85 : 0.5,
            fieldConfidence: ["merchant": 0.95, "date": date == nil ? 0.3 : 0.8, "total": total == nil ? 0.5 : 0.9, "tip": 0.85],
            source: .onDevice, model: "ride-parser")
        result.ride = ride
        return (result, ride)
    }

    /// Lines like "10:02 PM 123 Main St, San Francisco, CA" or "Pickup 10:02 PM · 123 Main St".
    private static func stopAddress(_ line: String) -> String? {
        var text = line
        for prefix in ["pickup", "pick-up", "picked up", "drop-off", "dropoff", "drop off", "dropped off", "from", "to"] {
            if text.lowercased().hasPrefix(prefix + " ") || text.lowercased().hasPrefix(prefix + ":") {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": ·-"))
                break
            }
        }
        guard let groups = match(timePrefix, in: text) else { return nil }
        let address = groups[3].trimmingCharacters(in: CharacterSet(charactersIn: " ·-|"))
        // An address has letters and isn't an amount line.
        guard address.rangeOfCharacter(from: .letters) != nil, !address.contains("$"), !address.contains("€"), !address.contains("£") else { return nil }
        return String(address.prefix(120))
    }

    private static func parseDate(_ line: String, now: Date) -> Date? {
        let formats = ["MMMM d, yyyy 'at' h:mm a", "MMMM d, yyyy", "MMM d, yyyy", "MMMM d", "d MMMM yyyy", "EEEE, MMMM d, yyyy"]
        let cleaned = line.replacingOccurrences(of: "Here's your receipt for your ride, ", with: "").replacingOccurrences(of: "Your ride on ", with: "")
        let calendar = Calendar(identifier: .gregorian)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let candidate = cleaned.range(of: #"[A-Z][a-z]+,? [A-Z]?[a-z]* ?\d{1,2}(, \d{4})?( at \d{1,2}:\d{2} [AP]M)?"#, options: .regularExpression).map({ String(cleaned[$0]) }) ?? Optional(cleaned),
               var date = formatter.date(from: candidate) {
                if !format.contains("yyyy") {
                    var components = calendar.dateComponents([.month, .day], from: date)
                    components.year = calendar.component(.year, from: now)
                    date = calendar.date(from: components) ?? date
                    if date > now { date = calendar.date(byAdding: .year, value: -1, to: date) ?? date }
                }
                return date
            }
        }
        return nil
    }

    private static func match(_ regex: NSRegularExpression, in line: String) -> [String]? {
        guard let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
