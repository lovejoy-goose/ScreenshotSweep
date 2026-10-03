import Foundation

/// Type-safe JSON value for event payloads.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Envelope of one event delivered to Katana. Immutable once created: retries send the
/// same `event_id` and payload. UUIDs are encoded in lowercase.
struct ConnectorEvent: Codable, Equatable, Sendable {
    static let maxTypeLength = 100

    let eventID: UUID
    let type: String
    let occurredAt: Date
    let sessionID: UUID
    let payload: JSONValue

    init(eventID: UUID = UUID(), type: String, occurredAt: Date, sessionID: UUID, payload: JSONValue) {
        self.eventID = eventID
        self.type = type
        self.occurredAt = occurredAt
        self.sessionID = sessionID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case type
        case occurredAt = "occurred_at"
        case sessionID = "session_id"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID.uuidString.lowercased(), forKey: .eventID)
        try container.encode(type, forKey: .type)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(sessionID.uuidString.lowercased(), forKey: .sessionID)
        try container.encode(payload, forKey: .payload)
    }

    /// Lowercase dot-separated identifier, e.g. `screenshot_cleanup.completed`.
    var hasValidType: Bool {
        !type.isEmpty && type.count <= Self.maxTypeLength
            && type.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" }
    }
}

// Descriptions never include the payload.
extension ConnectorEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "ConnectorEvent(\(type), \(eventID.uuidString.lowercased()))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["eventID": eventID, "type": type, "occurredAt": occurredAt, "sessionID": sessionID],
               displayStyle: .struct)
    }
}
