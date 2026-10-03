import Foundation

/// Activity category (D-039). Raw values are wire values and must never change.
enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    /// Deterministic rule for several flags at once and for ties: movement beats standing
    /// still (iOS reports `stationary` together with `automotive` in a stopped car).
    static let priority: [ActivityCategory] = [.automotive, .cycling, .running, .walking, .stationary, .unknown]
}

enum ActivityConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

/// One neutral activity reading from the system adapter: six flags and a confidence.
/// No timestamp, no history, no raw sample — nothing else ever leaves the adapter.
struct MotionActivityReading: Equatable, Sendable {
    var stationary = false
    var walking = false
    var running = false
    var cycling = false
    var automotive = false
    var unknown = false
    var confidence: ActivityConfidence = .low

    func isSet(_ category: ActivityCategory) -> Bool {
        switch category {
        case .stationary: return stationary
        case .walking: return walking
        case .running: return running
        case .cycling: return cycling
        case .automotive: return automotive
        case .unknown: return unknown
        }
    }
}

enum ActivityClassifier {
    /// The first set flag in `ActivityCategory.priority`; no flags → `unknown`.
    static func category(for reading: MotionActivityReading) -> ActivityCategory {
        ActivityCategory.priority.first { reading.isSet($0) } ?? .unknown
    }
}

/// Motion & Fitness adapter used by Activity Journal (implemented in Features, mocked in tests).
protocol ActivitySystem: Sendable {
    func isActivityAvailable() async -> Bool
    /// Reads the status without any prompt.
    func permission() async -> MotionPermission
    /// Shows the Motion & Fitness prompt (only called after the user's button, only if not requested yet).
    func requestAuthorization() async -> MotionPermission
    /// The current activity: one reading, updates stop right after it.
    func currentReading() async throws -> MotionActivityReading
    /// Updates while a manual session is observed in the foreground. `handler` may be called on any thread.
    func startUpdates(_ handler: @escaping @Sendable (MotionActivityReading) -> Void) async
    func stopUpdates() async
}

// MARK: - Snapshot

/// Result of «Определить текущую активность». `eventID` is fixed when the result is shown,
/// so «Отправить в Katana» retries reuse it.
struct ActivitySnapshot: Equatable, Sendable {
    let snapshotID: UUID
    let eventID: UUID
    let activity: ActivityCategory
    let confidence: ActivityConfidence
    let checkedAt: Date

    static let source = "motion_activity"

    private struct Payload: Encodable {
        let activity: ActivityCategory
        let confidence: ActivityConfidence
        let checkedAt: Date
        let source = ActivitySnapshot.source
        let interrupted = false

        enum CodingKeys: String, CodingKey {
            case activity, confidence, source, interrupted
            case checkedAt = "checked_at"
        }
    }

    /// `activity.snapshot.completed`; the envelope `session_id` is the snapshot ID.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.activitySnapshot, eventID: eventID, occurredAt: checkedAt, sessionID: snapshotID,
                                         payload: Payload(activity: activity, confidence: confidence, checkedAt: checkedAt))
    }
}

// MARK: - Session

/// Whole seconds per category.
struct ActivitySeconds: Codable, Equatable, Sendable {
    var stationary = 0
    var walking = 0
    var running = 0
    var cycling = 0
    var automotive = 0
    var unknown = 0

    subscript(category: ActivityCategory) -> Int {
        get {
            switch category {
            case .stationary: return stationary
            case .walking: return walking
            case .running: return running
            case .cycling: return cycling
            case .automotive: return automotive
            case .unknown: return unknown
            }
        }
        set {
            switch category {
            case .stationary: stationary = newValue
            case .walking: walking = newValue
            case .running: running = newValue
            case .cycling: cycling = newValue
            case .automotive: automotive = newValue
            case .unknown: unknown = newValue
            }
        }
    }

    var total: Int { ActivityCategory.allCases.reduce(0) { $0 + self[$1] } }

    /// Largest time; ties by `ActivityCategory.priority`; nothing at all → `unknown`.
    var dominant: ActivityCategory {
        guard total > 0 else { return .unknown }
        let best = ActivityCategory.allCases.map { self[$0] }.max() ?? 0
        return ActivityCategory.priority.first { self[$0] == best } ?? .unknown
    }
}

/// Aggregate of one manual session — the only session data sent to Katana. No time series,
/// no Motion samples, no coordinates.
struct ActivitySessionSummary: Codable, Equatable, Sendable {
    /// Documented server tolerance for the sum of categories; the client produces an exact sum.
    static let toleranceSeconds = 1

    let sessionID: UUID
    let startedAt: Date
    let completedAt: Date
    let durationSeconds: Int
    let dominantActivity: ActivityCategory
    let seconds: ActivitySeconds
    let interrupted: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case dominantActivity = "dominant_activity"
        case stationary = "stationary_seconds"
        case walking = "walking_seconds"
        case running = "running_seconds"
        case cycling = "cycling_seconds"
        case automotive = "automotive_seconds"
        case unknown = "unknown_seconds"
        case interrupted
    }

    init(sessionID: UUID, startedAt: Date, completedAt: Date, seconds: ActivitySeconds, interrupted: Bool) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationSeconds = max(0, Int(completedAt.timeIntervalSince(startedAt).rounded(.down)))
        self.dominantActivity = seconds.dominant
        self.seconds = seconds
        self.interrupted = interrupted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        dominantActivity = try container.decode(ActivityCategory.self, forKey: .dominantActivity)
        seconds = ActivitySeconds(stationary: try container.decode(Int.self, forKey: .stationary),
                                  walking: try container.decode(Int.self, forKey: .walking),
                                  running: try container.decode(Int.self, forKey: .running),
                                  cycling: try container.decode(Int.self, forKey: .cycling),
                                  automotive: try container.decode(Int.self, forKey: .automotive),
                                  unknown: try container.decode(Int.self, forKey: .unknown))
        interrupted = try container.decode(Bool.self, forKey: .interrupted)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(dominantActivity, forKey: .dominantActivity)
        try container.encode(seconds.stationary, forKey: .stationary)
        try container.encode(seconds.walking, forKey: .walking)
        try container.encode(seconds.running, forKey: .running)
        try container.encode(seconds.cycling, forKey: .cycling)
        try container.encode(seconds.automotive, forKey: .automotive)
        try container.encode(seconds.unknown, forKey: .unknown)
        try container.encode(interrupted, forKey: .interrupted)
    }

    var isValid: Bool {
        durationSeconds >= 0 && startedAt <= completedAt
            && ActivityCategory.allCases.allSatisfy { seconds[$0] >= 0 }
            && seconds.total <= durationSeconds + Self.toleranceSeconds
            && dominantActivity == seconds.dominant
    }

    /// `activity.session.completed`; the envelope `session_id` is the session ID.
    func makeEvent(eventID: UUID) throws -> ConnectorEvent {
        guard isValid else { throw ContextEventError.invalidPayload }
        return try ContextEventSchema.makeEvent(.activitySession, eventID: eventID, occurredAt: completedAt,
                                                sessionID: sessionID, payload: self)
    }
}

/// A manual session as persisted. All times are whole seconds and never go backwards, so the
/// categories always add up to the duration. Only categories and durations are kept.
struct ActivitySession: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Observed while the app is active.
        case active
        /// The app process ended during the session; it can only be completed or deleted.
        case interrupted
        /// «Завершить» was tapped; the summary waits for «Отправить в Katana».
        case awaitingConfirmation = "awaiting_confirmation"
    }

    let sessionID: UUID
    let startedAt: Date
    private(set) var phase: Phase
    private(set) var wasInterrupted: Bool
    /// Category observed since `segmentStartedAt`; `nil` while nothing is observed (app in
    /// background, before the first reading) — that time counts as `unknown`.
    private(set) var currentActivity: ActivityCategory?
    /// Start of the open segment, which is also the last saved checkpoint.
    private(set) var segmentStartedAt: Date
    private(set) var seconds: ActivitySeconds
    /// Frozen result and its event ID once the user tapped «Завершить».
    private(set) var summary: ActivitySessionSummary?
    private(set) var eventID: UUID?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case phase
        case wasInterrupted = "interrupted"
        case currentActivity = "current_activity"
        case segmentStartedAt = "segment_started_at"
        case seconds
        case summary
        case eventID = "event_id"
    }

    init(sessionID: UUID = UUID(), startedAt date: Date) {
        self.sessionID = sessionID
        self.startedAt = WholeSeconds.floor(date)
        phase = .active
        wasInterrupted = false
        currentActivity = nil
        segmentStartedAt = startedAt
        seconds = ActivitySeconds()
    }

    private mutating func closeSegment(at date: Date) {
        let end = max(WholeSeconds.floor(date), segmentStartedAt)
        seconds[currentActivity ?? .unknown] += Int(end.timeIntervalSince(segmentStartedAt))
        segmentStartedAt = end
    }

    /// A reading arrived while observed: the time so far goes to the previous category.
    mutating func observe(_ category: ActivityCategory, at date: Date) {
        guard phase == .active else { return }
        closeSegment(at: date)
        currentActivity = category
    }

    /// The app left the foreground: nothing is observed until the next reading.
    mutating func suspend(at date: Date) {
        guard phase == .active else { return }
        closeSegment(at: date)
        currentActivity = nil
    }

    /// Restored after the process ended. Time after the last checkpoint was not observed and is not counted.
    mutating func markInterrupted() {
        guard phase == .active else { return }
        phase = .interrupted
        wasInterrupted = true
        currentActivity = nil
    }

    /// «Завершить»: freezes the summary once. A second call changes nothing.
    @discardableResult
    mutating func finish(at date: Date, eventID: UUID) -> ActivitySessionSummary? {
        switch phase {
        case .awaitingConfirmation:
            return summary
        case .active:
            closeSegment(at: date)
        case .interrupted:
            break
        }
        let result = ActivitySessionSummary(sessionID: sessionID, startedAt: startedAt, completedAt: segmentStartedAt,
                                            seconds: seconds, interrupted: wasInterrupted)
        guard result.isValid else { return nil }
        currentActivity = nil
        phase = .awaitingConfirmation
        summary = result
        self.eventID = eventID
        return result
    }
}

/// A result shown in the local history. Aggregates only.
struct ActivityHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case snapshot
        case session
    }

    /// Snapshot or session ID.
    let id: UUID
    let kind: Kind
    let eventID: UUID
    let recordedAt: Date
    /// Snapshot activity, or the dominant activity of a session.
    let activity: ActivityCategory
    let confidence: ActivityConfidence?
    let durationSeconds: Int?
    let interrupted: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, activity, confidence, interrupted
        case eventID = "event_id"
        case recordedAt = "recorded_at"
        case durationSeconds = "duration_seconds"
    }
}

/// `activity-journal.json` (D-043), format v1. No tokens, no raw samples, no coordinates.
struct ActivityJournalFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "activity-journal.json"
    static let directoryName = "ActivityJournal"
    static let maxHistory = 50
    static var empty: ActivityJournalFile { ActivityJournalFile() }

    var version = ActivityJournalFile.currentVersion
    var session: ActivitySession?
    var history: [ActivityHistoryEntry] = []

    static func applicationSupportStore() -> VersionedJSONFileStore<ActivityJournalFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<ActivityJournalFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}
