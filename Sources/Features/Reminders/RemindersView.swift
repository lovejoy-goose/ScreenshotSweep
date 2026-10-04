import SwiftUI
import UIKit

/// Reminders created by Connector from Katana drafts. Shows and cancels only these.
struct RemindersView: View {
    @EnvironmentObject var reminders: ReminderCoordinator
    @State private var reminderToCancel: ReminderRecord?

    var body: some View {
        List {
            Section {
                Text("Katana присылает ссылку на черновик напоминания — без текста в самой ссылке. Напоминание появляется на iPhone только после вашей кнопки «Создать напоминание». Здесь — только напоминания Connector.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if reminders.reminders.isEmpty {
                Section {
                    Text("Пока нет напоминаний. Откройте ссылку на напоминание в Katana.").foregroundStyle(.secondary)
                }
            } else {
                Section("Напоминания") {
                    ForEach(reminders.reminders) { record in
                        ReminderRow(record: record) { reminderToCancel = record }
                    }
                }
            }
            if let issue = reminders.storageIssue {
                Text(issue == .quarantined
                     ? "Файл напоминаний был повреждён: он сохранён для диагностики, список начат заново. Уже созданные уведомления iOS не удалены."
                     : "Не удалось сохранить список напоминаний на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Локальные напоминания")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reminders.retryPendingEvents() }
        .confirmationDialog("Отменить напоминание?", isPresented: Binding(get: { reminderToCancel != nil },
                                                                         set: { if !$0 { reminderToCancel = nil } }),
                            titleVisibility: .visible, presenting: reminderToCancel) { record in
            Button("Отменить напоминание", role: .destructive) {
                Task { await reminders.cancelReminder(record.draftID) }
            }
            Button("Не отменять", role: .cancel) {}
        } message: { record in
            Text("Уведомление «\(record.title)» не появится. Katana узнает только, что оно отменено.")
        }
    }
}

private struct ReminderRow: View {
    @EnvironmentObject var reminders: ReminderCoordinator
    let record: ReminderRecord
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title).font(.subheadline.bold())
            if let text = record.body {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(record.fireAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if let eventID = latestSavedEventID {
                EventDeliveryStatusLabel(eventID: eventID)
            }
            if record.status == .scheduled, !record.isDue(at: Date()) {
                Button("Отменить", role: .destructive, action: onCancel)
                    .font(.footnote)
                    .disabled(reminders.cancelling.contains(record.draftID))
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch record.status {
        case .cancelled: return "Отменено"
        case .scheduled: return record.isDue(at: Date()) ? "Время наступило" : "Запланировано"
        }
    }

    private var latestSavedEventID: UUID? {
        if record.status == .cancelled, record.cancelledEventSaved { return record.cancelledEventID }
        return record.scheduledEventSaved ? record.scheduledEventID : nil
    }
}

/// Screen of one Katana reminder draft. Opening it (also by a link) loads nothing: the draft is
/// fetched by «Загрузить напоминание», the notification is created by «Создать напоминание».
struct ReminderDraftView: View {
    let draftID: UUID
    @EnvironmentObject var reminders: ReminderCoordinator

    var body: some View {
        List {
            switch reminders.phase(for: draftID) {
            case .idle:
                Section {
                    Text("Katana предлагает создать напоминание на этом iPhone. Текст не передаётся в ссылке — его можно загрузить из Katana по защищённому соединению.")
                        .font(.footnote)
                    Button("Загрузить напоминание") { Task { await reminders.loadDraft(draftID) } }
                }
            case .loading, .scheduling:
                Section { ProgressView() }
            case .loaded:
                draftSection
                Section {
                    Button("Создать напоминание") { Task { await reminders.createReminder(draftID) } }
                    Text("Разрешение на уведомления будет запрошено только после нажатия, если его ещё нет. В Katana уйдёт только факт создания — без текста.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .scheduled:
                if let record = reminders.record(for: draftID) {
                    Section("Напоминание создано") {
                        Text(record.title).font(.headline)
                        LabeledContent("Когда", value: record.fireAt.formatted(date: .abbreviated, time: .shortened))
                        Text(record.status == .cancelled ? "Отменено" : "Запланировано").font(.footnote)
                        Text("Повторное открытие ссылки не создаёт второе напоминание.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let failure):
                if reminders.drafts[draftID] != nil { draftSection }
                Section {
                    Text(Self.text(failure)).font(.footnote).foregroundStyle(.orange)
                    retryButton(for: failure)
                }
            }
        }
        .navigationTitle("Напоминание из Katana")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var draftSection: some View {
        if let draft = reminders.drafts[draftID] {
            Section("Черновик из Katana") {
                Text(draft.title).font(.headline)
                if let body = draft.body { Text(body).font(.subheadline) }
                LabeledContent("Когда", value: draft.fireAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder
    private func retryButton(for failure: ReminderCoordinator.Failure) -> some View {
        switch failure {
        case .unavailable, .invalidResponse:
            Button("Повторить") { Task { await reminders.loadDraft(draftID) } }
        case .permissionDenied:
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Создать напоминание") { Task { await reminders.createReminder(draftID) } }
        case .scheduleFailed, .storage:
            Button("Создать напоминание") { Task { await reminders.createReminder(draftID) } }
        case .notPaired, .requiresRepair, .notFound, .expired, .consumed, .alreadyDue:
            EmptyView()
        }
    }

    private static func text(_ failure: ReminderCoordinator.Failure) -> String {
        switch failure {
        case .notPaired: return "Katana не подключена. Подключите Katana и откройте ссылку снова."
        case .requiresRepair: return "Требуется повторное подключение к Katana. Подключите Katana заново."
        case .notFound: return "Напоминание не найдено."
        case .expired: return "Срок действия ссылки истёк."
        case .consumed: return "Это напоминание уже использовано."
        case .alreadyDue: return "Время напоминания уже наступило."
        case .unavailable: return "Нет соединения с Katana. Ничего не создано — можно повторить."
        case .invalidResponse: return "Katana ответила неожиданно. Ничего не создано."
        case .permissionDenied: return "Уведомления для Katana Connector запрещены. Разрешите их в Настройках и повторите."
        case .scheduleFailed: return "Не удалось создать уведомление. Попробуйте ещё раз."
        case .storage: return "Не удалось сохранить напоминание на iPhone. Уведомление не создано."
        }
    }
}
