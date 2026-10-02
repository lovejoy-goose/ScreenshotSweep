import SwiftUI

/// Start screen. Requests no system permissions and makes no network calls.
struct DashboardView: View {
    let registry: CapabilityRegistry
    @EnvironmentObject var pairing: PairingCoordinator
    @State private var confirmingDisconnect = false

    private static let highlighted: [CapabilityID] = [
        .photos, .currentLocation, .motion, .localNotifications, .backgroundLocation, .healthKit,
    ]

    var body: some View {
        List {
            Section("Подключение") {
                if case .connected(let device) = pairing.status {
                    ConnectionRow(icon: "link", title: "Katana подключена",
                                  subtitle: "\(device.host) · \(device.displayName)")
                    LabeledContent("Подключено", value: device.pairedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                    Button("Отключить на этом iPhone", role: .destructive) { confirmingDisconnect = true }
                } else {
                    ConnectionRow(icon: "link.badge.plus", title: "Katana не подключена",
                                  subtitle: pairing.notice == .credentialsUnavailable
                                      ? "Сохранённое подключение недоступно (например, после переустановки). Подключите Katana заново."
                                      : "Подключите этот iPhone к Katana по QR-коду.")
                    NavigationLink(value: AppRoute.pairing) {
                        Label("Подключить Katana", systemImage: "qrcode.viewfinder")
                    }
                }
                if pairing.notice == .disconnectFailed {
                    Text("Не удалось удалить данные подключения. Попробуйте ещё раз.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Функции") {
                NavigationLink(value: AppRoute.screenshotCleanup) {
                    Label("Разобрать скриншоты", systemImage: "photo.on.rectangle.angled")
                }
            }

            Section("Возможности устройства") {
                ForEach(Self.highlighted, id: \.self) { id in
                    LabeledContent(registry.descriptor(for: id).title,
                                   value: Self.statusText(registry.snapshot(for: id)))
                }
            }
            .font(.footnote)

            Section("Техническое") {
                LabeledContent("Connector Core", value: "models + pairing")
                LabeledContent("Capability Lab", value: "planned")
            }
            .font(.footnote)
        }
        .navigationTitle("Katana Connector")
        .confirmationDialog("Отключить Katana на этом iPhone?", isPresented: $confirmingDisconnect,
                            titleVisibility: .visible) {
            Button("Отключить", role: .destructive) { pairing.disconnectLocally() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Данные подключения будут удалены только с этого iPhone. Katana пока не получает уведомления об отключении — при необходимости удалите устройство в Katana вручную.")
        }
    }

    private static func statusText(_ snapshot: CapabilitySnapshot) -> String {
        switch snapshot.availability {
        case .planned: return "planned"
        case .missingEntitlement: return "missing entitlement"
        case .unsupportedDevice: return "unsupported"
        case .available:
            switch snapshot.probeState {
            case .notRun: return "untested"
            case .passed: return "passed"
            case .failed: return "failed"
            }
        }
    }
}

private struct ConnectionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
