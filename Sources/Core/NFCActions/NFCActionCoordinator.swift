import Combine
import Foundation

/// NFC actions (D-048). A trigger (Shortcuts link or Core NFC scan) only opens the preview;
/// «Выполнить» / «Отклонить» create exactly one `nfc.action.completed` per run.
@MainActor
final class NFCActionCoordinator: ObservableObject, ActionDraftHandler {
    enum Preview: Equatable, Sendable {
        case ready(NFCPendingExecution)
        case unknown
        case disabled
        case expired
        /// Decided; shows the result.
        case done(NFCCompletedExecution)
    }

    enum ScanState: Equatable, Sendable {
        case idle
        case scanning
        case found(UUID)
        case notKatana
        case empty
        case cancelled
        case failed(NFCTagError)
        case writing
        case written
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined
        case writeFailed
    }

    @Published private(set) var registrations: [NFCActionRegistration] = []
    @Published private(set) var pending: [NFCPendingExecution] = []
    @Published private(set) var executions: [NFCCompletedExecution] = []
    @Published private(set) var previews: [UUID: Preview] = [:]
    @Published private(set) var coreNFCStatus: CoreNFCStatus = .requiresEntitlement
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var storageIssue: StorageIssue?

    weak var sink: (any ConnectorEventSink)?

    private let store: VersionedJSONFileStore<NFCActionsFile>
    private let tags: any NFCTagSystem
    private let now: () -> Date
    private var deciding: Set<UUID> = []
    private var isRetryingEvents = false

    init(store: VersionedJSONFileStore<NFCActionsFile>,
         tags: any NFCTagSystem,
         sink: (any ConnectorEventSink)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.tags = tags
        self.sink = sink
        self.now = now
        restore()
    }

    /// Launch: pending runs of a previous process are restored as interrupted; stale ones dropped.
    private func restore() {
        let file: NFCActionsFile
        do {
            file = try store.load()
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
            return
        } catch {
            storageIssue = .writeFailed
            return
        }
        registrations = file.registrations
        executions = file.executions
        let date = now()
        pending = file.pending
            .filter { date.timeIntervalSince($0.openedAt) <= NFCPendingExecution.maxAge }
            .map { var run = $0; run.restored = true; return run }
        if pending != file.pending { persist() }
    }

    func registration(for actionID: UUID) -> NFCActionRegistration? {
        registrations.first { $0.actionID == actionID }
    }

    /// The link Shortcuts opens for this action: only the opaque ID.
    func shortcutLink(for actionID: UUID) -> URL {
        ConnectorURLRouter.url(for: .nfcAction(actionID))
    }

    func refreshCoreNFCStatus() async {
        coreNFCStatus = await tags.status()
    }

    // MARK: Registration (from an action draft)

    func performActionDraft(_ draft: ActionDraft) async -> ActionDraftHandlerResult {
        guard case .nfcAction(let payload) = draft.payload else { return .notPerformed }
        if registration(for: payload.actionID) != nil { return .completed(resultRef: payload.actionID) }
        guard registrations.count < NFCActionsFile.maxRegistrations else { return .notPerformed }
        let created = WholeSeconds.floor(now())
        registrations.insert(NFCActionRegistration(actionID: payload.actionID, label: payload.label, createdAt: created,
                                                   expiresAt: created.addingTimeInterval(NFCActionRegistration.lifetime),
                                                   enabled: true, sourceDraftID: draft.draftID), at: 0)
        guard persist() else {
            registrations.removeAll { $0.actionID == payload.actionID }
            return .notPerformed
        }
        return .completed(resultRef: payload.actionID)
    }

    func setEnabled(_ enabled: Bool, actionID: UUID) {
        guard let index = registrations.firstIndex(where: { $0.actionID == actionID }) else { return }
        registrations[index].enabled = enabled
        if !enabled { pending.removeAll { $0.actionID == actionID } }
        persist()
    }

    /// Local removal (after the user confirmed). Katana keeps its own registry.
    func remove(actionID: UUID) {
        registrations.removeAll { $0.actionID == actionID }
        pending.removeAll { $0.actionID == actionID }
        previews[actionID] = nil
        persist()
    }

    // MARK: Trigger → preview

    /// Opens the preview for a trigger. Creates no event and touches no network. A second
    /// trigger within `reuseWindow` shows the same run.
    func open(actionID: UUID, source: NFCActionSource) {
        let date = now()
        guard let registration = registration(for: actionID) else {
            previews[actionID] = .unknown
            return
        }
        guard registration.enabled else {
            previews[actionID] = .disabled
            return
        }
        guard !registration.isExpired(at: date) else {
            previews[actionID] = .expired
            return
        }
        if let existing = pending.first(where: { $0.actionID == actionID }),
           date.timeIntervalSince(existing.openedAt) <= NFCPendingExecution.reuseWindow || existing.restored {
            previews[actionID] = .ready(existing)
            return
        }
        pending.removeAll { $0.actionID == actionID }
        let run = NFCPendingExecution(executionID: UUID(), actionID: actionID, source: source, openedAt: date, restored: false)
        pending.append(run)
        persist()
        previews[actionID] = .ready(run)
    }

    /// «Выполнить» / «Отклонить». One event per run, also on double taps.
    func decide(actionID: UUID, result: NFCActionResult) async {
        guard case .ready(let run)? = previews[actionID], !deciding.contains(run.executionID),
              let registration = registration(for: actionID), registration.enabled, !registration.isExpired(at: now()) else { return }
        deciding.insert(run.executionID)
        defer { deciding.remove(run.executionID) }
        let execution = NFCCompletedExecution(executionID: run.executionID, actionID: actionID, eventID: UUID(),
                                              source: run.source, confirmedAt: WholeSeconds.floor(now()), result: result,
                                              interrupted: run.restored, eventSaved: false)
        pending.removeAll { $0.executionID == run.executionID }
        executions.insert(execution, at: 0)
        if executions.count > NFCActionsFile.maxExecutions {
            executions.removeLast(executions.count - NFCActionsFile.maxExecutions)
        }
        persist()
        previews[actionID] = .done(execution)
        await saveEvent(of: execution.executionID)
    }

    // MARK: Native Core NFC (gated)

    /// «Сканировать метку». Only when Core NFC is available; cancelling the system sheet is normal.
    func scanTag() async {
        guard scanState != .scanning, scanState != .writing else { return }
        coreNFCStatus = await tags.status()
        guard coreNFCStatus == .available else { return }
        scanState = .scanning
        do {
            switch try await tags.readActionLink() {
            case .actionLink(let url):
                if case .openDestination(.nfcAction(let actionID))? = try? ConnectorURLRouter.parse(url) {
                    open(actionID: actionID, source: .coreNFC)
                    scanState = .found(actionID)
                } else {
                    scanState = .notKatana
                }
            case .notKatana:
                scanState = .notKatana
            case .empty:
                scanState = .empty
            }
        } catch NFCTagError.cancelled {
            scanState = .cancelled
        } catch let error as NFCTagError {
            scanState = .failed(error)
        } catch {
            scanState = .failed(.systemError)
        }
    }

    /// «Записать на метку» — only after the user confirmed the preview of what is written.
    /// Writes the opaque v3 link; never locks the tag.
    func writeTag(actionID: UUID) async {
        guard scanState != .scanning, scanState != .writing,
              let registration = registration(for: actionID), registration.enabled else { return }
        coreNFCStatus = await tags.status()
        guard coreNFCStatus == .available else { return }
        scanState = .writing
        do {
            try await tags.writeActionLink(shortcutLink(for: actionID))
            scanState = .written
        } catch NFCTagError.cancelled {
            scanState = .cancelled
        } catch let error as NFCTagError {
            scanState = .failed(error)
        } catch {
            scanState = .failed(.systemError)
        }
    }

    // MARK: Events

    func retryPendingEvents() async {
        guard !isRetryingEvents else { return }
        isRetryingEvents = true
        defer { isRetryingEvents = false }
        for execution in executions.reversed() where !execution.eventSaved {
            await saveEvent(of: execution.executionID)
        }
    }

    private func saveEvent(of executionID: UUID) async {
        guard let sink, let execution = executions.first(where: { $0.executionID == executionID }), !execution.eventSaved,
              let event = try? execution.makeEvent() else { return }
        guard await sink.enqueueEvent(event) == .saved,
              let index = executions.firstIndex(where: { $0.executionID == executionID }) else { return }
        executions[index].eventSaved = true
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(NFCActionsFile(registrations: registrations, pending: pending, executions: executions))
            if storageIssue == .writeFailed { storageIssue = nil }
            return true
        } catch {
            storageIssue = .writeFailed
            return false
        }
    }
}
