import SwiftUI

/// Screen of one Katana action draft (D-047). Opening it — also by a link — loads nothing:
/// «Загрузить действие» fetches it, «Выполнить» runs it once after a confirmation.
struct ActionDraftView: View {
    let draftID: UUID
    @EnvironmentObject var drafts: ActionDraftCoordinator
    @State private var confirming = false

    var body: some View {
        List {
            switch drafts.phase(for: draftID) {
            case .idle:
                Section {
                    Text("Katana предлагает действие на этом iPhone. Ссылка не содержит команд и текста — посмотрите, что предлагается, загрузив его из Katana по защищённому соединению.")
                        .font(.footnote)
                    Button("Загрузить действие") { Task { await drafts.loadDraft(draftID) } }
                }
            case .loading, .performing:
                Section { ProgressView() }
            case .loaded:
                previewSection
                Section {
                    Button("Выполнить") { confirming = true }
                    Text("Ничего не произойдёт без этой кнопки. Выполнить действие можно только один раз.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .continuing:
                previewSection
                Section {
                    Label("Действие будет выполнено после отправки на экране «Поделиться с Katana».",
                          systemImage: "arrow.forward.circle")
                        .font(.footnote)
                    NavigationLink(value: AppRoute.capture) {
                        Text("Открыть «Поделиться с Katana»")
                    }
                }
            case .accepted:
                Section {
                    Label("Действие выполнено. Повторно выполнить его нельзя.", systemImage: "checkmark.circle")
                    if let record = drafts.acceptedRecord(for: draftID) {
                        EventDeliveryStatusLabel(eventID: record.eventID)
                    }
                }
            case .failed(let failure):
                if drafts.drafts[draftID] != nil { previewSection }
                Section {
                    Text(Self.text(failure)).font(.footnote).foregroundStyle(.orange)
                    switch failure {
                    case .unavailable, .invalidResponse:
                        Button("Повторить") { Task { await drafts.loadDraft(draftID) } }
                    case .notPerformed, .storage:
                        Button("Выполнить ещё раз") { confirming = true }
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .navigationTitle("Действие из Katana")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Выполнить действие?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Выполнить") { Task { await drafts.perform(draftID) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let draft = drafts.drafts[draftID] {
            Section(ActionDraftText.title(draft.kind)) {
                switch draft.payload {
                case .nfcAction(let payload):
                    LabeledContent("Действие", value: payload.label)
                    Text("Действие будет добавлено в «NFC-действия». Его можно запустить меткой через Команды; каждый запуск требует подтверждения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .geofenceCreate(let payload):
                    LabeledContent("Название", value: payload.nameSuggestion)
                    LabeledContent("Радиус", value: "\(payload.radiusMeters) м")
                    LabeledContent("Центр", value: "\(payload.latitude), \(payload.longitude)")
                        .font(.footnote.monospacedDigit())
                    Text("Нужно разрешение геолокации «Всегда». При входе и выходе Katana получит только сам факт и время — без координат.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .sharedCapture(let payload):
                    Text(payload.prompt).font(.subheadline)
                    LabeledContent("Можно отправить", value: payload.acceptedKinds.map(CaptureText.title).joined(separator: ", "))
                    Text("Откроется экран «Поделиться с Katana»; ничего не отправится без вашего подтверждения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var confirmationText: String {
        switch drafts.drafts[draftID]?.kind {
        case .nfcAction?: return "NFC-действие будет добавлено на этот iPhone."
        case .geofenceCreate?: return "Геозона будет зарегистрирована, её координаты отправятся в Katana."
        case .sharedCapture?: return "Откроется выбор того, чем поделиться."
        case nil: return ""
        }
    }

    private static func text(_ failure: ActionDraftCoordinator.Failure) -> String {
        switch failure {
        case .notPaired: return "Katana не подключена. Подключите Katana и откройте ссылку снова."
        case .requiresRepair: return "Требуется повторное подключение к Katana."
        case .notFound: return "Действие не найдено."
        case .expired: return "Срок действия истёк."
        case .consumed: return "Действие уже выполнено."
        case .unavailable: return "Нет соединения с Katana. Ничего не выполнено — можно повторить."
        case .invalidResponse: return "Katana ответила неожиданно. Ничего не выполнено."
        case .unsupported: return "Эта сборка Connector не умеет выполнять такое действие."
        case .notPerformed: return "Действие не выполнено. Подробности — на экране функции."
        case .storage: return "Не удалось сохранить результат на iPhone."
        }
    }
}

enum ActionDraftText {
    static func title(_ kind: ActionDraftKind) -> String {
        switch kind {
        case .nfcAction: return "NFC-действие"
        case .geofenceCreate: return "Геозона"
        case .sharedCapture: return "Поделиться с Katana"
        }
    }
}

enum CaptureText {
    static func title(_ kind: CaptureKind) -> String {
        switch kind {
        case .text: return "текст"
        case .url: return "ссылка"
        case .image: return "изображение"
        case .pdf: return "PDF"
        case .file: return "текстовый файл"
        }
    }
}
