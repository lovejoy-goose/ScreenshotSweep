import Combine
import Foundation

/// What a feature did with a confirmed action draft.
enum ActionDraftHandlerResult: Equatable, Sendable {
    /// Done; `resultRef` is the action, geofence or capture ID.
    case completed(resultRef: UUID)
    /// The feature continues on its own screen (capture) and reports back via `completeDeferred`.
    case continuing
    /// Nothing was done (permission refused, limit reached, …); the feature shows why.
    case notPerformed
}

/// A feature that can execute one kind of action draft after the user confirmed it.
@MainActor
protocol ActionDraftHandler: AnyObject {
    func performActionDraft(_ draft: ActionDraft) async -> ActionDraftHandlerResult
}

/// Action Drafts (D-047). A link only opens the draft screen; «Загрузить действие» fetches it,
/// «Выполнить» runs it once through the feature that owns the kind. A draft accepted on this
/// iPhone is never executed again; Katana consumes it atomically with `action_draft.accepted`.
@MainActor
final class ActionDraftCoordinator: ObservableObject {
    enum Failure: Equatable, Sendable {
        case notPaired
        case requiresRepair
        case notFound
        case expired
        case consumed
        /// Retryable by button: offline, rate limited or server error.
        case unavailable
        case invalidResponse
        /// This build cannot perform the kind (no feature registered).
        case unsupported
        /// The feature did not perform the action; it explains why on its own screen.
        case notPerformed
        case storage
    }

    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case performing
        /// The feature continues (capture); the draft is accepted when it reports back.
        case continuing
        case accepted
        case failed(Failure)
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined
        case writeFailed
    }

    @Published private(set) var drafts: [UUID: ActionDraft] = [:]
    @Published private(set) var phases: [UUID: Phase] = [:]
    @Published private(set) var accepted: [AcceptedActionDraft] = []
    @Published private(set) var storageIssue: StorageIssue?

    weak var sink: (any ConnectorEventSink)?

    private let store: VersionedJSONFileStore<ActionDraftStoreFile>
    private let fetcher: any ActionDraftFetching
    private let now: () -> Date
    private var handlers: [ActionDraftKind: WeakHandler] = [:]
    /// Device time of loading, to measure elapsed time for the server-clock TTL.
    private var loadedAt: [UUID: Date] = [:]
    private var isRetryingEvents = false

    private struct WeakHandler {
        weak var handler: (any ActionDraftHandler)?
    }

    init(store: VersionedJSONFileStore<ActionDraftStoreFile>,
         fetcher: any ActionDraftFetching,
         sink: (any ConnectorEventSink)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.fetcher = fetcher
        self.sink = sink
        self.now = now
        do {
            accepted = try store.load().accepted
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
        } catch {
            storageIssue = .writeFailed
        }
    }

    func register(_ handler: any ActionDraftHandler, for kind: ActionDraftKind) {
        handlers[kind] = WeakHandler(handler: handler)
    }

    func acceptedRecord(for draftID: UUID) -> AcceptedActionDraft? {
        accepted.first { $0.draftID == draftID }
    }

    /// An accepted draft always shows as accepted — without network.
    func phase(for draftID: UUID) -> Phase {
        if acceptedRecord(for: draftID) != nil { return .accepted }
        return phases[draftID] ?? .idle
    }

    // MARK: Load

    /// «Загрузить действие». Never called by a link; no automatic retries.
    func loadDraft(_ draftID: UUID) async {
        switch phase(for: draftID) {
        case .loading, .performing, .continuing, .accepted: return
        case .idle, .loaded, .failed: break
        }
        phases[draftID] = .loading
        do {
            let draft = try await fetcher.fetchActionDraft(id: draftID)
            drafts[draftID] = draft
            loadedAt[draftID] = now()
            phases[draftID] = .loaded
        } catch let error as ActionDraftError {
            drafts[draftID] = nil
            if error == .unauthorized { sink?.reportUnauthorized() }
            phases[draftID] = .failed(Self.failure(for: error))
        } catch {
            drafts[draftID] = nil
            phases[draftID] = .failed(.invalidResponse)
        }
    }

    // MARK: Perform

    /// «Выполнить» (after the preview). Runs at most once per draft.
    func perform(_ draftID: UUID) async {
        guard acceptedRecord(for: draftID) == nil, let draft = drafts[draftID] else { return }
        switch phase(for: draftID) {
        case .loaded, .failed(.notPerformed), .failed(.storage): break
        default: return
        }
        let elapsed = loadedAt[draftID].map { now().timeIntervalSince($0) } ?? 0
        guard !draft.isExpired(elapsedSinceLoad: elapsed) else {
            drafts[draftID] = nil
            phases[draftID] = .failed(.expired)
            return
        }
        guard let handler = handlers[draft.kind]?.handler else {
            phases[draftID] = .failed(.unsupported)
            return
        }
        phases[draftID] = .performing
        switch await handler.performActionDraft(draft) {
        case .completed(let resultRef):
            await recordAccepted(draftID: draft.draftID, kind: draft.kind, resultRef: resultRef)
        case .continuing:
            phases[draftID] = .continuing
        case .notPerformed:
            phases[draftID] = .failed(.notPerformed)
        }
    }

    /// Called by a feature that continued the draft on its own screen (capture) once its own
    /// event is saved — also after a relaunch, when the draft itself is no longer in memory.
    func completeDeferred(draftID: UUID, kind: ActionDraftKind, resultRef: UUID) async {
        guard acceptedRecord(for: draftID) == nil else { return }
        await recordAccepted(draftID: draftID, kind: kind, resultRef: resultRef)
    }

    /// The feature abandoned a continuing draft (e.g. the capture was cancelled): it can be performed again.
    func abandonDeferred(draftID: UUID) {
        guard phases[draftID] == .continuing else { return }
        phases[draftID] = .loaded
    }

    private func recordAccepted(draftID: UUID, kind: ActionDraftKind, resultRef: UUID) async {
        let record = AcceptedActionDraft(draftID: draftID, kind: kind, acceptedAt: WholeSeconds.floor(now()),
                                         resultRef: resultRef, eventID: UUID(), eventSaved: false)
        accepted.insert(record, at: 0)
        if accepted.count > ActionDraftStoreFile.maxAccepted {
            accepted.removeLast(accepted.count - ActionDraftStoreFile.maxAccepted)
        }
        guard persist() else {
            // The feature already acted; keep the record in memory so it is not repeated in this run.
            phases[draftID] = .accepted
            return
        }
        drafts[draftID] = nil
        phases[draftID] = .accepted
        await saveEvent(of: draftID)
    }

    // MARK: Events

    /// Saves `action_draft.accepted` events that are not yet in the queue, with their original IDs.
    func retryPendingEvents() async {
        guard !isRetryingEvents else { return }
        isRetryingEvents = true
        defer { isRetryingEvents = false }
        for record in accepted where !record.eventSaved {
            await saveEvent(of: record.draftID)
        }
    }

    private func saveEvent(of draftID: UUID) async {
        guard let sink, let record = acceptedRecord(for: draftID), !record.eventSaved,
              let event = try? record.makeEvent() else { return }
        guard await sink.enqueueEvent(event) == .saved,
              let index = accepted.firstIndex(where: { $0.draftID == draftID }) else { return }
        accepted[index].eventSaved = true
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(ActionDraftStoreFile(accepted: accepted))
            if storageIssue == .writeFailed { storageIssue = nil }
            return true
        } catch {
            storageIssue = .writeFailed
            return false
        }
    }

    private static func failure(for error: ActionDraftError) -> Failure {
        switch error {
        case .notPaired: return .notPaired
        case .unauthorized: return .requiresRepair
        case .notFound: return .notFound
        case .expired: return .expired
        case .consumed: return .consumed
        case .offline, .rateLimited, .serverError: return .unavailable
        case .invalidResponse: return .invalidResponse
        }
    }
}
