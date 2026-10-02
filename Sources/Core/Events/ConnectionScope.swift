import Foundation

/// Identifies the connection an event belongs to. Built only from stable, non-secret
/// data of the pairing — never from the device token or anything derived from it.
/// Events are delivered only while the current connection has the same scope.
struct ConnectionScope: Codable, Hashable, Sendable {
    /// Canonical form: lowercase scheme and host, no default port, no trailing slash,
    /// no user info, query or fragment.
    let baseURL: String
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case deviceID = "device_id"
    }

    init(baseURL: URL, deviceID: String) {
        self.baseURL = Self.canonicalBaseURL(baseURL)
        self.deviceID = deviceID
    }

    init(device: PairedDevice) {
        self.init(baseURL: device.baseURL, deviceID: device.deviceID)
    }

    static func canonicalBaseURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
