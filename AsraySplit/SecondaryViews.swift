import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    var filtered: [SplitGroup] { query.isEmpty ? store.groups : store.groups.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section { ForEach(filtered) { group in NavigationLink(destination: GroupDetailView(group: group)) { HStack(spacing: 14) { Text(group.emoji).font(.title).frame(width: 52, height: 52).background(Color(hex: group.colorHex).opacity(0.16), in: RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading) { Text(group.name).bold(); Text("\(group.members.count) people").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(abs(group.balance), format: .currency(code: "USD")).font(.subheadline.bold()).foregroundStyle(group.balance >= 0 ? Color.softMint : Color.orange) } } } }
        }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("Groups").searchable(text: $query).toolbar { Button(action: addGroup) { Image(systemName: "plus") } }
    }
    private func addGroup() { store.groups.append(SplitGroup(name: "New group", emoji: "✨", members: [store.currentUser], balance: 0, colorHex: "23C58A")) }
}

struct GroupDetailView: View {
    @EnvironmentObject private var store: AppStore
    let group: SplitGroup
    var expenses: [Expense] { store.expenses.filter { $0.groupID == group.id }.sorted { $0.date > $1.date } }
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            Text(group.emoji).font(.system(size: 48)).frame(width: 86, height: 86).background(Color(hex: group.colorHex).opacity(0.18), in: RoundedRectangle(cornerRadius: 26))
            Text(group.name).font(.title.bold())
            Text(group.balance >= 0 ? "You are owed \(abs(group.balance).formatted(.currency(code: "USD")))" : "You owe \(abs(group.balance).formatted(.currency(code: "USD")))").foregroundStyle(group.balance >= 0 ? Color.softMint : Color.orange)
            HStack { ForEach(group.members) { Avatar(name: $0.name, size: 42) }; Button(action: {}) { Image(systemName: "plus").frame(width: 42, height: 42).background(Color.panel, in: Circle()) } }
            Button { store.showScanner = true } label: { Label("Scan a receipt", systemImage: "viewfinder").font(.headline).frame(maxWidth: .infinity).padding().background(Color.softMint, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.ink) }
            VStack(alignment: .leading, spacing: 18) { Text("Expenses").font(.title3.bold()); if expenses.isEmpty { ContentUnavailableView("No expenses yet", systemImage: "receipt", description: Text("Scan a receipt or add one manually.")) }; ForEach(expenses) { ExpenseRow(expense: $0) } }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20) }.background(Color.ink).toolbar { Button("Settle up") {} }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { List(store.recentExpenses) { ExpenseRow(expense: $0).listRowBackground(Color.clear).padding(.vertical, 5) }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("Activity") }
}

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        List {
            Section { HStack(spacing: 15) { Avatar(name: store.currentUser.name, size: 58); VStack(alignment: .leading) { Text(store.currentUser.name).font(.headline); Text(store.backend.isConfigured ? "Supabase connected" : "Demo mode · not synced").font(.caption).foregroundStyle(store.backend.isConfigured ? Color.softMint : Color.orange) } } }
            Section("Smart tools") { Label("Spending insights", systemImage: "sparkles"); Label("Recurring expenses", systemImage: "repeat"); Label("Default splits", systemImage: "slider.horizontal.3") }
            Section("Data") { Label("Export CSV", systemImage: "square.and.arrow.up"); Label("Currencies", systemImage: "dollarsign.arrow.circlepath") }
            Section { NavigationLink("Supabase setup") { SetupView() } }
        }.scrollContentBackground(.hidden).background(Color.ink).navigationTitle("You")
    }
}

struct SetupView: View {
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) { Text("Connect Supabase").font(.title.bold()); Text("1. Create a Supabase project.\n2. Run supabase/migrations/001_initial.sql.\n3. Deploy the scan-receipt function.\n4. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to Info.plist.\n5. Set OPENAI_API_KEY as an Edge Function secret."); Text("The publishable key can live in the app. Never put a secret or service-role key in iOS.").foregroundStyle(.secondary); Label("Until configured, everything remains available in local demo mode.", systemImage: "checkmark.shield.fill").foregroundStyle(Color.softMint) }.padding(20) }.background(Color.ink) }
}
