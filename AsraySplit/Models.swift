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

    enum Category: String, Codable, CaseIterable {
        case food, travel, home, shopping, entertainment, other
        var icon: String { switch self { case .food: "fork.knife"; case .travel: "airplane"; case .home: "house.fill"; case .shopping: "bag.fill"; case .entertainment: "popcorn.fill"; case .other: "square.grid.2x2.fill" } }
    }
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

