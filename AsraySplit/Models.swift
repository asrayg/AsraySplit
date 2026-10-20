import Foundation
import SwiftUI

struct Person: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
}

struct SplitGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var members: [Person]
    var balance: Double
    var colorHex: String
    var startDate: Date = .now
    var endDate: Date = .now.addingTimeInterval(604_800)
    var currency: String = "USD"
    var budget: Double = 0
}

struct Expense: Identifiable, Codable, Hashable {
    var id = UUID()
    var groupID: UUID
    var title: String
    var amount: Double
    var paidBy: Person
    var date: Date
    var category: Category
    var note: String = ""
    var receiptPath: String? = nil
    var paymentMethod: PaymentMethod = .card
    var splitMethod: SplitMethod = .equally
    var tags: [String] = []
    var allocations: [ExpenseAllocation] = []

    enum Category: String, Codable, CaseIterable {
        case food, travel, home, shopping, entertainment, other
        var icon: String { switch self { case .food: "fork.knife"; case .travel: "airplane"; case .home: "house.fill"; case .shopping: "bag.fill"; case .entertainment: "popcorn.fill"; case .other: "square.grid.2x2.fill" } }
    }
}

enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case cash, card, bank, venmo, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String { switch self { case .cash: "banknote.fill"; case .card: "creditcard.fill"; case .bank: "building.columns.fill"; case .venmo: "v.circle.fill"; case .other: "ellipsis.circle.fill" } }
}

enum SplitMethod: String, Codable, CaseIterable, Identifiable {
    case equally, amounts, percentages, shares
    var id: String { rawValue }
    var title: String { switch self { case .equally: "Equally"; case .amounts: "Exact amounts"; case .percentages: "Percentages"; case .shares: "Shares" } }
}

struct ExpenseAllocation: Identifiable, Codable, Hashable {
    var id: UUID { personID }
    var personID: UUID
    var value: Double
    var owedAmount: Double
}

struct ReceiptItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var quantity: Int = 1
    var price: Double
    var assignedTo: Set<UUID> = []
}

struct ReceiptDraft: Codable, Equatable {
    var merchant = ""
    var date = Date()
    var items: [ReceiptItem] = []
    var subtotal: Double = 0
    var tax: Double = 0
    var tip: Double = 0
    var discount: Double = 0
    var currency = "USD"
    var confidence: Double = 0
    var rawText = ""
    var total: Double { subtotal + tax + tip - discount }
}

struct Balance: Identifiable { let id = UUID(); let person: Person; let amount: Double }

extension Color {
    static let ink = Color(red: 0.035, green: 0.055, blue: 0.07)
    static let panel = Color(red: 0.075, green: 0.105, blue: 0.12)
    static let softMint = Color(red: 0.43, green: 0.93, blue: 0.71)
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

