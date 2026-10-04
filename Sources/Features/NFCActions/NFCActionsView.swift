import SwiftUI
import UIKit

/// NFC actions registered from Katana drafts. Shortcuts + NFC is the working path; native
/// Core NFC buttons are enabled only when this build is provisioned for it (D-046).
struct NFCActionsView: View {
    @EnvironmentObject var nfc: NFCActionCoordinator
    @State private var actionToRemove: NFCActionRegistration?
    @State private var actionToWrite: NFCActionRegistration?
    @State private var copiedActionID: UUID?

    var body: some View {
        List {
            Section {
                Text("NFC-действие приходит из Katana. Касание метки только открывает предпросмотр — действие выполняется после кнопки «Выполнить». UID и содержимое меток не сохраняются.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if nfc.registrations.isEmpty {
                Section {
                    Text("Пока нет действий. Откройте в Katana ссылку на NFC-действие.").foregroundStyle(.secondary)
                }
            } else {
                Section("Действия") {
                    ForEach(nfc.registrations) { registration in
                        row(registration)
                    }
                }
            }
            Section {
                Text("1. Нажмите «Скопировать ссылку для Команд».\n2. Команды → Автоматизация → NFC → отсканируйте метку.\n3. Действие «Открыть URL» → вставьте ссылку.\nСсылка содержит только идентификатор действия.")
                    .font(.footnote)
            } header: {
                Text("Метка через Команды")
            }
            coreNFCSection
            if let issue = nfc.storageIssue {
                Text(issue == .quarantined
                     ? "Файл NFC-действий был повреждён: он сохранён для диагностики, список начат заново."
                     : "Не удалось сохранить NFC-действия на iPhone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("NFC-действия")
        .navigationBarTitleDisplayMode(.inline)
        .task { await nfc.refreshCoreNFCStatus() }
        .confirmationDialog("Удалить NFC-действие с этого iPhone?",
                            isPresented: Binding(get: { actionToRemove != nil }, set: { if !$0 { actionToRemove = nil } }),
                            titleVisibility: .visible, presenting: actionToRemove) { registration in
            Button("Удалить", role: .destructive) { nfc.remove(actionID: registration.actionID) }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Метки и команды с этой ссылкой перестанут работать на этом iPhone.")
        }
        .confirmationDialog("Записать ссылку на метку?",
                            isPresented: Binding(get: { actionToWrite != nil }, set: { if !$0 { actionToWrite = nil } }),
                            titleVisibility: .visible, presenting: actionToWrite) { registration in
            Button("Записать") { Task { await nfc.writeTag(actionID: registration.actionID) } }
            Button("Отмена", role: .cancel) {}
        } message: { registration in
            Text("На метку будет записана только ссылка «\(nfc.shortcutLink(for: registration.actionID).absoluteString)». Метка не блокируется.")
        }
    }

    @ViewBuilder
    private func row(_ registration: NFCActionRegistration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(registration.label).font(.subheadline.bold())
            Text(status(registration)).font(.caption).foregroundStyle(.secondary)
            Toggle("Включено", isOn: Binding(get: { registration.enabled },
                                             set: { nfc.setEnabled($0, actionID: registration.actionID) }))
                .font(.footnote)
            Button(copiedActionID == registration.actionID ? "Ссылка скопирована" : "Скопировать ссылку для Команд") {
                UIPasteboard.general.url = nfc.shortcutLink(for: registration.actionID)
                copiedActionID = registration.actionID
            }
            .font(.footnote)
            if nfc.coreNFCStatus == .available {
                Button("Записать на NFC-метку") { actionToWrite = registration }.font(.footnote)
            }
            Button("Удалить", role: .destructive) { actionToRemove = registration }.font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private func status(_ registration: NFCActionRegistration) -> String {
        if registration.isExpired(at: Date()) { return "Срок действия истёк — запросите новое действие в Katana" }
        return registration.enabled ? "Активно" : "Выключено"
    }

    private var coreNFCSection: some View {
        Section {
            LabeledContent("Core NFC", value: NFCText.status(nfc.coreNFCStatus))
            switch nfc.coreNFCStatus {
            case .available:
                Button("Сканировать метку") { Task { await nfc.scanTag() } }
                    .disabled(nfc.scanState == .scanning || nfc.scanState == .writing)
                if let text = NFCText.scan(nfc.scanState) {
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
            case .requiresEntitlement:
                Text("Сканирование и запись меток в приложении требуют NFC-entitlement, которого нет в этой сборке. Используйте метку через Команды.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .unsupportedDevice:
                Text("Это устройство не читает NFC-метки.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Сканирование в приложении")
        }
    }
}

/// Preview of one NFC action run. Opening it (also by a link or a tag) runs nothing.
struct NFCActionPreviewView: View {
    let actionID: UUID
    let source: NFCActionSource
    @EnvironmentObject var nfc: NFCActionCoordinator

    var body: some View {
        List {
            switch nfc.previews[actionID] {
            case .ready(let run)?:
                Section {
                    if let registration = nfc.registration(for: actionID) {
                        Text(registration.label).font(.headline)
                    }
                    LabeledContent("Источник", value: run.source == .shortcut ? "Команды (NFC)" : "NFC-метка")
                    if run.restored {
                        Text("Запуск восстановлен после перезапуска приложения.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Выполнить") { Task { await nfc.decide(actionID: actionID, result: .confirmed) } }
                    Button("Отклонить", role: .destructive) { Task { await nfc.decide(actionID: actionID, result: .declined) } }
                    Text("Katana получит только результат и время — без данных метки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done(let execution)?:
                Section {
                    Label(execution.result == .confirmed ? "Выполнено" : "Отклонено",
                          systemImage: execution.result == .confirmed ? "checkmark.circle" : "xmark.circle")
                    EventDeliveryStatusLabel(eventID: execution.eventID)
                }
            case .unknown?:
                Section { Text("Это NFC-действие не зарегистрировано на этом iPhone.").foregroundStyle(.orange) }
            case .disabled?:
                Section { Text("Это NFC-действие выключено. Включите его в «NFC-действия».").foregroundStyle(.orange) }
            case .expired?:
                Section { Text("Срок действия этого NFC-действия истёк. Запросите новое в Katana.").foregroundStyle(.orange) }
            case nil:
                Section { ProgressView() }
            }
        }
        .navigationTitle("NFC-действие")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nfc.open(actionID: actionID, source: source) }
    }
}

enum NFCText {
    static func status(_ status: CoreNFCStatus) -> String {
        switch status {
        case .available: return "доступно"
        case .requiresEntitlement: return "требуется entitlement"
        case .unsupportedDevice: return "не поддерживается"
        }
    }

    static func scan(_ state: NFCActionCoordinator.ScanState) -> String? {
        switch state {
        case .idle, .scanning, .writing: return nil
        case .found: return "Метка Katana найдена — откройте действие в списке."
        case .notKatana: return "На метке нет ссылки Katana. Её содержимое не сохранено."
        case .empty: return "Метка пустая."
        case .cancelled: return "Сканирование отменено."
        case .written: return "Ссылка записана. Метка не заблокирована."
        case .failed(let error):
            switch error {
            case .readOnly: return "Метка защищена от записи."
            case .unsupportedTag: return "Метка не поддерживается."
            case .tooSmall: return "На метке недостаточно места."
            case .cancelled: return "Отменено."
            case .notAvailable: return "Core NFC недоступен."
            case .systemError: return "Не удалось. Попробуйте ещё раз."
            }
        }
    }
}
