import AVFoundation
import SwiftUI

/// Pairing flow: explanation → camera permission (only on «Сканировать QR») → scan →
/// confirmation → code exchange. Camera access is never requested elsewhere.
struct PairingView: View {
    @EnvironmentObject var pairing: PairingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .intro

    private enum Step {
        case intro, scanning, cameraDenied, cameraUnavailable
    }

    var body: some View {
        content
            .navigationTitle("Подключение Katana")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { pairing.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch pairing.status {
        case .reviewing(let host):
            PairingConfirmationView(
                host: host,
                replacingHost: pairing.deviceToReplace?.host,
                onConfirm: { name in Task { await pairing.confirm(displayName: name) } },
                onCancel: {
                    pairing.cancel()
                    step = .intro
                }
            )
        case .pairing(let host):
            VStack(spacing: 16) {
                ProgressView()
                Text("Подключаемся к \(host)…").foregroundStyle(.secondary)
            }
        case .connected(let device):
            MessageView(
                icon: "checkmark.circle",
                title: "Katana подключена",
                text: "\(device.displayName) подключён к \(device.host).",
                buttonTitle: "Готово",
                action: { dismiss() }
            )
        case .failed(let error):
            MessageView(
                icon: "exclamationmark.triangle",
                title: "Не удалось подключиться",
                text: error.userMessage,
                buttonTitle: "Сканировать снова",
                action: {
                    pairing.cancel()
                    startScanning()
                }
            )
        case .unpaired, .requiresRepair:
            unpairedContent
        }
    }

    @ViewBuilder private var unpairedContent: some View {
        switch step {
        case .intro:
            MessageView(
                icon: "qrcode.viewfinder",
                title: "Подключить Katana",
                text: "Откройте Katana в браузере, начните подключение iPhone и отсканируйте показанный QR-код. Камера нужна только для сканирования; изображение никуда не отправляется.",
                buttonTitle: "Сканировать QR",
                action: startScanning
            )
        case .scanning:
            ZStack(alignment: .bottom) {
                QRScannerView(
                    onCode: { pairing.handleScannedCode($0) },
                    onFailure: { step = .cameraUnavailable }
                )
                .ignoresSafeArea(edges: .bottom)
                Button("Отмена") { step = .intro }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 32)
            }
        case .cameraDenied:
            MessageView(
                icon: "camera",
                title: "Нет доступа к камере",
                text: "Разрешите доступ в Настройках → Katana Connector → Камера, чтобы отсканировать QR-код.",
                buttonTitle: "Открыть Настройки",
                action: openSettings
            )
        case .cameraUnavailable:
            MessageView(
                icon: "camera",
                title: "Камера недоступна",
                text: "Не удалось запустить камеру на этом устройстве.",
                buttonTitle: "Назад",
                action: { step = .intro }
            )
        }
    }

    private func startScanning() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            step = .scanning
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                step = granted ? .scanning : .cameraDenied
            }
        default:
            step = .cameraDenied
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

extension PairingError {
    var userMessage: String {
        switch self {
        case .invalidQR:
            return "Это не QR-код подключения Katana или он повреждён. Начните подключение в Katana заново."
        case .insecureHost:
            return "Адрес Katana в QR-коде не использует HTTPS. Подключение отклонено."
        case .expiredCode:
            return "Срок действия кода истёк. Начните подключение в Katana заново."
        case .rejected:
            return "Katana отклонила код подключения. Возможно, он уже использован. Начните подключение заново."
        case .transport:
            return "Нет соединения с Katana. Проверьте интернет и попробуйте ещё раз."
        case .invalidResponse:
            return "Katana ответила неожиданно. Проверьте, что QR-код получен из актуальной версии Katana."
        case .keychainFailure:
            return "Не удалось безопасно сохранить подключение на этом iPhone. Попробуйте ещё раз."
        }
    }
}
