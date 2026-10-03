import SwiftUI

/// «Завершить разбор»: opens the summary. Leaving Screenshot Cleanup without it creates nothing.
struct FinishSessionButton: View {
    @EnvironmentObject var store: SweepStore
    @EnvironmentObject var session: CleanupSessionRecorder
    @State private var showingSummary = false

    var body: some View {
        if session.tracker.hasActivity || showingSummary {
            Button("Завершить разбор") { showingSummary = true }
                .font(.footnote)
                .disabled(store.isDeleting || !session.canComplete)
                .sheet(isPresented: $showingSummary) {
                    CleanupCompletionView()
                }
        }
    }
}

/// Session summary before and after explicit completion. Shows counts only — never
/// event IDs, connection details, tokens or raw errors.
struct CleanupCompletionView: View {
    @EnvironmentObject var session: CleanupSessionRecorder
    @EnvironmentObject var delivery: EventDeliveryCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var preview: CleanupSessionSummary?
    @State private var completion: CleanupSessionRecorder.Completion?

    var body: some View {
        NavigationStack {
            List {
                if let summary = completion?.summary ?? preview {
                    Section("Итог разбора") {
                        LabeledContent("Просмотрено", value: "\(summary.reviewedCount)")
                        LabeledContent("Оставлено", value: "\(summary.keptCount)")
                        LabeledContent("Отмечено на удаление", value: "\(summary.deletionRequestedCount)")
                        if !summary.deletionCompleted {
                            Text("Не все отмеченные скриншоты удалены. Удаление происходит только на экране проверки после подтверждения.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("В этом разборе пока нет решений.").foregroundStyle(.secondary)
                    }
                }

                if let completion {
                    Section("Katana") {
                        Label(statusText(completion), systemImage: statusIcon(completion))
                    }
                } else {
                    Section {
                        Text("В Katana отправятся только эти числа и время разбора. Скриншоты и данные о них остаются на iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Завершение разбора")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if completion == nil {
                        Button("Продолжить разбор") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if completion == nil {
                        Button("Завершить") {
                            Task { completion = await session.complete() }
                        }
                        .disabled(preview == nil || session.isCompleting)
                    } else {
                        Button("Готово") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(session.isCompleting)
            .onAppear {
                if completion == nil { preview = session.previewSummary() }
            }
        }
    }

    private func statusText(_ completion: CleanupSessionRecorder.Completion) -> String {
        switch completion.outcome {
        case .notPaired:
            return "Katana не подключена — итог не отправляется."
        case .failed:
            return "Не удалось сохранить итог для Katana. Разбор завершён, скриншоты не затронуты."
        case .saved:
            guard let id = completion.eventID else { return "Результат сохранён для Katana" }
            if delivery.deliveredEventIDs.contains(id) { return "Результат отправлен в Katana" }
            if delivery.rejectedEventIDs.contains(id) { return "Katana не приняла результат." }
            return "Результат сохранён для Katana и будет отправлен при наличии связи."
        }
    }

    private func statusIcon(_ completion: CleanupSessionRecorder.Completion) -> String {
        switch completion.outcome {
        case .notPaired: return "link.badge.plus"
        case .failed: return "exclamationmark.triangle"
        case .saved:
            if let id = completion.eventID, delivery.deliveredEventIDs.contains(id) { return "checkmark.icloud" }
            return "tray.and.arrow.up"
        }
    }
}
