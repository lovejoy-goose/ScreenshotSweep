import Combine
import Foundation

/// «Поделиться с Katana» (D-050). Content enters the inbox only after validation (and metadata
/// removal for images); nothing is uploaded before «Отправить в Katana»; the main app checks
/// every inbox entry again. Events carry no content.
@MainActor
final class CaptureCoordinator: ObservableObject, ActionDraftHandler {
    enum ImportState: Equatable, Sendable {
        case idle
        case validating
        case added(UUID)
        case rejected(CaptureRejection)
    }

    enum ItemStatus: Equatable, Sendable {
        case uploading
        /// Will be retried on the next launch, return to the app or «Синхронизировать».
        case waitingForNetwork
        case requiresRepair
        case notPaired
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined(Int)
        case writeFailed
    }

    @Published private(set) var items: [CaptureManifest] = []
    @Published private(set) var history: [CaptureHistoryEntry] = []
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var itemStatus: [UUID: ItemStatus] = [:]
    @Published private(set) var storageIssue: StorageIssue?
    /// A Katana `shared_capture` draft the next capture answers.
    @Published private(set) var activeDraft: (id: UUID, payload: CaptureDraftPayload)?

    weak var sink: (any ConnectorEventSink)?
    weak var actionDrafts: ActionDraftCoordinator?

    private let inboxes: [CaptureInboxStore]
    private let historyStore: VersionedJSONFileStore<CaptureHistoryFile>
    private let uploader: any CaptureUploading
    private let now: () -> Date
    private var busy: Set<UUID> = []
    private var isResuming = false

    /// `inboxes[0]` is where the app writes; further inboxes (an App Group shared with the Share
    /// Extension) are only read.
    init(inboxes: [CaptureInboxStore],
         historyStore: VersionedJSONFileStore<CaptureHistoryFile>,
         uploader: any CaptureUploading,
         sink: (any ConnectorEventSink)? = nil,
         now: @escaping () -> Date = { Date() }) {
        precondition(!inboxes.isEmpty)
        self.inboxes = inboxes
        self.historyStore = historyStore
        self.uploader = uploader
        self.sink = sink
        self.now = now
        do {
            history = try historyStore.load().history
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined(1)
        } catch {
            storageIssue = .writeFailed
        }
        refreshInbox()
    }

    private var appInbox: CaptureInboxStore { inboxes[0] }

    private func inbox(for manifest: CaptureManifest) -> CaptureInboxStore {
        inboxes.first { FileManager.default.fileExists(atPath: $0.manifestURL(manifest.captureID).path) } ?? appInbox
    }

    // MARK: Inbox

    /// Loads all inboxes again and re-checks every waiting entry against its stored bytes.
    func refreshInbox() {
        var entries: [CaptureManifest] = []
        var quarantined = 0
        for inbox in inboxes {
            guard let result = try? inbox.load(now: now()) else { continue }
            quarantined += result.quarantined
            for manifest in result.entries {
                if manifest.state == .uploaded {
                    entries.append(manifest)
                    continue
                }
                guard let data = try? inbox.payload(manifest.captureID), data.count == manifest.sizeBytes,
                      CaptureHash.sha256(data) == manifest.sha256,
                      CaptureValidator.storedBytesMatch(kind: manifest.kind, contentType: manifest.contentType, data: data) else {
                    inbox.quarantine(manifest.captureID)
                    quarantined += 1
                    continue
                }
                entries.append(manifest)
            }
        }
        items = entries.sorted { $0.createdAt < $1.createdAt }
        if quarantined > 0 { storageIssue = .quarantined(quarantined) }
    }

    /// Stored bytes of a waiting entry, for the preview only.
    func previewData(_ captureID: UUID) -> Data? {
        guard let manifest = items.first(where: { $0.captureID == captureID }), manifest.state != .uploaded else { return nil }
        return try? inbox(for: manifest).payload(captureID)
    }

    // MARK: Import (in-app; the Share Extension writes the same records)

    func importText(_ text: String) {
        add(CaptureCandidate(declaredKind: .text, declaredType: nil, originalName: nil, data: Data(text.utf8)))
    }

    func importURL(_ text: String) {
        add(CaptureCandidate(declaredKind: .url, declaredType: nil, originalName: nil, data: Data(text.utf8)))
    }

    /// A file or photo from a picker. `declaredType` is a UTI or extension; the kind follows from it.
    func importFile(data: Data, declaredType: String?, originalName: String?) {
        guard let kind = CaptureValidator.kind(forDeclaredType: declaredType)
                ?? CaptureValidator.kind(forDeclaredType: CaptureFileName.pathExtension(CaptureFileName.normalize(originalName))) else {
            importState = .rejected(.unsupportedType)
            return
        }
        add(CaptureCandidate(declaredKind: kind, declaredType: declaredType, originalName: originalName, data: data))
    }

    /// A picker reported a file larger than any limit before reading it.
    func rejectOversized() {
        importState = .rejected(.tooLarge)
    }

    private func add(_ candidate: CaptureCandidate) {
        importState = .validating
        if let draft = activeDraft, !draft.payload.acceptedKinds.contains(candidate.declaredKind) {
            importState = .rejected(.notAcceptedByDraft)
            return
        }
        do {
            let validated = try CaptureValidator.validate(candidate)
            let manifest = try appInbox.add(validated, origin: .inApp, draftID: activeDraft?.id, now: now())
            refreshInbox()
            importState = .added(manifest.captureID)
        } catch let rejection as CaptureRejection {
            importState = .rejected(rejection)
        } catch {
            importState = .rejected(.storage)
        }
    }

    func clearImportState() {
        importState = .idle
    }

    // MARK: Action draft

    func performActionDraft(_ draft: ActionDraft) async -> ActionDraftHandlerResult {
        guard case .sharedCapture(let payload) = draft.payload else { return .notPerformed }
        activeDraft = (draft.draftID, payload)
        return .continuing
    }

    // MARK: Confirm / cancel

    /// «Отправить в Katana» (after the user confirmed the preview).
    func confirm(_ captureID: UUID) async {
        guard let index = items.firstIndex(where: { $0.captureID == captureID }), items[index].state == .pendingReview else { return }
        var manifest = items[index]
        manifest.state = .confirmed
        do {
            try inbox(for: manifest).save(manifest)
        } catch {
            storageIssue = .writeFailed
            return
        }
        items[index] = manifest
        await upload(captureID)
    }

    /// «Отменить»: files are deleted; Katana gets `share.capture.cancelled` without content.
    func cancel(_ captureID: UUID) async {
        guard let manifest = items.first(where: { $0.captureID == captureID }), manifest.state != .uploaded,
              !busy.contains(captureID) else { return }
        let bucket = CaptureSizeBucket(bytes: manifest.sizeBytes) ?? .under10mb
        let entry = CaptureHistoryEntry(captureID: captureID, kind: manifest.kind, sizeBucket: bucket,
                                        finishedAt: WholeSeconds.floor(now()), outcome: .cancelled, eventID: UUID(), eventSaved: false)
        record(entry)
        inbox(for: manifest).remove(captureID)
        items.removeAll { $0.captureID == captureID }
        itemStatus[captureID] = nil
        if let draftID = manifest.draftID { actionDrafts?.abandonDeferred(draftID: draftID) }
        await saveHistoryEvents()
    }

    // MARK: Upload

    private func upload(_ captureID: UUID) async {
        guard !busy.contains(captureID), let manifest = items.first(where: { $0.captureID == captureID }),
              manifest.state == .confirmed else { return }
        busy.insert(captureID)
        defer { busy.remove(captureID) }
        let inbox = inbox(for: manifest)
        // The main app checks the bytes once more right before they leave the device.
        guard let data = try? inbox.payload(captureID), data.count == manifest.sizeBytes,
              CaptureHash.sha256(data) == manifest.sha256,
              CaptureValidator.storedBytesMatch(kind: manifest.kind, contentType: manifest.contentType, data: data) else {
            inbox.quarantine(captureID)
            items.removeAll { $0.captureID == captureID }
            storageIssue = .quarantined(1)
            return
        }
        itemStatus[captureID] = .uploading
        do {
            let receipt = try await uploader.uploadCapture(id: captureID, kind: manifest.kind, contentType: manifest.contentType,
                                                           sha256: manifest.sha256, body: data)
            var uploaded = manifest
            uploaded.state = .uploaded
            uploaded.objectRef = receipt.objectRef
            uploaded.createdEventID = UUID()
            uploaded.uploadedAt = WholeSeconds.floor(now())
            // Saved before the event is queued: a crash here retries the same event ID.
            try? inbox.save(uploaded)
            inbox.removePayload(captureID)
            replace(uploaded)
            itemStatus[captureID] = nil
            await finishUploaded(captureID)
        } catch let error as CaptureUploadError {
            switch error {
            case .offline, .rateLimited, .serverError:
                itemStatus[captureID] = .waitingForNetwork
            case .unauthorized:
                itemStatus[captureID] = .requiresRepair
                sink?.reportUnauthorized()
            case .notPaired:
                itemStatus[captureID] = .notPaired
            case .conflict, .rejected, .invalidResponse:
                let bucket = CaptureSizeBucket(bytes: manifest.sizeBytes) ?? .under10mb
                record(CaptureHistoryEntry(captureID: captureID, kind: manifest.kind, sizeBucket: bucket,
                                           finishedAt: WholeSeconds.floor(now()), outcome: .failed, eventID: nil, eventSaved: true))
                inbox.remove(captureID)
                items.removeAll { $0.captureID == captureID }
                itemStatus[captureID] = nil
                if let draftID = manifest.draftID { actionDrafts?.abandonDeferred(draftID: draftID) }
            }
        } catch {
            itemStatus[captureID] = .waitingForNetwork
        }
    }

    /// Queues `share.capture.created`, then the entry leaves the inbox and only history remains.
    private func finishUploaded(_ captureID: UUID) async {
        guard let sink, let manifest = items.first(where: { $0.captureID == captureID }), manifest.state == .uploaded,
              let event = try? CaptureEvents.created(manifest) else { return }
        guard await sink.enqueueEvent(event) == .saved else { return }
        let bucket = CaptureSizeBucket(bytes: manifest.sizeBytes) ?? .under10mb
        record(CaptureHistoryEntry(captureID: captureID, kind: manifest.kind, sizeBucket: bucket,
                                   finishedAt: manifest.uploadedAt ?? WholeSeconds.floor(now()), outcome: .sent,
                                   eventID: manifest.createdEventID, eventSaved: true))
        inbox(for: manifest).remove(captureID)
        items.removeAll { $0.captureID == captureID }
        if let draftID = manifest.draftID {
            if activeDraft?.id == draftID { activeDraft = nil }
            await actionDrafts?.completeDeferred(draftID: draftID, kind: .sharedCapture, resultRef: captureID)
        }
    }

    /// Launch, return to the app, «Синхронизировать»: retry uploads and unsaved events.
    func resumePending() async {
        guard !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        refreshInbox()
        for manifest in items {
            switch manifest.state {
            case .confirmed: await upload(manifest.captureID)
            case .uploaded: await finishUploaded(manifest.captureID)
            case .pendingReview: break
            }
        }
        await saveHistoryEvents()
    }

    private func saveHistoryEvents() async {
        guard let sink else { return }
        for entry in history where !entry.eventSaved && entry.outcome == .cancelled {
            guard let event = try? CaptureEvents.cancelled(entry), await sink.enqueueEvent(event) == .saved,
                  let index = history.firstIndex(where: { $0.captureID == entry.captureID }) else { continue }
            history[index].eventSaved = true
            persistHistory()
        }
    }

    // MARK: Helpers

    private func replace(_ manifest: CaptureManifest) {
        guard let index = items.firstIndex(where: { $0.captureID == manifest.captureID }) else { return }
        items[index] = manifest
    }

    private func record(_ entry: CaptureHistoryEntry) {
        history.removeAll { $0.captureID == entry.captureID }
        history.insert(entry, at: 0)
        if history.count > CaptureHistoryFile.maxEntries {
            history.removeLast(history.count - CaptureHistoryFile.maxEntries)
        }
        persistHistory()
    }

    private func persistHistory() {
        do {
            try historyStore.save(CaptureHistoryFile(history: history))
        } catch {
            storageIssue = .writeFailed
        }
    }
}
