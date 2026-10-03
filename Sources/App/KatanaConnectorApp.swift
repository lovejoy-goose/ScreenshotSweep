import SwiftUI

@main
struct KatanaConnectorApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Creating the store does not touch photo authorization; access is requested
    // only when Screenshot Cleanup is opened (see `ScreenshotCleanupView`).
    @StateObject private var sweepStore: SweepStore
    @StateObject private var cleanupSession: CleanupSessionRecorder
    // Reads saved pairing credentials from Keychain (no permission prompt, no network).
    @StateObject private var pairingCoordinator: PairingCoordinator
    @StateObject private var deliveryCoordinator: EventDeliveryCoordinator
    private let capabilityRegistry: CapabilityRegistry

    init() {
        let tokenStore = KeychainTokenStore()
        let registry = CapabilityRegistry()
        let pairing = PairingCoordinator(client: URLSessionPairingClient(), store: tokenStore)
        let delivery = EventDeliveryCoordinator(api: URLSessionConnectorAPIClient(store: tokenStore),
                                                queue: EventQueue(store: .applicationSupport()),
                                                registry: registry,
                                                syncState: UserDefaultsSyncStateStore())
        delivery.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        let session = CleanupSessionRecorder(sink: delivery)

        capabilityRegistry = registry
        _sweepStore = StateObject(wrappedValue: SweepStore(session: session))
        _cleanupSession = StateObject(wrappedValue: session)
        _pairingCoordinator = StateObject(wrappedValue: pairing)
        _deliveryCoordinator = StateObject(wrappedValue: delivery)
    }

    var body: some Scene {
        WindowGroup {
            RootView(capabilityRegistry: capabilityRegistry)
                .environmentObject(sweepStore)
                .environmentObject(pairingCoordinator)
                .environmentObject(deliveryCoordinator)
                .environmentObject(cleanupSession)
                .task {
                    await deliveryCoordinator.prepare()
                    deliveryCoordinator.appBecameActive()
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { deliveryCoordinator.appBecameActive() }
        }
    }
}
