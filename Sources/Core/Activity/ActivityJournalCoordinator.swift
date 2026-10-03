import Combine
import Foundation

/// Activity Journal (D-039): «Определить текущую активность» and manual sessions. Motion is
/// touched only after the user's button; a session is observed only while the app is active.
/// Events go to Katana only after explicit confirmation, through the existing queue.
@MainActor
final class ActivityJournalCoordinator: ObservableObject {
    enum Failure: Equatable, Sendable {
        case unsupported
        case permissionDenied
        case permissionRestricted
        case timedOut
        case systemError
        /// The session could not be saved on this iPhone.
        case storage
        /// Katana is not connected: nothing was recorded for it.
        case notPaired
        /// The queue could not store the event.
        case saveFailed
    }

    enum SnapshotPhase: Equatable, Sendable {
        case idle
        case checking
        /// Result shown; waits for «Отправить в Katana».
        case preview
        case sending
        case saved
        case failed(Failure)
    }

    enum StorageIssue: Equatable, Sendable {
        /// The journal file was unreadable; it was kept aside and the journal restarted.
        case quarantined
        case writeFailed
    }

    static let snapshotTimeout: TimeInterval = 15

    @Published private(set) var snapshot: ActivitySnapshot?
    @Published private(set) var snapshotPhase: SnapshotPhase = .idle
    @Published private(set) var session: ActivitySession?
    @Published private(set) var sessionFailure: Failure?
    @Published private(set) var isStartingSession = false
    @Published private(set) var isSendingSession = false
    /// True only while Motion updates are running for the session (app in foreground).
    @Published private(set) var isObserving = false
    @Published private(set) var history: [ActivityHistoryEntry] = []
    @Published private(set) var storageIssue: StorageIssue?

    weak var sink: (any ConnectorEventSink)?

    private let store: VersionedJSONFileStore<ActivityJournalFile>
    private let system: any ActivitySystem
    private let sleeper: any DeliverySleeper
    private let now: () -> Date
    private var appIsActive = true
    /// Incremented whenever observation stops, so late readings of an old observation are ignored.
    private var observationGeneration = 0

    init(store: VersionedJSONFileStore<ActivityJournalFile>,
         system: any ActivitySystem,
         sink: (any ConnectorEventSink)? = nil,
         sleeper: any DeliverySleeper = TaskSleeper(),
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.system = system
        self.sink = sink
        self.sleeper = sleeper
        self.now = now
        restore()
    }

    /// Launch: a session that was still active belongs to a process that ended → interrupted.
    private func restore() {
        var file: ActivityJournalFile
        do {
            file = try store.load()
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
            file = .empty
        } catch {
            storageIssue = .writeFailed
            file = .empty
        }
        if var restored = file.session, restored.phase == .active {
            restored.markInterrupted()
            file.session = restored
            session = restored
            history = file.history
            persist()
            return
        }
        session = file.session
        history = file.history
    }

    // MARK: Permission

    private func authorize() async -> Failure? {
        guard await system.isActivityAvailable() else { return .unsupported }
        var permission = await system.permission()
        // The prompt appears only here, right after the user's button, and only once.
        if permission == .notDetermined {
            permission = await system.requestAuthorization()
        }
        switch permission {
        case .authorized: return nil
        case .denied: return .permissionDenied
        case .restricted: return .permissionRestricted
        case .notDetermined, .unknown: return .systemError
        }
    }

    // MARK: Snapshot

    /// «Определить текущую активность». Creates nothing for Katana.
    func checkCurrentActivity() async {
        guard snapshotPhase != .checking, snapshotPhase != .sending else { return }
        snapshotPhase = .checking
        snapshot = nil
        if let failure = await authorize() {
            snapshotPhase = .failed(failure)
            return
        }
        let system = self.system
        let sleeper = self.sleeper
        let timeout = Self.snapshotTimeout
        do {
            let reading = try await withThrowingTaskGroup(of: MotionActivityReading?.self) { group -> MotionActivityReading? in
                group.addTask { try await system.currentReading() }
                group.addTask {
                    try await sleeper.sleep(seconds: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let reading else {
                snapshotPhase = .failed(.timedOut)
                return
            }
            snapshot = ActivitySnapshot(snapshotID: UUID(), eventID: UUID(),
                                        activity: ActivityClassifier.category(for: reading),
                                        confidence: reading.confidence, checkedAt: WholeSeconds.floor(now()))
            snapshotPhase = .preview
        } catch CapabilityProbeError.permissionDenied {
            snapshotPhase = .failed(.permissionDenied)
        } catch CapabilityProbeError.unavailable {
            snapshotPhase = .failed(.unsupported)
        } catch {
            snapshotPhase = .failed(.systemError)
        }
    }

    /// «Отправить в Katana» for the shown result. Retries reuse the same event ID.
    func sendSnapshot() async {
        guard let snapshot else { return }
        switch snapshotPhase {
        case .preview, .failed(.notPaired), .failed(.saveFailed): break
        default: return
        }
        snapshotPhase = .sending
        guard let event = try? snapshot.makeEvent() else {
            snapshotPhase = .failed(.saveFailed)
            return
        }
        switch await enqueue(event) {
        case .saved:
            record(ActivityHistoryEntry(id: snapshot.snapshotID, kind: .snapshot, eventID: snapshot.eventID,
                                        recordedAt: snapshot.checkedAt, activity: snapshot.activity,
                                        confidence: snapshot.confidence, durationSeconds: nil, interrupted: false))
            snapshotPhase = .saved
        case .notPaired:
            snapshotPhase = .failed(.notPaired)
        case .failed:
            snapshotPhase = .failed(.saveFailed)
        }
    }

    func discardSnapshot() {
        guard snapshotPhase != .sending, snapshotPhase != .checking else { return }
        snapshot = nil
        snapshotPhase = .idle
    }

    // MARK: Session

    /// «Начать сессию».
    func startSession() async {
        guard session == nil, !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }
        sessionFailure = nil
        if let failure = await authorize() {
            sessionFailure = failure
            return
        }
        guard session == nil else { return }
        let previous = session
        session = ActivitySession(startedAt: now())
        guard persist() else {
            session = previous
            sessionFailure = .storage
            return
        }
        await startObserving()
    }

    /// «Завершить»: stops observing and freezes the summary for the preview. A second tap does nothing.
    func finishSession() async {
        guard var current = session, current.phase != .awaitingConfirmation else { return }
        await stopObserving()
        guard current.finish(at: now(), eventID: UUID()) != nil else {
            sessionFailure = .systemError
            return
        }
        session = current
        sessionFailure = nil
        persist()
    }

    /// «Отправить в Katana» on the preview. The event ID was fixed by «Завершить».
    func confirmSession() async {
        guard !isSendingSession, let current = session, current.phase == .awaitingConfirmation,
              let summary = current.summary, let eventID = current.eventID else { return }
        isSendingSession = true
        defer { isSendingSession = false }
        guard let event = try? summary.makeEvent(eventID: eventID) else {
            sessionFailure = .saveFailed
            return
        }
        switch await enqueue(event) {
        case .saved:
            session = nil
            sessionFailure = nil
            record(ActivityHistoryEntry(id: summary.sessionID, kind: .session, eventID: eventID,
                                        recordedAt: summary.completedAt, activity: summary.dominantActivity,
                                        confidence: nil, durationSeconds: summary.durationSeconds,
                                        interrupted: summary.interrupted))
        case .notPaired:
            sessionFailure = .notPaired
        case .failed:
            sessionFailure = .saveFailed
        }
    }

    /// «Удалить без отправки» (active, interrupted or awaiting confirmation). No event.
    func deleteSession() async {
        guard session != nil, !isSendingSession else { return }
        await stopObserving()
        session = nil
        sessionFailure = nil
        persist()
    }

    // MARK: Lifecycle

    /// iOS does not let the app observe in the background: that time counts as `unknown`.
    func appDidEnterBackground() async {
        appIsActive = false
        await stopObserving()
        guard var current = session, current.phase == .active else { return }
        current.suspend(at: now())
        session = current
        persist()
    }

    func appDidBecomeActive() async {
        appIsActive = true
        await startObserving()
    }

    private func startObserving() async {
        guard appIsActive, !isObserving, session?.phase == .active else { return }
        isObserving = true
        observationGeneration += 1
        let generation = observationGeneration
        await system.startUpdates { [weak self] reading in
            Task { @MainActor in self?.receive(reading, generation: generation) }
        }
    }

    private func stopObserving() async {
        guard isObserving else { return }
        isObserving = false
        observationGeneration += 1
        await system.stopUpdates()
    }

    /// Only the category and the time of arrival are used; the reading itself is dropped here.
    private func receive(_ reading: MotionActivityReading, generation: Int) {
        guard isObserving, generation == observationGeneration,
              var current = session, current.phase == .active else { return }
        current.observe(ActivityClassifier.category(for: reading), at: now())
        session = current
        persist()
    }

    // MARK: Helpers

    private func enqueue(_ event: ConnectorEvent) async -> EventEnqueueOutcome {
        guard let sink else { return .notPaired }
        return await sink.enqueueEvent(event)
    }

    private func record(_ entry: ActivityHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > ActivityJournalFile.maxHistory {
            history.removeLast(history.count - ActivityJournalFile.maxHistory)
        }
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(ActivityJournalFile(session: session, history: history))
            if storageIssue == .writeFailed { storageIssue = nil }
            return true
        } catch {
            storageIssue = .writeFailed
            return false
        }
    }
}
