import SwiftUI

struct RootView: View {
    let capabilityRegistry: CapabilityRegistry
    @EnvironmentObject var pairing: PairingCoordinator
    @EnvironmentObject var delivery: EventDeliveryCoordinator
    @StateObject private var navigator = AppNavigator()

    var body: some View {
        navigation
            .onChange(of: pairing.status) { status in
                if case .connected = status { delivery.pairingDidConnect() }
            }
            // Cold and warm start: SwiftUI delivers `katana-connector://open?…` here once the
            // window exists. Only navigation changes; invalid links are ignored.
            .onOpenURL { url in navigator.handle(url) }
    }

    private var navigation: some View {
        NavigationStack(path: $navigator.path) {
            DashboardView(registry: capabilityRegistry)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .screenshotCleanup:
                        ScreenshotCleanupView()
                    case .pairing:
                        PairingView()
                    case .capabilityLab:
                        CapabilityLabView()
                    case .activityJournal:
                        ActivityJournalView()
                    case .locationCheckIn:
                        LocationCheckInView()
                    case .reminders:
                        RemindersView()
                    case .reminderDraft(let id):
                        ReminderDraftView(draftID: id)
                    }
                }
        }
    }
}
