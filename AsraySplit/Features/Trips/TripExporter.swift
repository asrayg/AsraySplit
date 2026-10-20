import Foundation

/// Builds a CSV ledger and a plain-text summary from canonical data. Totals reconcile exactly with
/// the in-app ledger because both use the same stored minor units.
enum TripExporter {
    static func csv(trip: Trip, expenses: [Expense], settlements: [Settlement]) -> String {
        let people = trip.participants
        var header = ["type", "date", "description", "merchant", "category", "payment_method", "paid_by",
                      "amount", "currency", "exchange_rate", "rate_source", "amount_\(trip.baseCurrency.rawValue.lowercased())", "tags", "notes"]
        header += people.map { "share_\($0.displayName)" }
        var rows = [header]
        let dateFormatter = ISO8601DateFormatter()
        func plain(_ minor: Int64, _ currency: CurrencyCode) -> String { MoneyParser(locale: Locale(identifier: "en_US_POSIX")).editableString(for: Money(minorUnits: minor, currency: currency)) }

        for expense in expenses.filter({ !$0.isDeleted }).sorted(by: { $0.spentAt < $1.spentAt }) {
            var row = ["expense", dateFormatter.string(from: expense.spentAt), expense.title, expense.merchant ?? "", expense.category.rawValue,
                       expense.paymentMethod.rawValue, expense.payments.map { trip.name(of: $0.participantId) }.joined(separator: "; "),
                       plain(expense.originalMinor, expense.originalCurrency), expense.originalCurrency.rawValue,
                       NSDecimalNumber(decimal: expense.exchangeRate).stringValue, expense.rateProvider ?? (expense.isForeignCurrency ? "manual" : ""),
                       plain(expense.baseMinor, expense.baseCurrency), expense.tags.joined(separator: " "), expense.notes ?? ""]
            row += people.map { person in plain(expense.baseShare(for: person.id), expense.baseCurrency) }
            rows.append(row)
        }
        for settlement in settlements.filter({ !$0.isDeleted }).sorted(by: { $0.settledAt < $1.settledAt }) {
            var row = ["payment", dateFormatter.string(from: settlement.settledAt),
                       "\(trip.name(of: settlement.fromParticipantId)) → \(trip.name(of: settlement.toParticipantId))", "", "", settlement.method.rawValue,
                       trip.name(of: settlement.fromParticipantId), plain(settlement.amountMinor, settlement.currency), settlement.currency.rawValue,
                       NSDecimalNumber(decimal: settlement.exchangeRate).stringValue, "", plain(settlement.baseAmountMinor, trip.baseCurrency), "", settlement.note ?? ""]
            row += people.map { _ in "" }
            rows.append(row)
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting, plus a leading apostrophe for cells that spreadsheets would treat as formulas.
    static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@\t\r".contains(first), Decimal(string: value) == nil { value = "'" + value }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func summary(trip: Trip, expenses: [Expense], balances: [ParticipantBalance], transfers: [SuggestedTransfer]) -> String {
        let live = expenses.filter { !$0.isDeleted }
        let total = live.reduce(Int64(0)) { $0 + $1.baseMinor }
        var lines = ["\(trip.emoji) \(trip.name)"]
        if let start = trip.startDate, let end = trip.endDate { lines.append("\(start.shortDay) – \(end.shortDay)") }
        lines.append(String(localized: "Total spent: \(Money(minorUnits: total, currency: trip.baseCurrency).formatted()) across \(live.count) expenses"))
        lines.append("")
        lines.append(String(localized: "Balances:"))
        for balance in balances {
            let money = Money(minorUnits: abs(balance.netMinor), currency: trip.baseCurrency).formatted()
            let state = balance.netMinor > 0 ? String(localized: "is owed \(money)") : balance.netMinor < 0 ? String(localized: "owes \(money)") : String(localized: "is settled")
            lines.append("• \(trip.name(of: balance.participantID)) \(state)")
        }
        if !transfers.isEmpty {
            lines.append("")
            lines.append(String(localized: "To settle up:"))
            for transfer in transfers {
                lines.append("• \(trip.name(of: transfer.from)) → \(trip.name(of: transfer.to)): \(Money(minorUnits: transfer.amountMinor, currency: trip.baseCurrency).formatted())")
            }
        }
        return lines.joined(separator: "\n")
    }
}
