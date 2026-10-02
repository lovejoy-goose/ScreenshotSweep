import SwiftUI

@main
struct KatanaConnectorApp: App {
    // Creating the store does not touch photo authorization; access is requested
    // only when Screenshot Cleanup is opened (see `ScreenshotCleanupView`).
    @StateObject private var sweepStore = SweepStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sweepStore)
        }
    }
}
