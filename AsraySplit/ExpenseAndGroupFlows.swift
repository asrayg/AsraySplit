import SwiftUI
import UserNotifications

struct CreateGroupView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "✈️"
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(604_800)
    @State private var currency = "USD"
    @State private var budget = 0.0
    @State private var invitees: [String] = [""]
    private let emojis = ["✈️", "🏝️", "⛷️", "🚗", "🏕️", "🏙️", "🎉", "🏠"]
    private let currencies = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "INR", "MXN"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Trip name", text: $name)
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(emojis, id: \.self) { value in Button(value) { emoji = value }.font(.title).padding(9).background(emoji == value ? Color.softMint.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 12)) } } }
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
                Section("Money") {
                    Picker("Home currency", selection: $currency) { ForEach(currencies, id: \.self) { Text($0) } }
                    TextField("Trip budget (optional)", value: $budget, format: .number).keyboardType(.decimalPad)
                }
                Section("Travelers") {
                    ForEach(invitees.indices, id: \.self) { index in TextField("Name or email", text: $invitees[index]) }
                    Button { invitees.append("") } label: { Label("Add traveler", systemImage: "person.badge.plus") }
                }
            }
            .navigationTitle("New trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }
    private func create() {
        let people = invitees.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { Person(name: $0) }
        store.createGroup(SplitGroup(name: name, emoji: emoji, members: [store.currentUser] + people, balance: 0, colorHex: "23C58A", startDate: startDate, endDate: endDate, currency: currency, budget: budget))
        dismiss()
    }
}

struct AddExpenseView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = 0.0
    @State private var groupID: UUID?
    @State private var payerID: UUID?
    @State private var category = Expense.Category.food
    @State private var payment = PaymentMethod.card
    @State private var splitMethod = SplitMethod.equally
    @State private var values: [UUID: Double] = [:]
    @State private var selected: Set<UUID> = []
    @State private var tags: [String] = []
    @State private var customTag = ""
    @State private var date = Date()
    private let commonTags = ["cash", "reimbursable", "shared", "booking", "food", "transport"]
    private var group: SplitGroup { store.groups.first { $0.id == groupID } ?? store.groups[0] }
    private var payer: Person { group.members.first { $0.id == payerID } ?? store.currentUser }
    private var activeMembers: [Person] { group.members.filter { selected.contains($0.id) } }
    private var allocatedTotal: Double {
        switch splitMethod { case .equally: amount; case .amounts: activeMembers.reduce(0) { $0 + (values[$1.id] ?? 0) }; case .percentages: activeMembers.reduce(0) { $0 + (values[$1.id] ?? 0) }; case .shares: activeMembers.reduce(0) { $0 + (values[$1.id] ?? 0) } }
    }
    private var isValid: Bool {
        guard !title.isEmpty, amount > 0, !activeMembers.isEmpty else { return false }
        if splitMethod == .amounts { return abs(allocatedTotal - amount) < 0.01 }
        if splitMethod == .percentages { return abs(allocatedTotal - 100) < 0.01 }
        if splitMethod == .shares { return allocatedTotal > 0 }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was it for?", text: $title)
                    HStack(alignment: .firstTextBaseline) { Text(group.currency).foregroundStyle(.secondary); TextField("0.00", value: $amount, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).font(.system(size: 34, weight: .bold, design: .rounded)) }
                    Picker("Group", selection: Binding(get: { groupID ?? store.groups[0].id }, set: { groupID = $0; resetMembers() })) { ForEach(store.groups) { Text("\($0.emoji) \($0.name)").tag($0.id) } }
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Paid with") {
                    Picker("Method", selection: $payment) { ForEach(PaymentMethod.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } }
                    Picker("Paid by", selection: Binding(get: { payerID ?? store.currentUser.id }, set: { payerID = $0 })) { ForEach(group.members) { Text($0.name).tag($0.id) } }
                }
                Section("Split") {
                    Picker("Type", selection: $splitMethod) { ForEach(SplitMethod.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                    ForEach(group.members) { member in allocationRow(member) }
                    if splitMethod == .amounts { validation("Assigned", allocatedTotal, target: amount, suffix: group.currency) }
                    if splitMethod == .percentages { validation("Assigned", allocatedTotal, target: 100, suffix: "%") }
                }
                Section("Category") { Picker("Category", selection: $category) { ForEach(Expense.Category.allCases, id: \.self) { Label($0.rawValue.capitalized, systemImage: $0.icon).tag($0) } } }
                Section("Tags") {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(commonTags, id: \.self) { tag in Button { toggleTag(tag) } label: { Text(tag).padding(.horizontal, 11).padding(.vertical, 7).background(tags.contains(tag) ? Color.softMint.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule()) } } } }
                    HStack { TextField("Custom tag", text: $customTag); Button("Add") { let clean = customTag.lowercased().trimmingCharacters(in: .whitespaces); if !clean.isEmpty && !tags.contains(clean) { tags.append(clean) }; customTag = "" }.disabled(customTag.isEmpty) }
                }
            }
            .navigationTitle("Add expense")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!isValid) } }
            .onAppear { if groupID == nil { groupID = store.pendingGroupID ?? store.groups.first?.id }; resetMembers() }
            .onDisappear { store.pendingGroupID = nil }
        }
    }

    @ViewBuilder private func allocationRow(_ member: Person) -> some View {
        let included = selected.contains(member.id)
        HStack {
            Button { if included { selected.remove(member.id) } else { selected.insert(member.id) } } label: { Image(systemName: included ? "checkmark.circle.fill" : "circle").foregroundStyle(included ? Color.softMint : Color.secondary) }
            Avatar(name: member.name, size: 30); Text(member.name); Spacer()
            if included && splitMethod != .equally {
                TextField(splitMethod == .percentages ? "0%" : splitMethod == .shares ? "1" : "0.00", value: Binding(get: { values[member.id] ?? (splitMethod == .shares ? 1 : 0) }, set: { values[member.id] = $0 }), format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 76)
            } else if included { Text((amount / Double(max(activeMembers.count, 1))), format: .currency(code: group.currency)).foregroundStyle(.secondary) }
        }
    }
    private func validation(_ title: String, _ value: Double, target: Double, suffix: String) -> some View { HStack { Text(title).font(.caption); Spacer(); Text("\(value.formatted()) / \(target.formatted()) \(suffix)").font(.caption.bold()).foregroundStyle(abs(value - target) < 0.01 ? Color.softMint : Color.orange) } }
    private func resetMembers() { selected = Set(group.members.map(\.id)); payerID = group.members.contains(store.currentUser) ? store.currentUser.id : group.members.first?.id; values = [:] }
    private func toggleTag(_ tag: String) { if tags.contains(tag) { tags.removeAll { $0 == tag } } else { tags.append(tag) } }
    private func save() {
        let denominator = splitMethod == .shares ? max(allocatedTotal, 1) : 1
        let allocations = activeMembers.map { member -> ExpenseAllocation in
            let value = values[member.id] ?? (splitMethod == .shares ? 1 : 0)
            let owed: Double
            switch splitMethod { case .equally: owed = amount / Double(activeMembers.count); case .amounts: owed = value; case .percentages: owed = amount * value / 100; case .shares: owed = amount * value / denominator }
            return ExpenseAllocation(personID: member.id, value: value, owedAmount: owed)
        }
        var finalTags = tags; if payment == .cash && !finalTags.contains("cash") { finalTags.append("cash") }
        store.addExpense(Expense(groupID: group.id, title: title, amount: amount, paidBy: payer, date: date, category: category, paymentMethod: payment, splitMethod: splitMethod, tags: finalTags, allocations: allocations))
        dismiss()
    }
}

struct SettleUpView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let group: SplitGroup
    @State private var amount = 0.0
    @State private var personID: UUID?
    @State private var payment = PaymentMethod.cash
    var body: some View { NavigationStack { Form { Section { Text(group.balance >= 0 ? "Someone owes you" : "You owe the group").foregroundStyle(.secondary); TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2))).keyboardType(.decimalPad).font(.title.bold()) }; Section { Picker("With", selection: Binding(get: { personID ?? group.members.first(where: { $0 != store.currentUser })?.id ?? store.currentUser.id }, set: { personID = $0 })) { ForEach(group.members.filter { $0 != store.currentUser }) { Text($0.name).tag($0.id) } }; Picker("Method", selection: $payment) { ForEach(PaymentMethod.allCases) { Label($0.title, systemImage: $0.icon).tag($0) } } } }.navigationTitle("Settle up").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Record") { if let person = group.members.first(where: { $0.id == personID }) ?? group.members.first(where: { $0 != store.currentUser }) { store.settle(group: group, amount: amount, with: person, method: payment) }; dismiss() }.disabled(amount <= 0) } }.onAppear { amount = abs(group.balance); personID = group.members.first(where: { $0 != store.currentUser })?.id } } }
}

final class NotificationService {
    static let shared = NotificationService(); private init() {}
    func requestPermission() async -> Bool { (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false }
    func scheduleExpenseAdded(_ title: String, amount: Double) { let content = UNMutableNotificationContent(); content.title = "Expense saved"; content.body = "\(title) · \(amount.formatted(.currency(code: "USD")))"; content.sound = .default; let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)); UNUserNotificationCenter.current().add(request) }
    func scheduleTripReminder() { let content = UNMutableNotificationContent(); content.title = "Anything to split?"; content.body = "Add today’s vacation expenses while they’re fresh."; content.sound = .default; var time = DateComponents(); time.hour = 20; let request = UNNotificationRequest(identifier: "daily-trip-reminder", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)); UNUserNotificationCenter.current().add(request) }
    func removeTripReminder() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-trip-reminder"]) }
}
