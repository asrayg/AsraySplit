import BackgroundTasks
import SwiftUI

@main
struct AsraySplitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        let environment = AppEnvironment.live()
        let model = AppModel(env: environment)
        _model = State(initialValue: model)
        // Overnight photo sync (Wi-Fi + charging). Must be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: TripPhotoStore.backgroundTaskID, using: nil) { task in
            Task { @MainActor in
                let work = Task { @MainActor in
                    let trips = (try? await environment.backend.trips.fetchTrips().map(\.id)) ?? []
                    await environment.photos.sync(tripIDs: Array(Set(trips + [CrewMember.tripID])))
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                environment.photos.scheduleOvernightSync()
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
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
            model.processSharedInbox()
            Task { await model.store.syncNow() }
        }
    }
}
