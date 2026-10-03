import Foundation

/// A reminder draft prepared by Katana for this device (D-041). Loaded only by the user's
/// button over authenticated HTTPS; the link carries only its ID. Text is never logged.
struct ReminderDraft: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let draftID: UUID
    let title: String
    let body: String?
    let fireAt: Date
    let expiresAt: Date

    var description: String { "ReminderDraft(\(draftID.uuidString.lowercased()))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["draftID": draftID, "fireAt": fireAt], displayStyle: .struct) }
}

/// Typed outcome of `GET /api/connector/reminder-drafts/{draft_id}`. Carries no bodies or tokens.
enum ReminderDraftError: Error, Equatable, Sendable {
    /// No saved connection; nothing was sent.
    case notPaired
    /// 401, or credentials already rejected: pair again. Never retried automatically.
    case unauthorized
    /// 403/404: no such draft for this device.
    case notFound
    /// 410, or `expires_at` already passed.
    case expired
    /// 409: the draft was already used.
    case consumed
    /// `fire_at` is not in the future any more.
    case alreadyDue
    /// No response, timeout or 408. Retry by button.
    case offline
    case rateLimited
    case serverError
    /// Redirect, unexpected status, oversized or malformed body, or a draft violating the rules.
    case invalidResponse

    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .serverError: return true
        default: return false
        }
    }

    /// Client interpretation of an HTTP status (`nil` for 2xx).
    static func classify(statusCode: Int) -> ReminderDraftError? {
        switch statusCode {
        case 200...299: return nil
        case 401: return .unauthorized
        case 403, 404: return .notFound
        case 408: return .offline
        case 409: return .consumed
        case 410: return .expired
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .invalidResponse
        }
    }
}

enum ReminderTextRules {
    static let maxTitleScalars = 120
    static let maxBodyScalars = 500
    /// `fire_at` further away than this is rejected as implausible.
    static let maxLeadTime: TimeInterval = 366 * 24 * 60 * 60

    static func isValidTitle(_ title: String) -> Bool {
        let scalars = title.unicodeScalars
        return (1...maxTitleScalars).contains(scalars.count)
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Empty → `nil`; too long or control characters other than a line break → invalid (`.failure`).
    static func normalizedBody(_ body: String?) -> Result<String?, ReminderDraftError> {
        guard let body, !body.isEmpty else { return .success(nil) }
        guard body.unicodeScalars.count <= maxBodyScalars,
              !body.unicodeScalars.contains(where: { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.invalidResponse)
        }
        return .success(body)
    }
}

/// Response body of the draft route; unknown extra keys are ignored.
struct ReminderDraftResponse: Decodable, Sendable {
    let draftID: String
    let title: String
    let body: String?
    let fireAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case title
        case body
        case fireAt = "fire_at"
        case expiresAt = "expires_at"
    }

    func validated(requestedID: UUID, now: Date) throws -> ReminderDraft {
        guard UUID(uuidString: draftID) == requestedID, ReminderTextRules.isValidTitle(title) else {
            throw ReminderDraftError.invalidResponse
        }
        let body = try ReminderTextRules.normalizedBody(self.body).get()
        guard expiresAt > now else { throw ReminderDraftError.expired }
        guard fireAt > now else { throw ReminderDraftError.alreadyDue }
        guard fireAt.timeIntervalSince(now) <= ReminderTextRules.maxLeadTime else { throw ReminderDraftError.invalidResponse }
        return ReminderDraft(draftID: requestedID, title: title, body: body, fireAt: fireAt, expiresAt: expiresAt)
    }
}

/// Loads a draft (the authenticated API client; mocked in tests).
protocol ReminderDraftFetching: Sendable {
    func fetchReminderDraft(id: UUID) async throws -> ReminderDraft
}

// MARK: - Local notifications

enum ReminderNotificationID {
    static let prefix = "app.katana.connector.reminder"

    /// Deterministic: the same draft always maps to the same system notification.
    static func make(draftID: UUID) -> String {
        "\(prefix).\(draftID.uuidString.lowercased())"
    }
}

/// Permission the reminder was scheduled with. Raw values are wire values.
enum ReminderAuthorization: String, Codable, CaseIterable, Sendable {
    case authorized
    case provisional
    case ephemeral
}

struct ReminderNotificationRequest: Equatable, Sendable, CustomStringConvertible {
    let identifier: String
    let title: String
    let body: String?
    let fireAt: Date

    var description: String { "ReminderNotificationRequest(\(identifier))" }
}

/// Local notifications adapter for reminders (implemented in Features, mocked in tests).
/// Touches only identifiers it is given — never other notifications of the app.
protocol ReminderNotificationSystem: Sendable {
    /// Reads the settings without any prompt.
    func permission() async -> NotificationPermission
    /// Shows the prompt (only after «Создать напоминание», only if not requested yet).
    func requestAuthorization() async -> NotificationPermission
    /// Adds or replaces the pending request with `request.identifier`.
    func schedule(_ request: ReminderNotificationRequest) async throws
    func removePending(identifier: String) async
}

// MARK: - Records and events

/// A reminder created by Connector, as persisted (D-043). Title and body are kept only for
/// the list in the app; events never contain them.
struct ReminderRecord: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case scheduled
        case cancelled
    }

    let draftID: UUID
    let notificationID: String
    let title: String
    let body: String?
    let fireAt: Date
    let createdAt: Date
    let authorization: ReminderAuthorization
    var status: Status
    var cancelledAt: Date?
    let scheduledEventID: UUID
    /// `reminder.local.scheduled` is in the queue; until then it is retried with the same ID.
    var scheduledEventSaved: Bool
    var cancelledEventID: UUID?
    var cancelledEventSaved: Bool

    var id: UUID { draftID }

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case notificationID = "notification_id"
        case title, body, status, authorization
        case fireAt = "fire_at"
        case createdAt = "created_at"
        case cancelledAt = "cancelled_at"
        case scheduledEventID = "scheduled_event_id"
        case scheduledEventSaved = "scheduled_event_saved"
        case cancelledEventID = "cancelled_event_id"
        case cancelledEventSaved = "cancelled_event_saved"
    }

    /// The notification time has come (shown, or about to be); it can no longer be cancelled.
    func isDue(at date: Date) -> Bool { fireAt <= date }

    private struct ScheduledPayload: Encodable {
        let draftID: UUID
        let scheduledFor: Date
        let notificationID: String
        let authorization: ReminderAuthorization
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case draftID = "draft_id"
            case scheduledFor = "scheduled_for"
            case notificationID = "notification_id"
            case authorization
            case createdAt = "created_at"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(draftID.uuidString.lowercased(), forKey: .draftID)
            try container.encode(scheduledFor, forKey: .scheduledFor)
            try container.encode(notificationID, forKey: .notificationID)
            try container.encode(authorization, forKey: .authorization)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }

    private struct CancelledPayload: Encodable {
        let draftID: UUID
        let notificationID: String
        let cancelledAt: Date

        enum CodingKeys: String, CodingKey {
            case draftID = "draft_id"
            case notificationID = "notification_id"
            case cancelledAt = "cancelled_at"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(draftID.uuidString.lowercased(), forKey: .draftID)
            try container.encode(notificationID, forKey: .notificationID)
            try container.encode(cancelledAt, forKey: .cancelledAt)
        }
    }

    /// `reminder.local.scheduled` — without title or body.
    func makeScheduledEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.reminderScheduled, eventID: scheduledEventID, occurredAt: createdAt, sessionID: draftID,
                                         payload: ScheduledPayload(draftID: draftID, scheduledFor: fireAt,
                                                                   notificationID: notificationID,
                                                                   authorization: authorization, createdAt: createdAt))
    }

    /// `reminder.local.cancelled` — without title or body.
    func makeCancelledEvent() throws -> ConnectorEvent {
        guard status == .cancelled, let cancelledAt, let cancelledEventID else { throw ContextEventError.invalidPayload }
        return try ContextEventSchema.makeEvent(.reminderCancelled, eventID: cancelledEventID, occurredAt: cancelledAt,
                                                sessionID: draftID,
                                                payload: CancelledPayload(draftID: draftID, notificationID: notificationID,
                                                                          cancelledAt: cancelledAt))
    }
}

/// `reminders.json` (D-043), format v1. No tokens.
struct ReminderStoreFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "reminders.json"
    static let directoryName = "Reminders"
    static let maxReminders = 100
    static var empty: ReminderStoreFile { ReminderStoreFile() }

    var version = ReminderStoreFile.currentVersion
    var reminders: [ReminderRecord] = []

    static func applicationSupportStore() -> VersionedJSONFileStore<ReminderStoreFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<ReminderStoreFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}
