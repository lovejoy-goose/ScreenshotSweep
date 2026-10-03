import SwiftUI
import UIKit

/// Activity Journal. Motion is touched only by «Определить текущую активность» and
/// «Начать сессию»; Katana gets results only after «Отправить в Katana».
struct ActivityJournalView: View {
    @EnvironmentObject var journal: ActivityJournalCoordinator
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                Text("Connector определяет только вид активности и длительности. Сырые данные датчиков и маршрут не сохраняются и не отправляются; в Katana результат уходит только после кнопки «Отправить в Katana».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            snapshotSection
            sessionSection
            if !journal.history.isEmpty {
                Section("История") {
                    ForEach(journal.history) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            if let issue = journal.storageIssue {
                Text(issue == .quarantined
                     ? "Файл журнала был повреждён: он сохранён для диагностики, журнал начат заново."
                     : "Не удалось сохранить журнал на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Activity Journal")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить сессию без отправки?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await journal.deleteSession() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В Katana ничего не будет отправлено.")
        }
    }

    // MARK: Snapshot

    private var snapshotSection: some View {
        Section("Текущая активность") {
            if let snapshot = journal.snapshot {
                LabeledContent("Активность", value: ActivityText.title(snapshot.activity))
                LabeledContent("Уверенность", value: ActivityText.title(snapshot.confidence))
                LabeledContent("Проверено", value: snapshot.checkedAt.formatted(date: .omitted, time: .standard))
            }
            switch journal.snapshotPhase {
            case .idle:
                Button("Определить текущую активность") { Task { await journal.checkCurrentActivity() } }
            case .checking, .sending:
                ProgressView()
            case .preview:
                Button("Отправить в Katana") { Task { await journal.sendSnapshot() } }
                Button("Сбросить", role: .cancel) { journal.discardSnapshot() }
            case .saved:
                if let snapshot = journal.snapshot { EventDeliveryStatusLabel(eventID: snapshot.eventID) }
                Button("Проверить ещё раз") { Task { await journal.checkCurrentActivity() } }
            case .failed(let failure):
                FailureText(failure: failure)
                if journal.snapshot != nil, failure == .notPaired || failure == .saveFailed {
                    Button("Повторить отправку") { Task { await journal.sendSnapshot() } }
                    Button("Сбросить", role: .cancel) { journal.discardSnapshot() }
                } else {
                    Button("Определить текущую активность") { Task { await journal.checkCurrentActivity() } }
                }
            }
        }
        .font(.subheadline)
    }

    // MARK: Session

    private var sessionSection: some View {
        Section {
            if let session = journal.session {
                sessionContent(session)
            } else if journal.isStartingSession {
                ProgressView()
            } else {
                Text("Сессия считает время по видам активности, пока приложение открыто. Начало и конец — только вашими кнопками.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Начать сессию") { Task { await journal.startSession() } }
            }
            if let failure = journal.sessionFailure {
                FailureText(failure: failure)
            }
        } header: {
            Text("Сессия активности")
        } footer: {
            Text("Когда приложение свёрнуто или экран заблокирован, iOS не даёт Connector наблюдать за активностью. Это время честно учитывается как «неизвестно».")
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func sessionContent(_ session: ActivitySession) -> some View {
        LabeledContent("Начало", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
        switch session.phase {
        case .active:
            LabeledContent("Состояние", value: journal.isObserving ? "идёт наблюдение" : "наблюдение приостановлено")
            if let current = session.currentActivity {
                LabeledContent("Сейчас", value: ActivityText.title(current))
            }
            Button("Завершить") { Task { await journal.finishSession() } }
            Button("Удалить без отправки", role: .destructive) { confirmingDelete = true }
        case .interrupted:
            Label("Сессия прервана: приложение было закрыто. Время после закрытия не учитывается.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Завершить") { Task { await journal.finishSession() } }
            Button("Удалить без отправки", role: .destructive) { confirmingDelete = true }
        case .awaitingConfirmation:
            if let summary = session.summary {
                SummaryRows(summary: summary)
                Text("В Katana уйдут только эти числа, вид активности и время начала и конца.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if journal.isSendingSession {
                ProgressView()
            } else {
                Button("Отправить в Katana") { Task { await journal.confirmSession() } }
                Button("Удалить без отправки", role: .destructive) { confirmingDelete = true }
            }
        }
    }
}

private struct SummaryRows: View {
    let summary: ActivitySessionSummary

    var body: some View {
        LabeledContent("Длительность", value: ActivityText.duration(summary.durationSeconds))
        LabeledContent("Преобладает", value: ActivityText.title(summary.dominantActivity))
        ForEach(ActivityCategory.allCases, id: \.self) { category in
            if summary.seconds[category] > 0 {
                LabeledContent(ActivityText.title(category), value: ActivityText.duration(summary.seconds[category]))
                    .font(.footnote)
            }
        }
        if summary.interrupted {
            Text("Сессия была прервана.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let entry: ActivityHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.kind == .snapshot ? "Текущая активность" : "Сессия").font(.subheadline.bold())
            Text(detail).font(.footnote)
            Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            EventDeliveryStatusLabel(eventID: entry.eventID)
        }
    }

    private var detail: String {
        switch entry.kind {
        case .snapshot:
            return ActivityText.title(entry.activity)
        case .session:
            let duration = entry.durationSeconds.map(ActivityText.duration) ?? ""
            return "\(ActivityText.title(entry.activity)) · \(duration)" + (entry.interrupted ? " · прервана" : "")
        }
    }
}

private struct FailureText: View {
    let failure: ActivityJournalCoordinator.Failure

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.orange)
        if failure == .permissionDenied {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var text: String {
        switch failure {
        case .unsupported: return "Это устройство не определяет активность."
        case .permissionDenied: return "Доступ к «Движению и фитнесу» запрещён. Его можно разрешить в Настройках."
        case .permissionRestricted: return "Доступ к «Движению и фитнесу» ограничен на этом устройстве."
        case .timedOut: return "Система не ответила вовремя. Попробуйте ещё раз."
        case .systemError: return "Не удалось определить активность. Попробуйте ещё раз."
        case .storage: return "Не удалось сохранить сессию на iPhone."
        case .notPaired: return "Katana не подключена — результат не отправлен. Подключите Katana и повторите."
        case .saveFailed: return "Не удалось сохранить результат для Katana. Попробуйте ещё раз."
        }
    }
}

enum ActivityText {
    static func title(_ category: ActivityCategory) -> String {
        switch category {
        case .stationary: return "Неподвижно"
        case .walking: return "Ходьба"
        case .running: return "Бег"
        case .cycling: return "Велосипед"
        case .automotive: return "Транспорт"
        case .unknown: return "Неизвестно"
        }
    }

    static func title(_ confidence: ActivityConfidence) -> String {
        switch confidence {
        case .low: return "низкая"
        case .medium: return "средняя"
        case .high: return "высокая"
        }
    }

    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) с"
    }
}
