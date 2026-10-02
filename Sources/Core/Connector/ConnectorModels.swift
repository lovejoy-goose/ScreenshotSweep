import Foundation

/// Connection of this device to Katana. Raw values are wire values (snake_case).
enum ConnectorConnectionState: String, Codable, CaseIterable, Sendable {
    case unpaired
    case pairing
    case connected
    case revoked
    case error
}

/// Non-personal summary of this Connector installation.
/// `deviceID` is assigned by the server on pairing; `nil` until then.
struct ConnectorDeviceSummary: Codable, Equatable, Sendable {
    var deviceID: String?
    var displayName: String
    var appVersion: String
    var systemVersion: String
    var connectionState: ConnectorConnectionState
    var lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayName = "display_name"
        case appVersion = "app_version"
        case systemVersion = "system_version"
        case connectionState = "connection_state"
        case lastSeenAt = "last_seen_at"
    }
}

/// JSON coding used for Connector models: ISO 8601 dates (UTC), as in docs/API.md.
enum ConnectorJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
