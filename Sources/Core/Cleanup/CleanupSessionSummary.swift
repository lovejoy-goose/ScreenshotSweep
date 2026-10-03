import Foundation

/// Private aggregate of one Screenshot Cleanup session — the only cleanup data sent to Katana.
/// Contains no images, asset identifiers, file names, per-photo dates, locations,
/// thumbnails or action history.
struct CleanupSessionSummary: Codable, Equatable, Sendable {
    static let eventType = "screenshot_cleanup.completed"

    let sessionID: UUID
    let startedAt: Date
    let completedAt: Date
    /// Screenshots decided in this session (kept + marked for deletion).
    let reviewedCount: Int
    let keptCount: Int
    /// Screenshots the user marked for deletion in this session.
    let deletionRequestedCount: Int
    /// Every screenshot marked for deletion was actually deleted (after both confirmations).
    let deletionCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case reviewedCount = "reviewed_count"
        case keptCount = "kept_count"
        case deletionRequestedCount = "deletion_requested_count"
        case deletionCompleted = "deletion_completed"
    }

    /// Counters are consistent; summaries that fail this are never sent.
    var isValid: Bool {
        reviewedCount > 0 && keptCount >= 0 && deletionRequestedCount >= 0
            && reviewedCount == keptCount + deletionRequestedCount
            && startedAt <= completedAt
            && (deletionRequestedCount > 0 || deletionCompleted)
    }

    /// The `screenshot_cleanup.completed` event. `session_id` doubles as the envelope session.
    func makeEvent(eventID: UUID = UUID()) throws -> ConnectorEvent {
        let payload = try ConnectorJSON.makeDecoder().decode(JSONValue.self, from: ConnectorJSON.makeEncoder().encode(self))
        return ConnectorEvent(eventID: eventID, type: Self.eventType, occurredAt: completedAt,
                              sessionID: sessionID, payload: payload)
    }

    // UUIDs are sent in lowercase, like the event envelope.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(reviewedCount, forKey: .reviewedCount)
        try container.encode(keptCount, forKey: .keptCount)
        try container.encode(deletionRequestedCount, forKey: .deletionRequestedCount)
        try container.encode(deletionCompleted, forKey: .deletionCompleted)
    }
}

/// In-memory bookkeeping of the current session. Local asset identifiers live only here,
/// only in memory, and never leave this type; the summary contains counts only.
struct CleanupSessionTracker: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case keep
        case delete
    }

    private(set) var sessionID = UUID()
    private(set) var startedAt: Date?
    private var decisions: [String: Decision] = [:]
    /// Marked for deletion and currently in a PhotoKit deletion request.
    private var deleting: Set<String> = []
    /// Screenshots of this session that were marked for deletion and actually deleted.
    private(set) var deletedCount = 0

    var hasActivity: Bool { startedAt != nil && reviewedCount > 0 }
    var keptCount: Int { decisions.values.filter { $0 == .keep }.count }
    /// Marked for deletion but not deleted (yet).
    var pendingDeletionCount: Int { decisions.values.filter { $0 == .delete }.count + deleting.count }
    var reviewedCount: Int { decisions.count + deleting.count + deletedCount }

    mutating func record(_ decision: Decision, assetID: String, at date: Date) {
        if startedAt == nil { startedAt = date }
        decisions[assetID] = decision
    }

    mutating func undo(assetID: String) {
        decisions[assetID] = nil
    }

    /// Changes a decision made in this session (review screen toggle).
    mutating func change(assetID: String, to decision: Decision) {
        guard decisions[assetID] != nil else { return }
        decisions[assetID] = decision
    }

    /// Called right before a PhotoKit deletion request. The library may report the change
    /// before the request completes, so these are protected from `retainOnly`.
    mutating func beginDeletion(assetIDs: [String]) {
        for id in assetIDs where decisions[id] == .delete {
            decisions[id] = nil
            deleting.insert(id)
        }
    }

    /// Called when the PhotoKit request finished. On failure or cancellation the screenshots
    /// are marked for deletion again.
    mutating func finishDeletion(assetIDs: [String], success: Bool) {
        for id in assetIDs where deleting.contains(id) {
            deleting.remove(id)
            if success {
                deletedCount += 1
            } else {
                decisions[id] = .delete
            }
        }
    }

    /// Drops decisions for screenshots that disappeared from the library outside the app;
    /// their fate is unknown, so they are not counted.
    mutating func retainOnly(existing assetIDs: Set<String>) {
        decisions = decisions.filter { assetIDs.contains($0.key) }
    }

    func summary(completedAt: Date) -> CleanupSessionSummary? {
        guard let startedAt else { return nil }
        let pending = pendingDeletionCount
        let summary = CleanupSessionSummary(sessionID: sessionID, startedAt: startedAt, completedAt: completedAt,
                                            reviewedCount: reviewedCount, keptCount: keptCount,
                                            deletionRequestedCount: deletedCount + pending,
                                            deletionCompleted: pending == 0)
        return summary.isValid ? summary : nil
    }
}

// Asset identifiers are never shown in descriptions either.
extension CleanupSessionTracker: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "CleanupSessionTracker(reviewed: \(reviewedCount), kept: \(keptCount), deleted: \(deletedCount))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["reviewedCount": reviewedCount, "keptCount": keptCount, "deletedCount": deletedCount],
               displayStyle: .struct)
    }
}
