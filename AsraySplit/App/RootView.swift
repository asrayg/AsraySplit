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
            AppMark(size: 84)
            ProgressView().accessibilityLabel(Text("Loading"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
    }
}

/// Original brand mark: two overlapping rounded receipts.
@MainActor
struct AppMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.brand)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Color.onBrand)
                .rotationEffect(.degrees(90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(TripStore.self) private var store

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            TripsHomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .trip(let id): TripDetailView(tripID: id)
                    case .expense(let trip, let expense): ExpenseDetailView(tripID: trip, expenseID: expense)
                    case .balances(let id): BalancesView(tripID: id)
                    case .tripSettings(let id): TripSettingsView(tripID: id)
                    case .activity(let id): ActivityView(tripID: id)
                    case .receipts(let id): ReceiptsView(tripID: id)
                    }
                }
        }
        .sheet(item: $app.sheet) { sheet in
            switch sheet {
            case .join(let secret): JoinTripView(secret: secret)
            case .createTrip: TripEditorView(existing: nil)
            case .addExpense(let trip): ExpenseEditorView(tripID: trip, editing: nil)
            case .scanReceipt(let trip): ScanReceiptView(initialTripID: trip)
            case .settleUp(let trip, let transfer): SettleUpView(tripID: trip, suggestion: transfer)
            }
        }
    }
}
