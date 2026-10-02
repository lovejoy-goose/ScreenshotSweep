import Foundation

// Secrets are wrapped in dedicated types whose description, debugDescription and
// mirror are redacted, so `print`, string interpolation, `dump` and the debugger
// never show the value. Read `secretValue` only where the secret is actually used.

/// One-time pairing code from the QR. Never logged, never stored.
struct PairingCode: Encodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let maxLength = 128

    let secretValue: String

    init(_ secretValue: String) {
        self.secretValue = secretValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secretValue)
    }

    var description: String { "PairingCode(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [Mirror.Child](), displayStyle: .struct) }
}

/// Long-lived device token issued by Katana. Stored only in Keychain.
struct DeviceToken: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let maxLength = 4096

    let secretValue: String

    init(_ secretValue: String) {
        self.secretValue = secretValue
    }

    init(from decoder: Decoder) throws {
        secretValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secretValue)
    }

    var description: String { "DeviceToken(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [Mirror.Child](), displayStyle: .struct) }
}

/// Which pairing hosts are acceptable. Release builds accept HTTPS only.
/// `localDevelopment` is reserved for a separate debug configuration (not wired into any
/// build yet); it additionally allows plain HTTP to local hosts only, never arbitrary HTTP.
struct PairingSecurityPolicy: Equatable, Sendable {
    let allowsLocalHTTP: Bool

    static let release = PairingSecurityPolicy(allowsLocalHTTP: false)
    static let localDevelopment = PairingSecurityPolicy(allowsLocalHTTP: true)

    func permits(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return allowsLocalHTTP && Self.isLocalDevelopmentHost(host)
        default: return false
        }
    }

    static func isLocalDevelopmentHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

/// Validated content of a pairing QR (v1).
struct PairingPayload: Equatable, Sendable {
    let baseURL: URL
    let code: PairingCode

    /// Hostname (and non-default port) shown to the user before the code is sent.
    var displayHost: String {
        let host = (baseURL.host ?? "").lowercased()
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }
}

enum InvalidQRReason: Equatable, Sendable {
    case tooLong
    case malformed
    case wrongScheme
    case wrongHost
    case unsupportedVersion
    case missingCode
    case invalidCode
    case missingBaseURL
    case malformedBaseURL
    case baseURLHasCredentials
    case baseURLHasQuery
    case baseURLHasFragment
}

enum PairingError: Error, Equatable, Sendable {
    case invalidQR(InvalidQRReason)
    case insecureHost
    case expiredCode
    case rejected
    case transport
    case invalidResponse
    case keychainFailure
}

/// User-editable device name sent to Katana. `UIDevice.name` is not used.
enum DeviceDisplayName {
    static let fallback = "iPhone"
    static let maxLength = 40

    static func normalize(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? fallback : limited
    }
}

/// Non-personal device information sent with the pairing request.
struct PairingDeviceInfo: Encodable, Equatable, Sendable {
    let displayName: String
    let platform: String
    let appVersion: String
    let systemVersion: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case platform
        case appVersion = "app_version"
        case systemVersion = "system_version"
    }

    static func current(displayName: String) -> PairingDeviceInfo {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return PairingDeviceInfo(displayName: DeviceDisplayName.normalize(displayName), platform: "ios",
                                 appVersion: appVersion, systemVersion: systemVersion)
    }
}

struct PairingCompleteRequest: Encodable, Equatable, Sendable {
    let pairingCode: PairingCode
    let device: PairingDeviceInfo

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case device
    }
}

struct PairingCompleteResponse: Decodable, Equatable, Sendable {
    let deviceID: String
    let deviceToken: DeviceToken
    let displayName: String
    let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceToken = "device_token"
        case displayName = "display_name"
        case pairedAt = "paired_at"
    }
}

/// Non-secret result of pairing; safe to show in UI.
struct PairedDevice: Codable, Equatable, Sendable {
    let deviceID: String
    let displayName: String
    let pairedAt: Date
    let baseURL: URL

    var host: String { (baseURL.host ?? "").lowercased() }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayName = "display_name"
        case pairedAt = "paired_at"
        case baseURL = "base_url"
    }
}

/// Everything persisted in Keychain: the token plus minimal pairing metadata.
struct PairingCredentials: Codable, Equatable, Sendable {
    let token: DeviceToken
    let device: PairedDevice

    enum CodingKeys: String, CodingKey {
        case token = "device_token"
        case device
    }
}
