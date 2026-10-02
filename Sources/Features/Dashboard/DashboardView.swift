import SwiftUI

/// Start screen. Requests no system permissions and makes no network calls.
struct DashboardView: View {
    let registry: CapabilityRegistry

    private static let highlighted: [CapabilityID] = [
        .photos, .currentLocation, .motion, .localNotifications, .backgroundLocation, .healthKit,
    ]

    var body: some View {
        List {
            Section("Подключение") {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Katana не подключена").font(.headline)
                        Text("Подключение к Katana появится в следующих версиях.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
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
                LabeledContent("Connector Core", value: "models")
                LabeledContent("Capability Lab", value: "planned")
            }
            .font(.footnote)
        }
        .navigationTitle("Katana Connector")
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
