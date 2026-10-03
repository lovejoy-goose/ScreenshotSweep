import Combine
import Foundation

/// Local reminders from Katana drafts (D-041). A link only opens the draft screen; the draft is
/// loaded by «Загрузить напоминание», the notification is created by «Создать напоминание» —
/// only then is the notification permission requested. One draft → at most one reminder.
@MainActor
final class ReminderCoordinator: ObservableObject {
    enum Failure: Equatable, Sendable {
        case notPaired
        case requiresRepair
        case notFound
        case expired
        case consumed
        case alreadyDue
        /// Retryable by button: offline, rate limited or server error.
        case unavailable
        case invalidResponse
        case permissionDenied
        case scheduleFailed
        case storage
    }

    enum DraftPhase: Equatable, Sendable {
        /// Opened (e.g. by a link); nothing loaded yet.
        case idle
        case loading
        /// Shown to the user; waits for «Создать напоминание».
        case loaded
        case scheduling
        case scheduled
        case failed(Failure)
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined
        case writeFailed
    }

    @Published private(set) var reminders: [ReminderRecord] = []
    @Published private(set) var storageIssue: StorageIssue?
    /// In memory only; dropped once the reminder exists (its text then lives in the record).
    @Published private(set) var drafts: [UUID: ReminderDraft] = [:]
    @Published private(set) var phases: [UUID: DraftPhase] = [:]
    @Published private(set) var cancelling: Set<UUID> = []

    weak var sink: (any ConnectorEventSink)?

    private let store: VersionedJSONFileStore<ReminderStoreFile>
    private let fetcher: any ReminderDraftFetching
    private let notifications: any ReminderNotificationSystem
    private let now: () -> Date
    private var isRetryingEvents = false

    init(store: VersionedJSONFileStore<ReminderStoreFile>,
         fetcher: any ReminderDraftFetching,
         notifications: any ReminderNotificationSystem,
         sink: (any ConnectorEventSink)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.fetcher = fetcher
        self.notifications = notifications
        self.sink = sink
        self.now = now
        do {
            reminders = try store.load().reminders
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
        } catch {
            storageIssue = .writeFailed
        }
    }

    func record(for draftID: UUID) -> ReminderRecord? {
        reminders.first { $0.draftID == draftID }
    }

    /// An existing reminder always wins: reopening the link shows it, without network.
    func phase(for draftID: UUID) -> DraftPhase {
        if let phase = phases[draftID], phase != .idle { return phase }
        return record(for: draftID) == nil ? .idle : .scheduled
    }

    // MARK: Draft

    /// «Загрузить напоминание». Never called by a link. No automatic retries.
    func loadDraft(_ draftID: UUID) async {
        guard record(for: draftID) == nil else {
            phases[draftID] = .scheduled
            return
        }
        switch phase(for: draftID) {
        case .loading, .scheduling, .scheduled: return
        case .idle, .loaded, .failed: break
        }
        phases[draftID] = .loading
        do {
            drafts[draftID] = try await fetcher.fetchReminderDraft(id: draftID)
            phases[draftID] = .loaded
        } catch let error as ReminderDraftError {
            drafts[draftID] = nil
            if error == .unauthorized { sink?.reportUnauthorized() }
            phases[draftID] = .failed(Self.failure(for: error))
        } catch {
            drafts[draftID] = nil
            phases[draftID] = .failed(.invalidResponse)
        }
    }

    /// «Создать напоминание». Permission is requested here and only here. A second tap or a
    /// second call for the same draft never creates a second reminder.
    func createReminder(_ draftID: UUID) async {
        // A draft is kept only while it can still be scheduled (loaded, or a retryable creation failure).
        guard record(for: draftID) == nil, let draft = drafts[draftID] else { return }
        switch phase(for: draftID) {
        case .loaded, .failed: break
        case .idle, .loading, .scheduling, .scheduled: return
        }
        phases[draftID] = .scheduling

        let date = now()
        guard draft.expiresAt > date else { return fail(draftID, .expired, dropDraft: true) }
        guard draft.fireAt > date else { return fail(draftID, .alreadyDue, dropDraft: true) }

        var permission = await notifications.permission()
        if permission == .notDetermined {
            permission = await notifications.requestAuthorization()
        }
        let authorization: ReminderAuthorization
        switch permission {
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        case .ephemeral: authorization = .ephemeral
        case .denied, .notDetermined, .unknown: return fail(draftID, .permissionDenied, dropDraft: false)
        }

        let identifier = ReminderNotificationID.make(draftID: draftID)
        do {
            // Same identifier for the same draft: even a repeated request replaces, never duplicates.
            try await notifications.schedule(ReminderNotificationRequest(identifier: identifier, title: draft.title,
                                                                         body: draft.body, fireAt: draft.fireAt))
        } catch {
            return fail(draftID, .scheduleFailed, dropDraft: false)
        }
        guard record(for: draftID) == nil else {
            phases[draftID] = .scheduled
            return
        }
        let record = ReminderRecord(draftID: draftID, notificationID: identifier, title: draft.title, body: draft.body,
                                    fireAt: draft.fireAt, createdAt: WholeSeconds.floor(now()), authorization: authorization,
                                    status: .scheduled, cancelledAt: nil, scheduledEventID: UUID(),
                                    scheduledEventSaved: false, cancelledEventID: nil, cancelledEventSaved: false)
        reminders.insert(record, at: 0)
        guard persist() else {
            // Not remembered → do not leave an untracked notification behind.
            reminders.removeAll { $0.draftID == draftID }
            await notifications.removePending(identifier: identifier)
            return fail(draftID, .storage, dropDraft: false)
        }
        trimHistory()
        drafts[draftID] = nil
        phases[draftID] = .scheduled
        await saveEvents(of: draftID)
    }

    // MARK: Cancel

    /// «Отменить напоминание» (after the user confirmed). Removes only this reminder's notification.
    func cancelReminder(_ draftID: UUID) async {
        guard let current = record(for: draftID), current.status == .scheduled, !current.isDue(at: now()),
              !cancelling.contains(draftID) else { return }
        cancelling.insert(draftID)
        defer { cancelling.remove(draftID) }
        await notifications.removePending(identifier: current.notificationID)
        update(draftID) {
            $0.status = .cancelled
            $0.cancelledAt = WholeSeconds.floor(now())
            $0.cancelledEventID = UUID()
            $0.cancelledEventSaved = false
        }
        persist()
        await saveEvents(of: draftID)
    }

    // MARK: Events

    /// Saves events that are not yet in the queue (e.g. created while offline from storage
    /// errors or before pairing), always with their original event IDs.
    func retryPendingEvents() async {
        guard !isRetryingEvents else { return }
        isRetryingEvents = true
        defer { isRetryingEvents = false }
        for record in reminders where !record.scheduledEventSaved || (record.status == .cancelled && !record.cancelledEventSaved) {
            await saveEvents(of: record.draftID)
        }
    }

    /// Scheduled first, then cancelled — in that order, each at most once in the queue.
    private func saveEvents(of draftID: UUID) async {
        guard let sink else { return }
        if let current = record(for: draftID), !current.scheduledEventSaved, let event = try? current.makeScheduledEvent() {
            guard await sink.enqueueEvent(event) == .saved else { return }
            update(draftID) { $0.scheduledEventSaved = true }
            persist()
        }
        if let current = record(for: draftID), current.status == .cancelled, !current.cancelledEventSaved,
           let event = try? current.makeCancelledEvent() {
            guard await sink.enqueueEvent(event) == .saved else { return }
            update(draftID) { $0.cancelledEventSaved = true }
            persist()
        }
    }

    // MARK: Helpers

    private func fail(_ draftID: UUID, _ failure: Failure, dropDraft: Bool) {
        if dropDraft { drafts[draftID] = nil }
        phases[draftID] = .failed(failure)
    }

    private func update(_ draftID: UUID, _ change: (inout ReminderRecord) -> Void) {
        guard let index = reminders.firstIndex(where: { $0.draftID == draftID }) else { return }
        change(&reminders[index])
    }

    /// Keeps at most `maxReminders`, dropping the oldest finished (cancelled or due) ones first.
    private func trimHistory() {
        let date = now()
        while reminders.count > ReminderStoreFile.maxReminders,
              let index = reminders.lastIndex(where: { $0.status == .cancelled || $0.isDue(at: date) }) {
            reminders.remove(at: index)
        }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(ReminderStoreFile(reminders: reminders))
            if storageIssue == .writeFailed { storageIssue = nil }
            return true
        } catch {
            storageIssue = .writeFailed
            return false
        }
    }

    private static func failure(for error: ReminderDraftError) -> Failure {
        switch error {
        case .notPaired: return .notPaired
        case .unauthorized: return .requiresRepair
        case .notFound: return .notFound
        case .expired: return .expired
        case .consumed: return .consumed
        case .alreadyDue: return .alreadyDue
        case .offline, .rateLimited, .serverError: return .unavailable
        case .invalidResponse: return .invalidResponse
        }
    }
}
