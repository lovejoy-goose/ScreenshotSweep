import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// «Поделиться → Katana Connector» (D-050). Takes one attachment, validates it with the same
/// rules as the app, shows a preview and — only after «Сохранить для Katana» — writes it to the
/// App Group inbox. No token, no network, no commands. Without an App Group (this build, D-046)
/// it says so and stores nothing.
final class ShareViewController: UIViewController {
    private let model = ShareExtensionModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.complete = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "app.katana.connector.share", code: 0))
        }
        let host = UIHostingController(rootView: ShareExtensionView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        Task { await model.load(providers) }
    }
}

@MainActor
final class ShareExtensionModel: ObservableObject {
    enum State: Equatable {
        case loading
        case unavailable
        case preview(ValidatedCapture)
        case rejected(CaptureRejection)
        case saved
    }

    @Published var state: State = .loading
    var complete: () -> Void = {}
    var cancel: () -> Void = {}

    private let inbox = CaptureInboxStore.appGroup()

    /// Exactly one attachment in v0.3.
    func load(_ providers: [NSItemProvider]) async {
        guard inbox != nil else {
            state = .unavailable
            return
        }
        guard providers.count == 1, let provider = providers.first else {
            state = .rejected(.unsupportedType)
            return
        }
        do {
            state = .preview(try CaptureValidator.validate(try await Self.candidate(from: provider)))
        } catch let rejection as CaptureRejection {
            state = .rejected(rejection)
        } catch {
            state = .rejected(.unsupportedType)
        }
    }

    /// «Сохранить для Katana»: the main app checks it again and asks before sending anything.
    func save() {
        guard case .preview(let capture) = state, let inbox else { return }
        do {
            _ = try inbox.add(capture, origin: .shareExtension, draftID: nil, now: Date())
            state = .saved
        } catch let rejection as CaptureRejection {
            state = .rejected(rejection)
        } catch {
            state = .rejected(.storage)
        }
    }

    private static let fileTypes: [UTType] = [.jpeg, .png, .heic, .pdf, .commaSeparatedText, .json, .plainText]

    private static func candidate(from provider: NSItemProvider) async throws -> CaptureCandidate {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil)
            guard let url = item as? URL else { throw CaptureRejection.invalidURL }
            return CaptureCandidate(declaredKind: .url, declaredType: nil, originalName: nil, data: Data(url.absoluteString.utf8))
        }
        for type in fileTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            guard let kind = CaptureValidator.kind(forDeclaredType: type.identifier) else { continue }
            let data = try await loadData(provider, type: type)
            return CaptureCandidate(declaredKind: kind, declaredType: type.identifier, originalName: provider.suggestedName, data: data)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil)
            guard let text = item as? String else { throw CaptureRejection.invalidText }
            return CaptureCandidate(declaredKind: .text, declaredType: nil, originalName: nil, data: Data(text.utf8))
        }
        throw CaptureRejection.unsupportedType
    }

    /// Reads at most the largest limit + 1 bytes from the provided file.
    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url, error == nil, let handle = try? FileHandle(forReadingFrom: url) else {
                    return continuation.resume(throwing: CaptureRejection.unsupportedType)
                }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: CaptureLimits.maxImageBytes + 1)) ?? Data()
                guard data.count <= CaptureLimits.maxImageBytes else {
                    return continuation.resume(throwing: CaptureRejection.tooLarge)
                }
                continuation.resume(returning: data)
            }
        }
    }
}

struct ShareExtensionView: View {
    @ObservedObject var model: ShareExtensionModel

    var body: some View {
        NavigationStack {
            List {
                switch model.state {
                case .loading:
                    ProgressView()
                case .unavailable:
                    Text("Эта сборка Katana Connector ещё не может принимать данные из «Поделиться»: нужен общий контейнер (App Group). Откройте Katana Connector → «Поделиться с Katana».")
                case .preview(let capture):
                    Section("Предпросмотр") {
                        Text(capture.kind.rawValue)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(capture.sizeBytes), countStyle: .file))
                        if let name = capture.normalizedName { Text(name).font(.caption) }
                    }
                    Section {
                        Text("Ничего не отправляется отсюда. Katana Connector покажет запись и спросит подтверждение.")
                            .font(.footnote)
                        Button("Сохранить для Katana") { model.save() }
                    }
                case .rejected:
                    Text("Этот объект нельзя передать в Katana (тип, размер или содержимое).")
                case .saved:
                    Text("Сохранено. Откройте Katana Connector, чтобы проверить и отправить.")
                }
            }
            .navigationTitle("Katana Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.state == .saved ? "Готово" : "Отмена") {
                        model.state == .saved ? model.complete() : model.cancel()
                    }
                }
            }
        }
    }
}
