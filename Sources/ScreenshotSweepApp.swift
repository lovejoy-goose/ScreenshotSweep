import SwiftUI

@main
struct ScreenshotSweepApp: App {
    @StateObject private var store = SweepStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
