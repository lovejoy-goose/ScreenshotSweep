import Foundation

/// Screens reachable by navigation. Shared by Dashboard links and incoming URLs.
enum AppRoute: Hashable, Sendable {
    case screenshotCleanup
    case pairing
}

/// Features a `katana-connector://open` link may open. Wire values are part of URL v1.
enum ConnectorURLFeature: String, CaseIterable, Sendable {
    case screenshotCleanup = "screenshot_cleanup"
    case pairing

    var route: AppRoute {
        switch self {
        case .screenshotCleanup: return .screenshotCleanup
        case .pairing: return .pairing
        }
    }
}

/// The only thing a URL can do: open a screen. It never deletes, pairs, sends,
/// carries credentials or requests permissions.
enum ConnectorURLAction: Equatable, Sendable {
    case open(ConnectorURLFeature)
}

enum ConnectorURLError: Error, Equatable, Sendable {
    case tooLong
    case notPrintableASCII
    case malformed
    case wrongScheme
    case wrongHost
    /// user, password, port, fragment or a path other than empty or "/".
    case unexpectedComponent
    case missingVersion
    case unsupportedVersion
    case missingFeature
    case unknownFeature
    case duplicateParameter
    /// Anything other than `v` and `feature`, e.g. token, code, base_url, device_id.
    case unknownParameter
    case emptyValue
}

/// Strict parser for URL scheme v1:
/// `katana-connector://open?v=1&feature=screenshot_cleanup|pairing`.
/// Pure and offline. The pairing QR format (`katana-connector://pair?…`) is not accepted here.
enum ConnectorURLRouter {
    static let scheme = "katana-connector"
    static let host = "open"
    static let supportedVersion = "1"
    static let maxLength = 2048
    static let allowedParameters: Set<String> = ["v", "feature"]

    static func url(for feature: ConnectorURLFeature) -> URL {
        URL(string: "\(scheme)://\(host)?v=\(supportedVersion)&feature=\(feature.rawValue)")!
    }

    static func parse(_ url: URL) throws -> ConnectorURLAction {
        try parse(url.absoluteString)
    }

    static func parse(_ text: String) throws -> ConnectorURLAction {
        guard text.count <= maxLength else { throw ConnectorURLError.tooLong }
        // Checked explicitly: since iOS 17 URLComponents silently percent-encodes invalid characters.
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw ConnectorURLError.notPrintableASCII
        }
        guard let components = URLComponents(string: text) else { throw ConnectorURLError.malformed }
        guard components.scheme == scheme else { throw ConnectorURLError.wrongScheme }
        guard components.host == host else { throw ConnectorURLError.wrongHost }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ConnectorURLError.unexpectedComponent
        }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowedParameters.contains(item.name) else { throw ConnectorURLError.unknownParameter }
            guard parameters[item.name] == nil else { throw ConnectorURLError.duplicateParameter }
            guard let value = item.value, !value.isEmpty else { throw ConnectorURLError.emptyValue }
            parameters[item.name] = value
        }

        guard let version = parameters["v"] else { throw ConnectorURLError.missingVersion }
        guard version == supportedVersion else { throw ConnectorURLError.unsupportedVersion }
        guard let featureValue = parameters["feature"] else { throw ConnectorURLError.missingFeature }
        guard let feature = ConnectorURLFeature(rawValue: featureValue) else { throw ConnectorURLError.unknownFeature }
        return .open(feature)
    }
}
