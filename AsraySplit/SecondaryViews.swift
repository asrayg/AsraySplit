import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var showCreate = false
    var filtered: [SplitGroup] { query.isEmpty ? store.groups : store.groups.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section { ForEach(filtered) { group in NavigationLink(destination: GroupDetailView(group: group)) { HStack(spacing: 14) { Text(group.emoji).font(.title).frame(width: 52, height: 52).background(Color(hex: group.colorHex).opacity(0.16), in: RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading) { Text(group.name).bold(); Text("\(group.members.count) people").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(abs(group.balance), format: .currency(code: "USD")).font(.subheadline.bold()).foregroundStyle(group.balance >= 0 ? Color.softMint : Color.orange) } } } }
        }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("Groups").searchable(text: $query).toolbar { Button { showCreate = true } label: { Image(systemName: "plus") } }.sheet(isPresented: $showCreate) { CreateGroupView() }
    }
}

struct GroupDetailView: View {
    @EnvironmentObject private var store: AppStore
    let group: SplitGroup
    @State private var showSettle = false
    var expenses: [Expense] { store.expenses.filter { $0.groupID == group.id }.sorted { $0.date > $1.date } }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            Text(group.emoji).font(.system(size: 48)).frame(width: 86, height: 86).background(Color(hex: group.colorHex).opacity(0.18), in: RoundedRectangle(cornerRadius: 26))
            Text(group.name).font(.title.bold())
            Text(group.balance >= 0 ? "You are owed \(abs(group.balance).formatted(.currency(code: "USD")))" : "You owe \(abs(group.balance).formatted(.currency(code: "USD")))").foregroundStyle(group.balance >= 0 ? Color.softMint : Color.orange)
            if group.budget > 0 { VStack(alignment: .leading, spacing: 7) { HStack { Text("Trip budget").font(.caption.bold()); Spacer(); Text("\(expenses.reduce(0) { $0 + $1.amount }.formatted(.currency(code: group.currency))) of \(group.budget.formatted(.currency(code: group.currency)))").font(.caption) }; ProgressView(value: min(expenses.reduce(0) { $0 + $1.amount } / group.budget, 1)).tint(.softMint) }.padding().background(Color.panel, in: RoundedRectangle(cornerRadius: 16)) }
            HStack { ForEach(group.members) { Avatar(name: $0.name, size: 42) }; Spacer(); Text(group.startDate.formatted(date: .abbreviated, time: .omitted) + " – " + group.endDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            HStack { Button { store.pendingGroupID = group.id; store.showAddExpense = true } label: { Label("Add amount", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding().background(Color.panel, in: RoundedRectangle(cornerRadius: 16)) }; Button { store.showScanner = true } label: { Label("Scan", systemImage: "viewfinder").font(.headline).frame(maxWidth: .infinity).padding().background(Color.softMint, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.ink) } }
            VStack(alignment: .leading, spacing: 18) { Text("Expenses").font(.title3.bold()); if expenses.isEmpty { ContentUnavailableView("No expenses yet", systemImage: "receipt", description: Text("Scan a receipt or add one manually.")) }; ForEach(expenses) { expense in NavigationLink(destination: ExpenseDetailView(expense: expense)) { ExpenseRow(expense: expense) }.buttonStyle(.plain) } }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20) }.background(Color.ink).toolbar { Button("Settle up") { showSettle = true } }.sheet(isPresented: $showSettle) { SettleUpView(group: group) }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { List(store.recentExpenses) { expense in NavigationLink(destination: ExpenseDetailView(expense: expense)) { ExpenseRow(expense: expense).padding(.vertical, 5) }.listRowBackground(Color.clear) }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("Activity") }
}

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    @State private var notifications = false
    var body: some View {
        List {
            Section { HStack(spacing: 15) { Avatar(name: store.currentUser.name, size: 58); VStack(alignment: .leading) { Text(store.currentUser.name).font(.headline); Text(store.backend.isConfigured ? "Supabase connected" : "Demo mode · not synced").font(.caption).foregroundStyle(store.backend.isConfigured ? Color.softMint : Color.orange) } } }
            Section("Smart tools") { Toggle(isOn: $notifications) { Label("Daily trip reminder", systemImage: "bell.fill") }.onChange(of: notifications) { _, enabled in Task { if enabled { let granted = await NotificationService.shared.requestPermission(); if granted { NotificationService.shared.scheduleTripReminder() } } else { NotificationService.shared.removeTripReminder() } } }; Label("Spending insights", systemImage: "sparkles"); Label("Recurring expenses", systemImage: "repeat"); Label("Default splits", systemImage: "slider.horizontal.3") }
            Section("Data") { Label("Export CSV", systemImage: "square.and.arrow.up"); Label("Currencies", systemImage: "dollarsign.arrow.circlepath") }
            Section { NavigationLink("Supabase setup") { SetupView() } }
        }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("You")
    }
}

struct SetupView: View {
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) { Text("Connect Supabase").font(.title.bold()); Text("1. Create a Supabase project.\n2. Run supabase/migrations/001_initial.sql.\n3. Deploy the scan-receipt function.\n4. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to Info.plist.\n5. Set OPENAI_API_KEY as an Edge Function secret."); Text("The publishable key can live in the app. Never put a secret or service-role key in iOS.").foregroundStyle(.secondary); Label("Until configured, everything remains available in local demo mode.", systemImage: "checkmark.shield.fill").foregroundStyle(Color.softMint) }.padding(20) }.background(Color.ink) }
}
