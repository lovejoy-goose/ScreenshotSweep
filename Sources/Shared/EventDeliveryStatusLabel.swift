import SwiftUI

/// Delivery status of an event saved for Katana: «ждёт отправки» / «отправлено» / «не принято».
/// Never shows the event ID, the scope or raw errors.
struct EventDeliveryStatusLabel: View {
    let eventID: UUID
    @EnvironmentObject var delivery: EventDeliveryCoordinator
    @State private var state: EventLocalDeliveryState = .pending

    var body: some View {
        Label(Self.text(state), systemImage: Self.icon(state))
            .font(.caption)
            .foregroundStyle(state == .rejected ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .task(id: refreshKey) {
                state = await delivery.localDeliveryState(of: eventID)
            }
    }

    /// Re-checked whenever the queue or the delivery results change.
    private var refreshKey: String {
        "\(delivery.pendingCount)-\(delivery.deliveredEventIDs.count)-\(delivery.rejectedCount)-\(delivery.isFlushing)"
    }

    static func text(_ state: EventLocalDeliveryState) -> String {
        switch state {
        case .pending: return "Сохранено, ждёт отправки в Katana"
        case .delivered: return "Отправлено в Katana"
        case .rejected: return "Katana не приняла результат"
        }
    }

    private static func icon(_ state: EventLocalDeliveryState) -> String {
        switch state {
        case .pending: return "tray.and.arrow.up"
        case .delivered: return "checkmark.icloud"
        case .rejected: return "exclamationmark.triangle"
        }
    }
}
