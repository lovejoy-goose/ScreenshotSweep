import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// «Поделиться с Katana» inside the app (D-050). Everything goes through the same validation and
/// inbox as the Share Extension; nothing is uploaded before «Отправить в Katana».
struct CaptureView: View {
    @EnvironmentObject var capture: CaptureCoordinator
    @State private var text = ""
    @State private var link = ""
    @State private var photo: PhotosPickerItem?
    @State private var importingFile = false
    @State private var itemToSend: CaptureManifest?
    @State private var itemToCancel: CaptureManifest?

    private static let fileTypes: [UTType] = [.pdf, .plainText, .commaSeparatedText, .json, .jpeg, .png, .heic]

    var body: some View {
        List {
            Section {
                Text("Текст, ссылка, изображение, PDF или текстовый файл — по одному. Сначала предпросмотр, отправка — только после вашего подтверждения. У изображений удаляются EXIF и геоданные.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Системный пункт «Поделиться → Katana Connector» появится после включения App Group (в этой сборке его нет).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let draft = capture.activeDraft {
                Section("Запрос Katana") {
                    Text(draft.payload.prompt).font(.subheadline)
                    Text("Можно: " + draft.payload.acceptedKinds.map(CaptureText.title).joined(separator: ", ")).font(.caption)
                }
            }
            addSection
            if !capture.items.isEmpty {
                Section("Ждут решения") {
                    ForEach(capture.items) { item in
                        CaptureItemRow(item: item, onSend: { itemToSend = item }, onCancel: { itemToCancel = item })
                    }
                }
            }
            if !capture.history.isEmpty {
                Section("История") {
                    ForEach(capture.history) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(CaptureText.title(entry.kind)) · \(CaptureText.bucket(entry.sizeBucket))").font(.subheadline)
                            Text(CaptureText.outcome(entry.outcome)).font(.caption).foregroundStyle(.secondary)
                            if entry.outcome == .sent, let eventID = entry.eventID {
                                EventDeliveryStatusLabel(eventID: eventID)
                            }
                        }
                    }
                }
            }
            if let issue = capture.storageIssue {
                Text(issue == .writeFailed ? "Не удалось сохранить на iPhone."
                     : "Повреждённые записи отложены для диагностики и не отправлены.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Поделиться с Katana")
        .navigationBarTitleDisplayMode(.inline)
        .task { await capture.resumePending() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: Self.fileTypes) { result in
            guard case .success(let url) = result else { return }
            importFile(url)
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                let type = item.supportedContentTypes.first?.identifier
                if let data = try? await item.loadTransferable(type: Data.self) {
                    capture.importFile(data: data, declaredType: type, originalName: nil)
                }
                photo = nil
            }
        }
        .confirmationDialog("Отправить в Katana?",
                            isPresented: Binding(get: { itemToSend != nil }, set: { if !$0 { itemToSend = nil } }),
                            titleVisibility: .visible, presenting: itemToSend) { item in
            Button("Отправить") { Task { await capture.confirm(item.captureID) } }
            Button("Отмена", role: .cancel) {}
        } message: { item in
            Text(item.kind == .pdf || item.kind == .file
                 ? "Содержимое уйдёт в Katana как есть (метаданные PDF и файлов не очищаются). Имя файла не отправляется."
                 : "Содержимое уйдёт в Katana по защищённому соединению.")
        }
        .confirmationDialog("Отменить и удалить?",
                            isPresented: Binding(get: { itemToCancel != nil }, set: { if !$0 { itemToCancel = nil } }),
                            titleVisibility: .visible, presenting: itemToCancel) { item in
            Button("Удалить", role: .destructive) { Task { await capture.cancel(item.captureID) } }
            Button("Не удалять", role: .cancel) {}
        } message: { _ in
            Text("Файлы будут удалены с iPhone. Katana узнает только, что отправка отменена.")
        }
    }

    private var addSection: some View {
        Section("Добавить") {
            TextField("Текст", text: $text, axis: .vertical).lineLimit(1...5)
            Button("Проверить текст") {
                capture.importText(text)
                if case .added = capture.importState { text = "" }
            }
            .disabled(text.isEmpty)
            TextField("Ссылка https://…", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Проверить ссылку") {
                capture.importURL(link)
                if case .added = capture.importState { link = "" }
            }
            .disabled(link.isEmpty)
            PhotosPicker("Выбрать фото", selection: $photo, matching: .images)
            Button("Выбрать файл (PDF, текст, CSV, JSON, изображение)") { importingFile = true }
            if case .rejected(let rejection) = capture.importState {
                Text(CaptureText.rejection(rejection)).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    /// Reads at most limit + 1 bytes, so an oversized file is never loaded whole.
    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
        let limit = CaptureLimits.maxImageBytes
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            capture.rejectOversized()
            return
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else {
            capture.rejectOversized()
            return
        }
        capture.importFile(data: data, declaredType: type, originalName: url.lastPathComponent)
    }
}

private struct CaptureItemRow: View {
    @EnvironmentObject var capture: CaptureCoordinator
    let item: CaptureManifest
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(CaptureText.title(item.kind)) · \(CaptureText.size(item.sizeBytes))").font(.subheadline.bold())
            if let name = item.normalizedName {
                Text("Имя (только на экране): \(name)").font(.caption).foregroundStyle(.secondary)
            }
            preview
            if item.origin == .shareExtension {
                Text("Из «Поделиться»").font(.caption).foregroundStyle(.secondary)
            }
            switch item.state {
            case .pendingReview:
                Button("Отправить в Katana", action: onSend)
                Button("Отменить", role: .destructive, action: onCancel)
            case .confirmed:
                Text(CaptureText.status(capture.itemStatus[item.captureID])).font(.caption)
                Button("Отменить", role: .destructive, action: onCancel)
            case .uploaded:
                Text("Загружено, сохраняем результат для Katana…").font(.caption)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var preview: some View {
        if let data = capture.previewData(item.captureID) {
            switch item.kind {
            case .text, .url, .file:
                Text(String(decoding: data.prefix(400), as: UTF8.self)).font(.caption.monospaced()).lineLimit(6)
            case .image:
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                }
            case .pdf:
                Label("PDF-документ", systemImage: "doc.richtext")
            }
        }
    }
}

extension CaptureText {
    static func bucket(_ bucket: CaptureSizeBucket) -> String {
        switch bucket {
        case .under10kb: return "до 10 КБ"
        case .under100kb: return "до 100 КБ"
        case .under1mb: return "до 1 МБ"
        case .under10mb: return "до 10 МБ"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func outcome(_ outcome: CaptureHistoryEntry.Outcome) -> String {
        switch outcome {
        case .sent: return "Отправлено"
        case .cancelled: return "Отменено"
        case .failed: return "Katana не приняла"
        }
    }

    static func status(_ status: CaptureCoordinator.ItemStatus?) -> String {
        switch status {
        case .uploading?: return "Отправляем…"
        case .waitingForNetwork?: return "Нет связи — отправим позже."
        case .requiresRepair?: return "Требуется повторное подключение к Katana."
        case .notPaired?: return "Katana не подключена."
        case nil: return "Ожидает отправки."
        }
    }

    static func rejection(_ rejection: CaptureRejection) -> String {
        switch rejection {
        case .empty: return "Пусто."
        case .unsupportedType: return "Этот тип не поддерживается."
        case .typeMismatch: return "Содержимое не совпадает с типом или расширением файла."
        case .tooLarge: return "Слишком большой размер (изображение/PDF до 10 МБ, файл до 5 МБ, текст до 10 000 символов)."
        case .invalidText: return "Текст не подходит (пустой, слишком длинный или с недопустимыми символами)."
        case .invalidURL: return "Нужна ссылка http(s) без логина и пароля, до 2048 символов."
        case .invalidName: return "Недопустимое имя файла."
        case .sanitizationFailed: return "Не удалось удалить метаданные изображения — оно не сохранено."
        case .inboxFull: return "Слишком много ожидающих записей (до 10 и 50 МБ). Отправьте или отмените что-нибудь."
        case .notAcceptedByDraft: return "Katana ждёт другой тип."
        case .storage: return "Не удалось сохранить на iPhone."
        }
    }
}
