import SwiftUI
import UIKit

/// Location Check-in. Location is touched only by «Определить текущее место»; coordinates go
/// to Katana only after the preview, a precision choice and a separate confirmation.
struct LocationCheckInView: View {
    @EnvironmentObject var checkIn: LocationCheckInCoordinator
    @State private var confirmingSend = false

    var body: some View {
        List {
            Section {
                Label("Координаты — чувствительные данные. Они будут отправлены в Katana только после предпросмотра и вашего подтверждения.",
                      systemImage: "location.circle")
                    .font(.footnote)
                Text("Только «При использовании», одно определение места по кнопке. Connector не отслеживает перемещения и не использует геолокацию в фоне.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            actionSection
            if !checkIn.history.isEmpty {
                Section("История") {
                    ForEach(checkIn.history) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            Text("\(CheckInText.title(entry.precision)) · \(CheckInText.title(entry.accuracyBucket))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            EventDeliveryStatusLabel(eventID: entry.eventID)
                        }
                    }
                }
            }
            if let issue = checkIn.storageIssue {
                Text(issue == .quarantined
                     ? "Файл истории был повреждён: он сохранён для диагностики, история начата заново."
                     : "Не удалось сохранить историю на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Location Check-in")
        .navigationBarTitleDisplayMode(.inline)
        // An unconfirmed fix is not kept once the screen is left.
        .onDisappear { checkIn.discardPreview() }
        .confirmationDialog("Отправить координаты в Katana?", isPresented: $confirmingSend, titleVisibility: .visible) {
            Button("Отправить") { Task { await checkIn.send() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("Текущее место") {
            switch checkIn.phase {
            case .idle:
                locateButton
            case .locating, .sending:
                ProgressView()
            case .preview:
                previewRows
            case .saved:
                Label("Отметка сохранена для Katana. Координаты удалены с экрана.", systemImage: "checkmark.circle")
                    .font(.footnote)
                if case .saved(let entry) = checkIn.phase { EventDeliveryStatusLabel(eventID: entry.eventID) }
                locateButton
            case .failed(let failure):
                FailureRow(failure: failure)
                if checkIn.preview != nil {
                    previewRows
                } else {
                    locateButton
                }
            }
        }
        .font(.subheadline)
    }

    private var locateButton: some View {
        Button("Определить текущее место") { Task { await checkIn.locate() } }
    }

    @ViewBuilder
    private var previewRows: some View {
        if let preview = checkIn.preview {
            LabeledContent("Время", value: preview.occurredAt.formatted(date: .omitted, time: .standard))
            LabeledContent("Точность", value: CheckInText.title(preview.accuracyBucket))
            Picker("Что отправить", selection: $checkIn.precision) {
                Text("Приблизительно").tag(CheckInPrecision.approximate)
                Text("Точно").tag(CheckInPrecision.precise)
            }
            .pickerStyle(.segmented)
            let coordinates = preview.coordinates(checkIn.precision)
            LabeledContent("Будет отправлено",
                           value: "\(CheckInText.format(coordinates.latitude)), \(CheckInText.format(coordinates.longitude))")
                .font(.footnote.monospacedDigit())
            Text(checkIn.precision == .approximate
                 ? "Координаты округлены до ≈1 км."
                 : "Точные координаты (до 6 знаков после запятой).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Определить название места в Katana", isOn: $checkIn.labelRequested)
            Button("Отправить в Katana") { confirmingSend = true }
            Button("Отмена", role: .cancel) { checkIn.cancel() }
        }
    }

    private var confirmationText: String {
        let what = checkIn.precision == .approximate ? "приблизительные координаты (≈1 км)" : "точные координаты"
        return "В Katana будут отправлены \(what), время и точность. Высота, скорость и другие данные не отправляются."
    }
}

private struct FailureRow: View {
    let failure: LocationCheckInCoordinator.Failure

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.orange)
        if failure == .permissionDenied || failure == .servicesDisabled {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var text: String {
        switch failure {
        case .servicesDisabled: return "Службы геолокации выключены. Их можно включить в Настройках → Конфиденциальность."
        case .permissionDenied: return "Доступ к геолокации запрещён. Его можно разрешить в Настройках («При использовании»)."
        case .permissionRestricted: return "Доступ к геолокации ограничен на этом устройстве."
        case .timedOut: return "Место не определилось вовремя. Попробуйте ещё раз."
        case .systemError: return "Не удалось определить место. Попробуйте ещё раз."
        case .previewExpired: return "Предпросмотр устарел, координаты удалены. Определите место заново."
        case .notPaired: return "Katana не подключена — отметка не отправлена. Подключите Katana и повторите."
        case .saveFailed: return "Не удалось сохранить отметку для Katana. Попробуйте ещё раз."
        }
    }
}

enum CheckInText {
    static func title(_ precision: CheckInPrecision) -> String {
        precision == .approximate ? "Приблизительно" : "Точно"
    }

    static func title(_ bucket: HorizontalAccuracyBucket) -> String {
        switch bucket {
        case .under25m: return "до 25 м"
        case .under100m: return "до 100 м"
        case .under1km: return "до 1 км"
        case .over1km: return "больше 1 км"
        case .unknown: return "неизвестна"
        }
    }

    static func format(_ value: Double) -> String {
        String(value)
    }
}
