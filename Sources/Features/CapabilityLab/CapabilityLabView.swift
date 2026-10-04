import SwiftUI
import UIKit

/// Four independent manual checks. Nothing runs or asks for permission until the user taps
/// the button of that card. Shows only states — never frames, coordinates or motion data.
struct CapabilityLabView: View {
    @EnvironmentObject var lab: CapabilityLabCoordinator

    var body: some View {
        List {
            Section {
                Text("Каждая проверка запускается только своей кнопкой и запрашивает только своё разрешение. Результаты — без фото, координат и данных движения; в Katana уходит только состояние.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(CapabilityLabCoordinator.labCapabilities, id: \.self) { id in
                ProbeCard(id: id)
            }
            Section {
                Text("Физические триггеры (v0.3). «Всегда» запрашивается только кнопкой проверки; регион при проверке не создаётся.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(CapabilityLabCoordinator.triggerCapabilities, id: \.self) { id in
                ProbeCard(id: id)
            }
            Section("Недоступно в этой сборке") {
                ForEach(CapabilityLabCoordinator.gatedCapabilities, id: \.self) { id in
                    let snapshot = lab.snapshot(for: id)
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(lab.registry.descriptor(for: id).title, value: CapabilityStatusText.summary(snapshot))
                        Text(CapabilityStatusText.gatedReason(id)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.footnote)
            if lab.storageFailed {
                Text("Не удалось сохранить результат проверки на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Capability Lab")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProbeCard: View {
    @EnvironmentObject var lab: CapabilityLabCoordinator
    let id: CapabilityID

    var body: some View {
        let snapshot = lab.snapshot(for: id)
        let running = lab.isRunning(id)
        Section(lab.registry.descriptor(for: id).title) {
            Text(Self.purpose(id)).font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Доступность", value: Self.text(snapshot.availability))
            LabeledContent("Разрешение", value: Self.text(snapshot.authorization))
            LabeledContent("Результат", value: Self.text(snapshot.probeState))
            if let checkedAt = snapshot.checkedAt {
                LabeledContent("Проверено", value: checkedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let detail = snapshot.detail.flatMap(CapabilityProbeDetail.init(rawValue:)) {
                Text(Self.text(detail, for: id)).font(.footnote)
            }
            if running {
                HStack {
                    ProgressView()
                    Spacer()
                    Button("Отменить", role: .cancel) { lab.cancel(id) }
                }
            } else {
                Button(Self.buttonTitle(id)) { lab.start(id) }
                    .disabled(snapshot.availability != .available)
            }
            Text("Статус: " + CapabilityStatusText.summary(snapshot)).font(.caption).foregroundStyle(.secondary)
            // Settings only after a system denial, and only by this button.
            if snapshot.authorization == .denied || snapshot.detail == CapabilityProbeDetail.requiresSettings.rawValue, !running {
                Button("Открыть Настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private static func purpose(_ id: CapabilityID) -> String {
        switch id {
        case .camera: return "Получает один кадр с камеры и сразу его отбрасывает: ничего не сохраняется и не показывается."
        case .currentLocation: return "Получает одно определение местоположения (только «При использовании») и сразу его отбрасывает."
        case .motion: return "Получает одно событие датчиков движения и сразу его отбрасывает."
        case .localNotifications: return "Планирует одно тестовое уведомление через 5 секунд. Если приложение открыто, iOS может его не показать."
        case .locationAlways: return "Проверяет разрешение геолокации «Всегда», нужное геозонам. Если стоит «При использовании», iOS может один раз предложить «Всегда»."
        case .regionMonitoring: return "Проверяет, что устройство поддерживает геозоны и есть «Всегда». Регион не создаётся."
        default: return ""
        }
    }

    private static func buttonTitle(_ id: CapabilityID) -> String {
        switch id {
        case .camera: return "Проверить камеру"
        case .currentLocation: return "Проверить геолокацию"
        case .motion: return "Проверить датчики движения"
        case .localNotifications: return "Отправить тестовое уведомление"
        case .locationAlways: return "Проверить «Всегда»"
        case .regionMonitoring: return "Проверить геозоны"
        default: return "Проверить"
        }
    }

    private static func text(_ availability: CapabilityAvailability) -> String {
        switch availability {
        case .available: return "есть"
        case .planned: return "в планах"
        case .missingEntitlement: return "нужен entitlement"
        case .unsupportedDevice: return "не поддерживается устройством"
        }
    }

    private static func text(_ authorization: CapabilityAuthorization) -> String {
        switch authorization {
        case .unknown: return "не проверялось"
        case .notRequired: return "не требуется"
        case .notRequested: return "ещё не запрашивалось"
        case .granted: return "разрешено"
        case .limited: return "ограничено"
        case .denied: return "запрещено"
        case .restricted: return "ограничено системой"
        }
    }

    private static func text(_ state: CapabilityProbeState) -> String {
        switch state {
        case .notRun: return "не проверялось"
        case .passed: return "работает"
        case .failed: return "не удалось"
        }
    }

    private static func text(_ detail: CapabilityProbeDetail, for id: CapabilityID) -> String {
        switch detail {
        case .cameraFrameReceived: return "Камера передала кадр; кадр отброшен."
        case .locationFixReceived: return "Местоположение определено; координаты отброшены."
        case .motionSampleReceived: return "Датчики движения ответили; данные отброшены."
        case .testNotificationScheduled: return "Тестовое уведомление запланировано."
        case .permissionDenied: return "Доступ запрещён. Его можно разрешить в Настройках."
        case .permissionRestricted: return "Доступ ограничен на этом устройстве (Экранное время или профиль)."
        case .unavailable: return "На этом устройстве функция недоступна."
        case .timedOut: return "Система не ответила вовремя. Попробуйте ещё раз."
        case .cancelled: return "Проверка отменена."
        case .systemError: return "Системная ошибка. Попробуйте ещё раз."
        case .alwaysAuthorized: return "Разрешение «Всегда» есть."
        case .regionMonitoringAvailable: return "Геозоны поддерживаются и могут работать в фоне."
        case .requiresSettings: return "Нужно изменить настройку: Настройки → Katana Connector → Геопозиция → «Всегда»."
        }
    }
}

/// One label per capability: availability, authorization and probe stay separate dimensions;
/// this only names the most relevant one for the user (D-051).
enum CapabilityStatusText {
    static func summary(_ snapshot: CapabilitySnapshot) -> String {
        switch snapshot.availability {
        case .missingEntitlement: return "requires_entitlement"
        case .unsupportedDevice: return "unavailable"
        case .planned: return "unavailable"
        case .available: break
        }
        if snapshot.detail == CapabilityProbeDetail.requiresSettings.rawValue { return "requires_settings" }
        switch snapshot.probeState {
        case .passed: return "passed"
        case .failed: return snapshot.authorization == .denied ? "denied" : "failed"
        case .notRun:
            switch snapshot.authorization {
            case .denied, .restricted: return "denied"
            case .notRequested: return "not_requested"
            default: return "available"
            }
        }
    }

    static func gatedReason(_ id: CapabilityID) -> String {
        switch id {
        case .coreNFC, .coreNFCWrite: return "Нужен NFC-entitlement. Работает путь через Команды + NFC."
        case .appGroup: return "Нужен App Group entitlement для обмена с Share Extension."
        case .shareExtension: return "Собран, но не встроен до проверки App Group. Используйте «Поделиться с Katana» в приложении."
        case .backgroundLocation: return "Не используется: геозонам фоновая геолокация не нужна."
        default: return ""
        }
    }
}

