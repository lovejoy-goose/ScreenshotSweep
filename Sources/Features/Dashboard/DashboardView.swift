import SwiftUI

/// Start screen. Requests no system permissions and makes no network calls.
struct DashboardView: View {
    let registry: CapabilityRegistry
    @EnvironmentObject var pairing: PairingCoordinator
    @EnvironmentObject var delivery: EventDeliveryCoordinator
    // Observed only to re-render when probe results change; never starts probes from here.
    @EnvironmentObject var lab: CapabilityLabCoordinator
    @State private var confirmingDisconnect = false

    private static let highlighted: [CapabilityID] = [
        .photos, .camera, .currentLocation, .motion, .localNotifications, .backgroundLocation, .healthKit,
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
                } else if case .requiresRepair(let device) = pairing.status {
                    ConnectionRow(icon: "exclamationmark.triangle", title: "Требуется повторное подключение",
                                  subtitle: "Katana больше не принимает подключение \(device.host). Подключите Katana заново.")
                    NavigationLink(value: AppRoute.pairing) {
                        Label("Подключить Katana заново", systemImage: "qrcode.viewfinder")
                    }
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

            if showsSync {
                syncSection
            }

            Section("Функции") {
                NavigationLink(value: AppRoute.screenshotCleanup) {
                    Label("Разобрать скриншоты", systemImage: "photo.on.rectangle.angled")
                }
                NavigationLink(value: AppRoute.activityJournal) {
                    Label("Activity Journal", systemImage: "figure.walk")
                }
                NavigationLink(value: AppRoute.locationCheckIn) {
                    Label("Location Check-in", systemImage: "mappin.and.ellipse")
                }
                NavigationLink(value: AppRoute.reminders) {
                    Label("Локальные напоминания", systemImage: "bell")
                }
                NavigationLink(value: AppRoute.capabilityLab) {
                    Label("Capability Lab", systemImage: "checklist")
                }
            }

            Section("Возможности устройства") {
                ForEach(Self.highlighted, id: \.self) { id in
                    LabeledContent(registry.descriptor(for: id).title,
                                   value: Self.statusText(lab.snapshot(for: id)))
                }
            }
            .font(.footnote)

            Section("Техническое") {
                LabeledContent("Connector Core", value: "pairing + events")
                LabeledContent("Capability Lab", value: "4 probes")
                LabeledContent("Контекст и действия", value: "v0.2")
            }
            .font(.footnote)
        }
        .navigationTitle("Katana Connector")
        .confirmationDialog("Отключить Katana на этом iPhone?", isPresented: $confirmingDisconnect,
                            titleVisibility: .visible) {
            Button("Отключить", role: .destructive) { pairing.disconnectLocally() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Данные подключения будут удалены только с этого iPhone. Katana пока не получает уведомления об отключении — при необходимости удалите устройство в Katana вручную. Неотправленные события останутся на этом iPhone.")
        }
    }

    private var showsSync: Bool {
        switch pairing.status {
        case .connected, .requiresRepair: return true
        case .unpaired, .reviewing, .pairing, .failed: return false
        }
    }

    private var requiresRepair: Bool {
        if case .requiresRepair = pairing.status { return true }
        return delivery.status == .requiresRepair
    }

    private var syncSection: some View {
        Section("Синхронизация") {
            LabeledContent("Последняя синхронизация",
                           value: delivery.lastSuccessfulSync?.formatted(date: .abbreviated, time: .shortened) ?? "ещё не было")
            LabeledContent("Событий в очереди", value: "\(delivery.pendingCount)")
            if delivery.otherScopePendingCount > 0 {
                LabeledContent("Ждут решения (другое подключение)", value: "\(delivery.otherScopePendingCount)")
                Text("Эти события записаны для другого или прежнего подключения и автоматически не отправляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if delivery.rejectedCount > 0 {
                LabeledContent("Отклонено Katana", value: "\(delivery.rejectedCount)")
            }
            if let text = Self.syncStatusText(delivery.status) {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            if let check = delivery.lastCheck {
                Text(Self.checkText(check)).font(.caption)
            }
            if delivery.queueIssue == .corruptedStoreQuarantined {
                Text("Файл очереди был повреждён: он сохранён для диагностики, очередь начата заново.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await delivery.checkConnection() }
            } label: {
                if delivery.isCheckingConnection {
                    ProgressView()
                } else {
                    Text("Проверить соединение")
                }
            }
            .disabled(delivery.isCheckingConnection || requiresRepair)
            Button {
                Task { await delivery.synchronize() }
            } label: {
                if delivery.isFlushing {
                    ProgressView()
                } else {
                    Text("Синхронизировать")
                }
            }
            .disabled(delivery.isFlushing || requiresRepair)
        }
        .font(.footnote)
    }

    private static func syncStatusText(_ status: EventDeliveryCoordinator.SyncStatus) -> String? {
        switch status {
        case .idle: return nil
        case .syncing: return "Синхронизация…"
        case .waitingToRetry: return "Нет ответа от Katana, повторим автоматически."
        case .requiresRepair: return "Подключите Katana заново. События сохранены и будут отправлены после подключения."
        case .failed(let failure): return failureText(failure)
        }
    }

    private static func checkText(_ result: EventDeliveryCoordinator.ConnectionCheckResult) -> String {
        switch result {
        case .ok(_, let accountLabel):
            return accountLabel.map { "Соединение в порядке · \($0)" } ?? "Соединение в порядке"
        case .notPaired: return "Katana не подключена."
        case .requiresRepair: return "Katana отклонила подключение. Подключите Katana заново."
        case .failed(let failure): return failureText(failure)
        }
    }

    private static func failureText(_ failure: EventDeliveryCoordinator.Failure) -> String {
        switch failure {
        case .offline: return "Нет соединения с Katana."
        case .rateLimited: return "Katana просит подождать. Попробуйте позже."
        case .serverError: return "Katana временно недоступна. Попробуйте позже."
        case .rejected: return "Katana отклонила запрос."
        case .invalidResponse: return "Katana ответила неожиданно."
        case .storage: return "Не удалось прочитать или записать очередь событий."
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
