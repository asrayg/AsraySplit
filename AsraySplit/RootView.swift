import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $store.selectedTab) {
                NavigationStack { HomeView() }.tag(0).tabItem { Label("Home", systemImage: "house.fill") }
                NavigationStack { GroupsView() }.tag(1).tabItem { Label("Groups", systemImage: "person.3.fill") }
                Color.clear.tag(2).tabItem { Label("Scan", systemImage: "viewfinder") }
                NavigationStack { ActivityView() }.tag(3).tabItem { Label("Activity", systemImage: "clock.fill") }
                NavigationStack { ProfileView() }.tag(4).tabItem { Label("You", systemImage: "person.crop.circle.fill") }
            }
            .onChange(of: store.selectedTab) { _, tab in if tab == 2 { store.showScanner = true; store.selectedTab = 0 } }
            Button { store.showScanner = true } label: {
                Image(systemName: "viewfinder").font(.system(size: 23, weight: .bold)).foregroundStyle(Color.ink)
                    .frame(width: 58, height: 58).background(Color.softMint, in: Circle()).shadow(color: .black.opacity(0.4), radius: 12, y: 5)
            }.offset(y: -19).accessibilityLabel("Scan receipt")
        }
        .background(Color.ink.ignoresSafeArea())
        .fullScreenCover(isPresented: $store.showScanner) { ReceiptFlowView() }
        .overlay(alignment: .top) {
            if let toast = store.toast { Text(toast).font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 12).task { try? await Task.sleep(for: .seconds(2)); store.toast = nil } }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text("Tuesday, October 20").font(.caption).foregroundStyle(.secondary); Text("Hey, Alex").font(.largeTitle.bold()) }
                    Spacer(); Avatar(name: store.currentUser.name, size: 46)
                }
                BalanceCard()
                HStack { Text("Your groups").font(.title3.bold()); Spacer(); NavigationLink("See all", destination: GroupsView()).font(.subheadline).foregroundStyle(Color.softMint) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) { ForEach(store.groups) { group in NavigationLink(destination: GroupDetailView(group: group)) { GroupCard(group: group) }.buttonStyle(.plain) } }
                }.contentMargins(.horizontal, 20, for: .scrollContent).padding(.horizontal, -20)
                HStack { Text("Recent activity").font(.title3.bold()); Spacer(); Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary) }
                ForEach(store.recentExpenses.prefix(4)) { ExpenseRow(expense: $0) }
                AIInsightCard()
            }.padding(20).padding(.bottom, 90)
        }.background(Color.ink).toolbar(.hidden, for: .navigationBar)
    }
}

private struct BalanceCard: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("TOTAL BALANCE", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.black.opacity(0.65)); Spacer(); Text("USD").font(.caption.bold()).foregroundStyle(.black.opacity(0.55)) }
            Text(store.totalOwedToYou - store.totalYouOwe, format: .currency(code: "USD")).font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
            HStack(spacing: 22) {
                Label { VStack(alignment: .leading) { Text("You are owed").font(.caption); Text(store.totalOwedToYou, format: .currency(code: "USD")).bold() } } icon: { Image(systemName: "arrow.down.left").frame(width: 32, height: 32).background(.black.opacity(0.1), in: Circle()) }
                Divider().frame(height: 35)
                Label { VStack(alignment: .leading) { Text("You owe").font(.caption); Text(store.totalYouOwe, format: .currency(code: "USD")).bold() } } icon: { Image(systemName: "arrow.up.right").frame(width: 32, height: 32).background(.black.opacity(0.1), in: Circle()) }
            }.foregroundStyle(Color.ink)
        }.padding(22).background(LinearGradient(colors: [.softMint, Color(red: 0.57, green: 0.84, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
    }
}

struct GroupCard: View {
    let group: SplitGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.emoji).font(.system(size: 30)).frame(width: 52, height: 52).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            Text(group.name).font(.headline).lineLimit(1)
            Text(group.balance >= 0 ? "you are owed" : "you owe").font(.caption).foregroundStyle(.secondary)
            Text(abs(group.balance), format: .currency(code: "USD")).font(.title3.bold()).foregroundStyle(group.balance >= 0 ? Color.softMint : Color.orange)
        }.padding(18).frame(width: 175, alignment: .leading).background(Color(hex: group.colorHex).opacity(0.14), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07)))
    }
}

struct ExpenseRow: View {
    let expense: Expense
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: expense.category.icon).font(.headline).foregroundStyle(Color.softMint).frame(width: 44, height: 44).background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) { Text(expense.title).font(.subheadline.bold()); Text(expense.note.isEmpty ? "Paid by \(expense.paidBy.name)" : expense.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(expense.amount, format: .currency(code: "USD")).font(.subheadline.bold()); Text(expense.date, style: .relative).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

private struct AIInsightCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles").foregroundStyle(Color.ink).frame(width: 38, height: 38).background(Color.softMint, in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text("A little heads-up").bold(); Text("Dining is 18% higher this month. Your Lisbon group accounts for most of the change.").font(.subheadline).foregroundStyle(.secondary) }
        }.padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct Avatar: View {
    let name: String; var size: CGFloat = 38
    var body: some View { Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(Color.ink).frame(width: size, height: size).background(Color.softMint, in: Circle()) }
}
