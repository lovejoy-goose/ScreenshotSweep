import Combine
import Foundation

enum CleanupEnqueueOutcome: Equatable, Sendable {
    /// Persisted in the queue of the current connection.
    case saved
    /// No Katana connection: nothing is recorded.
    case notPaired
    /// The queue could not store the event.
    case failed
}

/// Where completed cleanup events go (the event delivery coordinator).
@MainActor
protocol CleanupEventSink: AnyObject {
    func enqueueCleanupEvent(_ event: ConnectorEvent) async -> CleanupEnqueueOutcome
}

/// Tracks the current Screenshot Cleanup session and turns an explicit completion into
/// exactly one `screenshot_cleanup.completed` event. Has no access to the photo library:
/// it only receives notifications about decisions and successful deletions.
@MainActor
final class CleanupSessionRecorder: ObservableObject {
    struct Completion: Equatable {
        let summary: CleanupSessionSummary
        /// Internal only; never shown in UI.
        let eventID: UUID?
        let outcome: CleanupEnqueueOutcome
    }

    @Published private(set) var tracker = CleanupSessionTracker()
    @Published private(set) var lastCompletion: Completion?
    @Published private(set) var isCompleting = false

    weak var sink: (any CleanupEventSink)?
    private let now: () -> Date

    init(sink: (any CleanupEventSink)? = nil, now: @escaping () -> Date = { Date() }) {
        self.sink = sink
        self.now = now
    }

    var canComplete: Bool { tracker.hasActivity && !isCompleting }

    // MARK: Notifications from SweepStore

    func recordDecision(_ decision: CleanupSessionTracker.Decision, assetID: String) {
        tracker.record(decision, assetID: assetID, at: now())
    }

    func undo(assetID: String) {
        tracker.undo(assetID: assetID)
    }

    func change(assetID: String, to decision: CleanupSessionTracker.Decision) {
        tracker.change(assetID: assetID, to: decision)
    }

    func willDelete(assetIDs: [String]) {
        tracker.beginDeletion(assetIDs: assetIDs)
    }

    func didFinishDeletion(assetIDs: [String], success: Bool) {
        tracker.finishDeletion(assetIDs: assetIDs, success: success)
    }

    func libraryChanged(existing assetIDs: Set<String>) {
        tracker.retainOnly(existing: assetIDs)
    }

    // MARK: Completion

    /// What would be sent if the user completed now. Creates nothing.
    func previewSummary() -> CleanupSessionSummary? {
        tracker.summary(completedAt: now())
    }

    /// Explicit completion by the user. The session is closed before anything is awaited,
    /// so a second tap cannot complete it twice; the event is persisted before any flush.
    @discardableResult
    func complete() async -> Completion? {
        guard !isCompleting, let summary = tracker.summary(completedAt: now()) else { return nil }
        isCompleting = true
        tracker = CleanupSessionTracker()
        defer { isCompleting = false }

        guard let event = try? summary.makeEvent() else {
            let completion = Completion(summary: summary, eventID: nil, outcome: .failed)
            lastCompletion = completion
            return completion
        }
        let outcome = await sink?.enqueueCleanupEvent(event) ?? .notPaired
        let completion = Completion(summary: summary, eventID: outcome == .saved ? event.eventID : nil, outcome: outcome)
        lastCompletion = completion
        return completion
    }
}
