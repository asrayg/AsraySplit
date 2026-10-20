import SwiftUI

struct ExpenseDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let expense: Expense
    private var group: SplitGroup? { store.groups.first { $0.id == expense.groupID } }
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: expense.category.icon).font(.largeTitle).foregroundStyle(Color.softMint).frame(width: 70, height: 70).background(Color.softMint.opacity(0.12), in: Circle())
                    Text(expense.title).font(.title2.bold())
                    Text(expense.amount, format: .currency(code: group?.currency ?? "USD")).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(expense.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            Section("Details") {
                LabeledContent("Paid by", value: expense.paidBy.name)
                LabeledContent("Method") { Label(expense.paymentMethod.title, systemImage: expense.paymentMethod.icon) }
                LabeledContent("Split", value: expense.splitMethod.title)
                LabeledContent("Category", value: expense.category.rawValue.capitalized)
            }
            if !expense.tags.isEmpty { Section("Tags") { Text(expense.tags.map { "#\($0)" }.joined(separator: "   ")).foregroundStyle(Color.softMint) } }
            if let group, !expense.allocations.isEmpty {
                Section("Shares") { ForEach(expense.allocations) { allocation in if let person = group.members.first(where: { $0.id == allocation.personID }) { HStack { Avatar(name: person.name, size: 30); Text(person.name); Spacer(); Text(allocation.owedAmount, format: .currency(code: group.currency)).bold() } } } }
            }
            Section { Button(role: .destructive) { store.deleteExpense(expense); dismiss() } label: { Label("Delete expense", systemImage: "trash") } }
        }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("Expense").navigationBarTitleDisplayMode(.inline)
    }
}
