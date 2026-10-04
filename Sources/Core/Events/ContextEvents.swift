import Foundation

/// Event types added in v0.2 (D-038). Raw values are wire values and must never change.
enum ContextEventType: String, CaseIterable, Sendable {
    case activitySnapshot = "activity.snapshot.completed"
    case activitySession = "activity.session.completed"
    case locationCheckIn = "location.check_in.created"
    case reminderScheduled = "reminder.local.scheduled"
    case reminderCancelled = "reminder.local.cancelled"

    /// The exact payload keys of this type. Anything else — missing or extra — is rejected before enqueue.
    var payloadKeys: Set<String> {
        switch self {
        case .activitySnapshot:
            return ["activity", "confidence", "checked_at", "source", "interrupted"]
        case .activitySession:
            return ["session_id", "started_at", "completed_at", "duration_seconds", "dominant_activity",
                    "stationary_seconds", "walking_seconds", "running_seconds", "cycling_seconds",
                    "automotive_seconds", "unknown_seconds", "interrupted"]
        case .locationCheckIn:
            return ["check_in_id", "occurred_at", "latitude", "longitude", "precision",
                    "horizontal_accuracy_bucket", "label_requested"]
        case .reminderScheduled:
            return ["draft_id", "scheduled_for", "notification_id", "authorization", "created_at"]
        case .reminderCancelled:
            return ["draft_id", "notification_id", "cancelled_at"]
        }
    }
}

enum ContextEventError: Error, Equatable, Sendable {
    /// Payload violates the schema or an invariant of its type; no event is created.
    case invalidPayload
}

/// Builds v0.2 events with strict payload validation before they can reach the queue.
enum ContextEventSchema {
    static func makeEvent<Payload: Encodable>(_ type: ContextEventType, eventID: UUID, occurredAt: Date,
                                              sessionID: UUID, payload: Payload) throws -> ConnectorEvent {
        let value: JSONValue
        do {
            value = try ConnectorJSON.makeDecoder().decode(JSONValue.self, from: ConnectorJSON.makeEncoder().encode(payload))
        } catch {
            throw ContextEventError.invalidPayload
        }
        let event = ConnectorEvent(eventID: eventID, type: type.rawValue, occurredAt: occurredAt,
                                   sessionID: sessionID, payload: value)
        try validate(event)
        return event
    }

    /// The payload is an object with exactly the keys of its type, and no value is nested.
    static func validate(_ event: ConnectorEvent) throws {
        guard let type = ContextEventType(rawValue: event.type), event.hasValidType,
              case .object(let object) = event.payload,
              Set(object.keys) == type.payloadKeys else {
            throw ContextEventError.invalidPayload
        }
        for value in object.values {
            switch value {
            case .array, .object, .null: throw ContextEventError.invalidPayload
            case .bool, .int, .double, .string: continue
            }
        }
    }
}

// MARK: - Sink used by the v0.2 features

enum EventEnqueueOutcome: Equatable, Sendable {
    /// Persisted in the queue of the current connection (or already there with the same `event_id`).
    case saved
    /// No Katana connection: nothing was recorded in the queue.
    case notPaired
    /// The queue could not store the event.
    case failed
}

/// What the user may be told about an event that was saved for Katana. Never shows IDs.
enum EventLocalDeliveryState: Equatable, Sendable {
    case pending
    case delivered
    case rejected
}

/// Where v0.2 features put their events (the event delivery coordinator). Features never see
/// the API client, the token or the scope.
@MainActor
protocol ConnectorEventSink: AnyObject {
    func enqueueEvent(_ event: ConnectorEvent) async -> EventEnqueueOutcome
    func localDeliveryState(of eventID: UUID) async -> EventLocalDeliveryState
    /// A feature request got 401: stop using the connection (same as a 401 during delivery).
    func reportUnauthorized()
}
