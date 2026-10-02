import SwiftUI

enum AppRoute: Hashable {
    case screenshotCleanup
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            DashboardView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .screenshotCleanup:
                        ScreenshotCleanupView()
                    }
                }
        }
    }
}
