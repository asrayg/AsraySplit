import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var groups: [SplitGroup] = [] { didSet { save() } }
    @Published var expenses: [Expense] = [] { didSet { save() } }
    @Published var selectedTab = 0
    @Published var showScanner = false
    @Published var toast: String?
    let currentUser = Person(name: "Alex Ray")
    let backend = SupabaseService()

    init() { load() }

    var totalOwedToYou: Double { groups.map(\.balance).filter { $0 > 0 }.reduce(0, +) }
    var totalYouOwe: Double { abs(groups.map(\.balance).filter { $0 < 0 }.reduce(0, +)) }
    var recentExpenses: [Expense] { expenses.sorted { $0.date > $1.date } }

    func addExpense(from draft: ReceiptDraft, group: SplitGroup, imageData: Data?) async {
        let expense = Expense(groupID: group.id, title: draft.merchant.isEmpty ? "Receipt" : draft.merchant,
                              amount: draft.total, paidBy: currentUser, date: draft.date, category: .food,
                              note: "AI itemized · \(draft.items.count) items")
        expenses.append(expense)
        if backend.isConfigured {
            do { try await backend.save(expense: expense, draft: draft, imageData: imageData) }
            catch { toast = "Saved locally — sync will retry later" }
        } else { toast = "Saved in demo mode" }
    }

    private struct Snapshot: Codable { let groups: [SplitGroup]; let expenses: [Expense] }
    private var fileURL: URL { URL.documentsDirectory.appending(path: "asray-split.json") }
    private func save() { try? JSONEncoder().encode(Snapshot(groups: groups, expenses: expenses)).write(to: fileURL, options: .atomic) }
    private func load() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            groups = saved.groups; expenses = saved.expenses; return
        }
        let sam = Person(name: "Sam Chen"), maya = Person(name: "Maya Patel"), jordan = Person(name: "Jordan Lee")
        groups = [
            SplitGroup(name: "Lisbon Escape", emoji: "🌊", members: [currentUser, sam, maya, jordan], balance: 142.38, colorHex: "23C58A"),
            SplitGroup(name: "Apartment 4B", emoji: "🪴", members: [currentUser, maya], balance: -64.20, colorHex: "786EF2"),
            SplitGroup(name: "Sunday Crew", emoji: "🥡", members: [currentUser, sam, jordan], balance: 28.50, colorHex: "F5A34A")]
        let now = Date()
        expenses = [
            Expense(groupID: groups[0].id, title: "Taberna da Rua", amount: 186.40, paidBy: currentUser, date: now.addingTimeInterval(-4200), category: .food, note: "AI itemized · 8 items"),
            Expense(groupID: groups[1].id, title: "October utilities", amount: 128.40, paidBy: maya, date: now.addingTimeInterval(-86400), category: .home),
            Expense(groupID: groups[0].id, title: "Airport transfer", amount: 54, paidBy: sam, date: now.addingTimeInterval(-172800), category: .travel)]
    }
}
