import SwiftUI

@main
struct KatanaConnectorApp: App {
    // Creating the store does not touch photo authorization; access is requested
    // only when Screenshot Cleanup is opened (see `ScreenshotCleanupView`).
    @StateObject private var sweepStore = SweepStore()
    // Reads saved pairing credentials from Keychain (no permission prompt, no network).
    @StateObject private var pairingCoordinator = PairingCoordinator(client: URLSessionPairingClient(),
                                                                     store: KeychainTokenStore())
    private let capabilityRegistry = CapabilityRegistry()

    var body: some Scene {
        WindowGroup {
            RootView(capabilityRegistry: capabilityRegistry)
                .environmentObject(sweepStore)
                .environmentObject(pairingCoordinator)
        }
    }
}
