import SwiftUI

enum AppRoute: Hashable {
    case screenshotCleanup
}

struct RootView: View {
    let capabilityRegistry: CapabilityRegistry

    var body: some View {
        NavigationStack {
            DashboardView(registry: capabilityRegistry)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .screenshotCleanup:
                        ScreenshotCleanupView()
                    }
                }
        }
    }
}
