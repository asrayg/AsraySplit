import SwiftUI

@main
struct AsraySplitApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.mint)
                .preferredColorScheme(.dark)
        }
    }
}

