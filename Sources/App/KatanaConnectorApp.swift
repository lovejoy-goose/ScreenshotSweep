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
    @StateObject private var capabilityLab: CapabilityLabCoordinator
    // Motion is touched only by the buttons inside Activity Journal.
    @StateObject private var activityJournal: ActivityJournalCoordinator
    private let capabilityRegistry: CapabilityRegistry

    init() {
        let tokenStore = KeychainTokenStore()
        // Probes only touch the system when the user taps a probe button in Capability Lab.
        let lab = CapabilityLabCoordinator(store: .applicationSupport(), probes: [
            CameraProbe(system: SystemCameraAccess()),
            CurrentLocationProbe(system: SystemLocationAccess()),
            MotionProbe(system: SystemMotionAccess()),
            LocalNotificationsProbe(system: SystemNotificationAccess()),
        ])
        // The registry reads the same snapshot store, so reports and Dashboard see probe results.
        let registry = lab.registry
        let pairing = PairingCoordinator(client: URLSessionPairingClient(), store: tokenStore)
        let delivery = EventDeliveryCoordinator(api: URLSessionConnectorAPIClient(store: tokenStore),
                                                queue: EventQueue(store: .applicationSupport()),
                                                registry: registry,
                                                syncState: UserDefaultsSyncStateStore())
        delivery.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        let session = CleanupSessionRecorder(sink: delivery)
        // Saved locally first; then a capability report if Katana is connected.
        lab.onSnapshotsChanged = { [weak delivery] in
            Task { await delivery?.reportCapabilities() }
        }

        let journal = ActivityJournalCoordinator(store: ActivityJournalFile.applicationSupportStore(),
                                                 system: SystemActivityAccess(), sink: delivery)

        capabilityRegistry = registry
        _sweepStore = StateObject(wrappedValue: SweepStore(session: session))
        _cleanupSession = StateObject(wrappedValue: session)
        _pairingCoordinator = StateObject(wrappedValue: pairing)
        _deliveryCoordinator = StateObject(wrappedValue: delivery)
        _capabilityLab = StateObject(wrappedValue: lab)
        _activityJournal = StateObject(wrappedValue: journal)
    }

    var body: some Scene {
        WindowGroup {
            RootView(capabilityRegistry: capabilityRegistry)
                .environmentObject(sweepStore)
                .environmentObject(pairingCoordinator)
                .environmentObject(deliveryCoordinator)
                .environmentObject(cleanupSession)
                .environmentObject(capabilityLab)
                .environmentObject(activityJournal)
                .task {
                    // Status read only: no prompts, no probes.
                    await capabilityLab.refreshAuthorizations()
                    await deliveryCoordinator.prepare()
                    deliveryCoordinator.appBecameActive()
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                deliveryCoordinator.appBecameActive()
                Task { await capabilityLab.refreshAuthorizations() }
                Task { await activityJournal.appDidBecomeActive() }
            case .background:
                // iOS does not let the app observe in the background; the session says so honestly.
                Task { await activityJournal.appDidEnterBackground() }
            default:
                break
            }
        }
    }
}
