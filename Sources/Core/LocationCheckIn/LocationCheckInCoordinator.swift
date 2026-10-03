import Combine
import Foundation

/// Location Check-in (D-040): one When In Use fix by button → preview → precision choice →
/// explicit confirmation → one event. Coordinates live only in memory until then and are
/// cleared right after the event was saved; the local history never contains them.
@MainActor
final class LocationCheckInCoordinator: ObservableObject {
    enum Failure: Equatable, Sendable {
        case servicesDisabled
        case permissionDenied
        case permissionRestricted
        case timedOut
        case systemError
        /// The preview was older than `CheckInPreview.lifetime`; its coordinates were dropped.
        case previewExpired
        case notPaired
        case saveFailed
    }

    enum Phase: Equatable, Sendable {
        case idle
        case locating
        /// Coordinates shown; waits for precision choice and confirmation.
        case preview
        case sending
        case saved(CheckInHistoryEntry)
        case failed(Failure)
    }

    enum StorageIssue: Equatable, Sendable {
        case quarantined
        case writeFailed
    }

    static let fixTimeout: TimeInterval = 20

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: CheckInPreview?
    @Published var precision: CheckInPrecision = .approximate
    @Published var labelRequested = true
    @Published private(set) var history: [CheckInHistoryEntry] = []
    @Published private(set) var storageIssue: StorageIssue?

    weak var sink: (any ConnectorEventSink)?

    private let store: VersionedJSONFileStore<CheckInHistoryFile>
    private let system: any CheckInLocationSystem
    private let sleeper: any DeliverySleeper
    private let now: () -> Date

    init(store: VersionedJSONFileStore<CheckInHistoryFile>,
         system: any CheckInLocationSystem,
         sink: (any ConnectorEventSink)? = nil,
         sleeper: any DeliverySleeper = TaskSleeper(),
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.system = system
        self.sink = sink
        self.sleeper = sleeper
        self.now = now
        do {
            history = try store.load().history
        } catch VersionedFileStoreError.quarantined(_) {
            storageIssue = .quarantined
        } catch {
            storageIssue = .writeFailed
        }
    }

    // MARK: Locate

    /// «Определить текущее место». The prompt (When In Use only) appears only here.
    func locate() async {
        guard phase != .locating, phase != .sending else { return }
        preview = nil
        phase = .locating
        if let failure = await authorize() {
            phase = .failed(failure)
            return
        }
        let system = self.system
        let sleeper = self.sleeper
        let timeout = Self.fixTimeout
        do {
            let fix = try await withThrowingTaskGroup(of: LocationFix?.self) { group -> LocationFix? in
                group.addTask { try await system.currentFix() }
                group.addTask {
                    try await sleeper.sleep(seconds: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let fix else {
                phase = .failed(.timedOut)
                return
            }
            preview = CheckInPreview(fix: fix, receivedAt: now())
            phase = .preview
        } catch CapabilityProbeError.permissionDenied {
            phase = .failed(.permissionDenied)
        } catch {
            phase = .failed(.systemError)
        }
    }

    private func authorize() async -> Failure? {
        guard await system.servicesEnabled() else { return .servicesDisabled }
        var permission = await system.permission()
        if permission == .notDetermined {
            permission = await system.requestWhenInUseAuthorization()
        }
        switch permission {
        case .authorizedWhenInUse, .authorizedAlways: return nil
        case .denied: return .permissionDenied
        case .restricted: return .permissionRestricted
        case .notDetermined, .unknown: return .systemError
        }
    }

    // MARK: Send / cancel

    /// Called only after the user confirmed «Отправить координаты в Katana?». Retries after
    /// `notPaired` or a queue error reuse the same check-in and event IDs.
    func send() async {
        guard let preview else { return }
        switch phase {
        case .preview, .failed(.notPaired), .failed(.saveFailed): break
        default: return
        }
        guard !preview.isExpired(at: now()) else {
            clearPreview()
            phase = .failed(.previewExpired)
            return
        }
        let precision = self.precision
        let labelRequested = self.labelRequested
        phase = .sending
        guard let event = try? preview.makeEvent(precision: precision, labelRequested: labelRequested) else {
            phase = .failed(.saveFailed)
            return
        }
        let outcome: EventEnqueueOutcome
        if let sink {
            outcome = await sink.enqueueEvent(event)
        } else {
            outcome = .notPaired
        }
        switch outcome {
        case .saved:
            // The coordinates are now only in the queued event; drop them from state and UI.
            clearPreview()
            let entry = CheckInHistoryEntry(checkInID: preview.checkInID, eventID: preview.eventID,
                                            occurredAt: preview.occurredAt, precision: precision,
                                            accuracyBucket: preview.accuracyBucket, labelRequested: labelRequested)
            history.insert(entry, at: 0)
            if history.count > CheckInHistoryFile.maxHistory {
                history.removeLast(history.count - CheckInHistoryFile.maxHistory)
            }
            persist()
            phase = .saved(entry)
        case .notPaired:
            phase = .failed(.notPaired)
        case .failed:
            phase = .failed(.saveFailed)
        }
    }

    /// «Отмена»: nothing is created and the coordinates are dropped.
    func cancel() {
        guard phase != .sending else { return }
        clearPreview()
        phase = .idle
    }

    /// Leaving the screen or the app going to the background: an unconfirmed fix is not kept.
    func discardPreview() {
        guard preview != nil, phase != .sending else { return }
        clearPreview()
        phase = .idle
    }

    private func clearPreview() {
        preview = nil
    }

    private func persist() {
        do {
            try store.save(CheckInHistoryFile(history: history))
            if storageIssue == .writeFailed { storageIssue = nil }
        } catch {
            storageIssue = .writeFailed
        }
    }
}
