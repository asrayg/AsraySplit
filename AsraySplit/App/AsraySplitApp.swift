import SwiftUI

@main
struct AsraySplitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        let environment = AppEnvironment.live()
        _model = State(initialValue: AppModel(env: environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.store)
                .environment(model.env.scanner)
                .tint(.brand)
                .onAppear {
                    appDelegate.onToken = { [weak model] token in Task { @MainActor in model?.env.notifications.didRegister(token: token) } }
                    model.start()
                }
                .onOpenURL { model.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, model.phase == .ready else { return }
            Task { await model.store.syncNow() }
        }
    }
}
