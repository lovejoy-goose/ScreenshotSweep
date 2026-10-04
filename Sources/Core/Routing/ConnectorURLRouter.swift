import Foundation

/// Screens reachable by navigation. Shared by Dashboard links and incoming URLs
/// (Capability Lab is reachable from Dashboard only; there is no URL for it).
enum AppRoute: Hashable, Sendable {
    case screenshotCleanup
    case pairing
    case capabilityLab
    case activityJournal
    case locationCheckIn
    case reminders
    /// Screen of one Katana reminder draft. Opening it loads nothing by itself (D-041).
    case reminderDraft(UUID)
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

/// Screens a v2 link may open (D-042). `reminderDraft` carries only the opaque draft ID —
/// never the reminder text.
enum ConnectorURLDestination: Equatable, Sendable {
    case activityJournal
    case locationCheckIn
    case reminderDraft(UUID)

    /// Wire values of `feature` in URL v2.
    static let featureValues = ["activity_journal", "location_check_in", "reminder"]

    var featureValue: String {
        switch self {
        case .activityJournal: return "activity_journal"
        case .locationCheckIn: return "location_check_in"
        case .reminderDraft: return "reminder"
        }
    }

    /// Navigation stack the link produces.
    var routes: [AppRoute] {
        switch self {
        case .activityJournal: return [.activityJournal]
        case .locationCheckIn: return [.locationCheckIn]
        case .reminderDraft(let id): return [.reminders, .reminderDraft(id)]
        }
    }
}

/// The only thing a URL can do: open a screen. It never deletes, pairs, sends, loads,
/// schedules, carries credentials or requests permissions.
enum ConnectorURLAction: Equatable, Sendable {
    /// URL v1.
    case open(ConnectorURLFeature)
    /// URL v2.
    case openDestination(ConnectorURLDestination)
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
    /// v2 reminder link without `draft_id`.
    case missingDraftID
    /// `draft_id` is not a canonical UUID, or appears where it is not allowed.
    case invalidDraftID
}

/// Strict parser for URL scheme v1 (`katana-connector://open?v=1&feature=screenshot_cleanup|pairing`)
/// and v2 (`…?v=2&feature=activity_journal|location_check_in`, `…?v=2&feature=reminder&draft_id=<uuid>`).
/// Pure and offline. The pairing QR format (`katana-connector://pair?…`) is not accepted here.
enum ConnectorURLRouter {
    static let scheme = "katana-connector"
    static let host = "open"
    static let supportedVersion = "1"
    static let version2 = "2"
    static let maxLength = 2048
    static let allowedParameters: Set<String> = ["v", "feature"]
    /// Parameters any version may carry; each version then allows only its own.
    private static let knownParameters: Set<String> = ["v", "feature", "draft_id"]

    static func url(for feature: ConnectorURLFeature) -> URL {
        URL(string: "\(scheme)://\(host)?v=\(supportedVersion)&feature=\(feature.rawValue)")!
    }

    static func url(for destination: ConnectorURLDestination) -> URL {
        var text = "\(scheme)://\(host)?v=\(version2)&feature=\(destination.featureValue)"
        if case .reminderDraft(let id) = destination { text += "&draft_id=\(id.uuidString.lowercased())" }
        return URL(string: text)!
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
            guard knownParameters.contains(item.name) else { throw ConnectorURLError.unknownParameter }
            guard parameters[item.name] == nil else { throw ConnectorURLError.duplicateParameter }
            guard let value = item.value, !value.isEmpty else { throw ConnectorURLError.emptyValue }
            parameters[item.name] = value
        }

        guard let version = parameters["v"] else { throw ConnectorURLError.missingVersion }
        switch version {
        case supportedVersion:
            // v1 is unchanged: only `v` and `feature`.
            guard parameters["draft_id"] == nil else { throw ConnectorURLError.unknownParameter }
            guard let featureValue = parameters["feature"] else { throw ConnectorURLError.missingFeature }
            guard let feature = ConnectorURLFeature(rawValue: featureValue) else { throw ConnectorURLError.unknownFeature }
            return .open(feature)
        case version2:
            return .openDestination(try parseVersion2(parameters, percentEncodedQuery: components.percentEncodedQuery))
        default:
            throw ConnectorURLError.unsupportedVersion
        }
    }

    private static func parseVersion2(_ parameters: [String: String], percentEncodedQuery: String?) throws -> ConnectorURLDestination {
        // v2 values are plain tokens; percent-encoding could smuggle anything past the checks.
        guard !(percentEncodedQuery ?? "").contains("%") else { throw ConnectorURLError.malformed }
        guard let featureValue = parameters["feature"] else { throw ConnectorURLError.missingFeature }
        let draftValue = parameters["draft_id"]
        switch featureValue {
        case "activity_journal", "location_check_in":
            guard draftValue == nil else { throw ConnectorURLError.invalidDraftID }
            return featureValue == "activity_journal" ? .activityJournal : .locationCheckIn
        case "reminder":
            guard let draftValue else { throw ConnectorURLError.missingDraftID }
            guard let id = canonicalUUID(draftValue) else { throw ConnectorURLError.invalidDraftID }
            return .reminderDraft(id)
        default:
            // v1 features exist, but not in this version.
            if ConnectorURLFeature(rawValue: featureValue) != nil { throw ConnectorURLError.unsupportedVersion }
            throw ConnectorURLError.unknownFeature
        }
    }

    /// Exactly `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (hex, any case). `UUID(uuidString:)` alone is
    /// not used as the check, so no other spelling is ever accepted.
    static func canonicalUUID(_ text: String) -> UUID? {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 36, groups.map(\.count) == [8, 4, 4, 4, 12],
              text.unicodeScalars.allSatisfy({ $0 == "-" || CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            return nil
        }
        return UUID(uuidString: text)
    }
}
