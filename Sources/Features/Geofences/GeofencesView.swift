import SwiftUI
import UIKit

/// Local geofences (D-049). Location only by «Определить текущее место»; «Всегда» only after the
/// confirmed «Зарегистрировать геозону». Shows what iOS actually monitors.
struct GeofencesView: View {
    @EnvironmentObject var geofences: GeofenceCoordinator
    @State private var confirmingRegister = false
    @State private var geofenceToRemove: GeofenceRecord?

    var body: some View {
        List {
            Section {
                Text("Геозона срабатывает при входе и выходе, даже когда приложение закрыто, — для этого iOS нужно разрешение геолокации «Всегда». Katana получает только «вход» или «выход» и время, без координат. Маршруты и перемещения не отслеживаются.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            createSection
            Section {
                if geofences.geofences.isEmpty {
                    Text("Геозон пока нет.").foregroundStyle(.secondary)
                }
                ForEach(geofences.geofences) { record in
                    row(record)
                }
            } header: {
                Text("Геозоны · \(geofences.geofences.filter(\.enabled).count) из \(GeofenceRules.maxGeofences)")
            }
            if let issue = geofences.storageIssue {
                Text(issue == .quarantined
                     ? "Файл геозон был повреждён: он сохранён для диагностики, список начат заново."
                     : "Не удалось сохранить геозоны на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Геозоны")
        .navigationBarTitleDisplayMode(.inline)
        .task { await geofences.reconcile() }
        .onDisappear { geofences.cancelDraft() }
        .confirmationDialog("Зарегистрировать геозону?", isPresented: $confirmingRegister, titleVisibility: .visible) {
            Button("Зарегистрировать") { Task { await geofences.registerDraft() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Если нужно, iOS спросит разрешение геолокации «Всегда». Центр (до 4 знаков) и радиус уйдут в Katana; название останется на iPhone. Дальше Katana будет получать вход и выход без координат.")
        }
        .confirmationDialog("Удалить геозону?",
                            isPresented: Binding(get: { geofenceToRemove != nil }, set: { if !$0 { geofenceToRemove = nil } }),
                            titleVisibility: .visible, presenting: geofenceToRemove) { record in
            Button("Удалить", role: .destructive) { Task { await geofences.remove(geofenceID: record.geofenceID) } }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Регион будет снят в iOS, координаты удалены с iPhone. Katana узнает об удалении.")
        }
    }

    @ViewBuilder
    private var createSection: some View {
        Section("Новая геозона") {
            switch geofences.phase {
            case .idle, .created:
                if case .created = geofences.phase {
                    Label("Геозона зарегистрирована.", systemImage: "checkmark.circle").font(.footnote)
                }
                Button("Определить текущее место") { Task { await geofences.locate() } }
            case .locating, .registering:
                ProgressView()
            case .preview:
                previewRows
            case .failed(let failure):
                Text(GeofenceText.failure(failure)).font(.footnote).foregroundStyle(.orange)
                if failure == .alwaysRequired || failure == .permissionDenied || failure == .servicesDisabled {
                    Button("Открыть Настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                if geofences.draft != nil {
                    previewRows
                } else {
                    Button("Определить текущее место") { Task { await geofences.locate() } }
                }
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var previewRows: some View {
        if let draft = geofences.draft {
            LabeledContent("Центр", value: "\(draft.latitude), \(draft.longitude)")
                .font(.footnote.monospacedDigit())
            LabeledContent("Точность", value: CheckInText.title(draft.accuracyBucket))
            TextField("Название (только на iPhone)", text: $geofences.draftName)
            Picker("Радиус", selection: $geofences.draftRadius) {
                ForEach(GeofenceRules.allowedRadii, id: \.self) { Text("\($0) м").tag($0) }
            }
            Button("Зарегистрировать геозону") { confirmingRegister = true }
            Button("Отмена", role: .cancel) { geofences.cancelDraft() }
        }
    }

    @ViewBuilder
    private func row(_ record: GeofenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.name).font(.subheadline.bold())
            Text("\(record.radiusMeters) м · \(record.origin == .actionDraft ? "из Katana" : "создана на iPhone")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(GeofenceText.state(geofences.systemStates[record.geofenceID] ?? (record.enabled ? .notRegistered : .disabled)))
                .font(.caption)
            if let failure = geofences.recordFailures[record.geofenceID] {
                Text(GeofenceText.failure(failure)).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Включена", isOn: Binding(get: { record.enabled },
                                             set: { value in Task { await geofences.setEnabled(value, geofenceID: record.geofenceID) } }))
                .font(.footnote)
            Button("Удалить", role: .destructive) { geofenceToRemove = record }.font(.footnote)
        }
        .padding(.vertical, 2)
    }
}

enum GeofenceText {
    static func state(_ state: GeofenceSystemState) -> String {
        switch state {
        case .active: return "iOS отслеживает вход и выход"
        case .disabled: return "Выключена"
        case .notRegistered: return "Не зарегистрирована в iOS"
        case .noAlwaysPermission: return "Не работает: нет разрешения «Всегда»"
        }
    }

    static func failure(_ failure: GeofenceCoordinator.Failure) -> String {
        switch failure {
        case .servicesDisabled: return "Службы геолокации выключены."
        case .permissionDenied: return "Доступ к геолокации запрещён."
        case .permissionRestricted: return "Доступ к геолокации ограничен на этом устройстве."
        case .alwaysRequired: return "Нужно разрешение геолокации «Всегда» (Настройки → Katana Connector → Геопозиция). Геозона не создана."
        case .monitoringUnavailable: return "Это устройство не поддерживает геозоны."
        case .limitReached: return "Достигнут лимит iOS — \(GeofenceRules.maxGeofences) геозон. Выключите или удалите одну."
        case .invalidName: return "Введите название до \(GeofenceRules.maxNameScalars) символов."
        case .timedOut: return "Место не определилось вовремя."
        case .systemError: return "Не удалось. Попробуйте ещё раз."
        case .storage: return "Не удалось сохранить геозону на iPhone. Ничего не зарегистрировано."
        }
    }
}
