import SwiftUI

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                SignInView()
            case .needsProfile:
                ProfileSetupView()
            case .ready:
                MainView()
            }
        }
        .animation(.default, value: app.phase)
        .overlay {
            if let rain = app.eggs.rain {
                EmojiRain(emojis: rain.emojis) { app.eggs.clearRain() }.id(rain.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            if app.phase == .ready { app.eggs.shook() }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast) { app.toast = nil }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.undo == nil ? 2.5 : 5))
                        if app.toast?.id == toast.id { app.toast = nil }
                    }
            }
        }
        .alert(app.presentedError?.title ?? "", isPresented: Binding(get: { app.presentedError != nil }, set: { if !$0 { app.presentedError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.presentedError?.message ?? "")
        }
    }
}

@MainActor
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppMark(size: 120)
            ProgressView().accessibilityLabel(Text("Loading"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
    }
}

/// The app icon (rounded), used on the launch screen and sign-in.
@MainActor
struct AppMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("LaunchIcon")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

@MainActor
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store

    private let trip = CrewMember.tripID

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            NavigationStack(path: $app.path) {
                CrewHomeView().withRoutes()
            }
            .tabItem { Label("Money", systemImage: "dollarsign.circle.fill") }
            .tag(AppTab.money)

            NavigationStack { ChatView(tripID: trip).withRoutes() }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(app.env.chat.unreadCount(for: trip))
                .tag(AppTab.chat)

            NavigationStack { TripPhotosView(tripID: trip).withRoutes() }
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                .tag(AppTab.photos)

            NavigationStack { TripGuideView(guide: .puertoRico).withRoutes() }
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(AppTab.plan)

            NavigationStack { CrewMapView(tripID: trip).withRoutes() }
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(AppTab.map)
        }
        .task(id: app.profile?.displayName) { app.startNearby() }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .addExpense(let trip): ExpenseEditorView(tripID: trip, editing: nil)
            case .scanReceipt(let trip): ScanReceiptView(initialTripID: trip)
            case .reviewScan(let trip, let job): ScanReceiptView(initialTripID: trip, initialJobID: job)
            case .settleUp(let trip, let transfer): SettleUpView(tripID: trip, suggestion: transfer)
            }
        }
    }
}

extension View {
    /// Shared navigation destinations for every tab's stack.
    @MainActor func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .trip(let id): TripDetailView(tripID: id)
            case .expense(let trip, let expense): ExpenseDetailView(tripID: trip, expenseID: expense)
            case .balances(let id): BalancesView(tripID: id)
            case .tripSettings(let id): TripSettingsView(tripID: id)
            case .activity(let id): ActivityView(tripID: id)
            case .receipts(let id): ReceiptsView(tripID: id)
            case .chat(let id): ChatView(tripID: id)
            case .photos(let id): TripPhotosView(tripID: id)
            case .map(let id): CrewMapView(tripID: id)
            }
        }
    }
}
