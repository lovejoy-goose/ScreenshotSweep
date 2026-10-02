import SwiftUI

/// Start screen. Requests no system permissions and makes no network calls.
struct DashboardView: View {
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

            Section("Техническое") {
                LabeledContent("Connector Core", value: "planned")
                LabeledContent("Capability Lab", value: "planned")
            }
            .font(.footnote)
        }
        .navigationTitle("Katana Connector")
    }
}
