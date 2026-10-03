import Foundation

/// `GET /api/connector/connection/check` response.
struct ConnectionCheckResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let serverTime: Date
    let accountLabel: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case serverTime = "server_time"
        case accountLabel = "account_label"
    }
}

/// `POST /api/connector/capabilities/report` body.
struct CapabilityReport: Encodable, Equatable, Sendable {
    let reportedAt: Date
    let device: ConnectorDeviceSummary
    let capabilities: [CapabilitySnapshot]

    enum CodingKeys: String, CodingKey {
        case reportedAt = "reported_at"
        case device
        case capabilities
    }
}

/// `POST /api/connector/events/batch` body.
struct EventBatchRequest: Encodable, Equatable, Sendable {
    let events: [ConnectorEvent]
}

enum EventDeliveryStatus: String, Codable, Sendable {
    case accepted
    case duplicate
    case rejected
}

struct EventDeliveryResult: Codable, Equatable, Sendable {
    let eventID: UUID
    let status: EventDeliveryStatus
    /// Optional machine-readable reason, e.g. for `rejected`.
    let code: String?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status
        case code
    }
}

/// `POST /api/connector/events/batch` response.
struct EventBatchResponse: Decodable, Equatable, Sendable {
    let results: [EventDeliveryResult]

    /// Results keyed by event ID. Every result must refer to a sent event, at most once;
    /// otherwise the whole response is invalid. Sent events without a result stay queued.
    func validated(against sent: [ConnectorEvent]) throws -> [UUID: EventDeliveryResult] {
        let sentIDs = Set(sent.map(\.eventID))
        var byID: [UUID: EventDeliveryResult] = [:]
        for result in results {
            guard sentIDs.contains(result.eventID), byID[result.eventID] == nil else {
                throw ConnectorAPIError.invalidResponse
            }
            byID[result.eventID] = result
        }
        return byID
    }
}
