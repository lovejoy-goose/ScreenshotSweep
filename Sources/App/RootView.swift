import SwiftUI

enum AppRoute: Hashable {
    case screenshotCleanup
    case pairing
}

struct RootView: View {
    let capabilityRegistry: CapabilityRegistry
    @EnvironmentObject var pairing: PairingCoordinator
    @EnvironmentObject var delivery: EventDeliveryCoordinator

    var body: some View {
        navigation
            .onChange(of: pairing.status) { status in
                if case .connected = status { delivery.pairingDidConnect() }
            }
    }

    private var navigation: some View {
        NavigationStack {
            DashboardView(registry: capabilityRegistry)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .screenshotCleanup:
                        ScreenshotCleanupView()
                    case .pairing:
                        PairingView()
                    }
                }
        }
    }
}
