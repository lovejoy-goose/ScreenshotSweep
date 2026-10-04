import Foundation

/// Fixed limits of local geofences (D-049).
enum GeofenceRules {
    /// Allowed radii in meters; also wire values of `radius_m`.
    static let allowedRadii = [100, 200, 500, 1000]
    /// Coordinates are rounded to 4 decimal places (≈11 m) before they are stored or sent.
    static let coordinateFractionDigits = 4
    /// Core Location monitors at most 20 regions per app.
    static let maxGeofences = 20
    static let maxNameScalars = 40
    /// Identifier prefix of every system region Connector registers.
    static let regionIdentifierPrefix = "app.katana.connector.geofence"

    static func regionIdentifier(for geofenceID: UUID) -> String {
        "\(regionIdentifierPrefix).\(geofenceID.uuidString.lowercased())"
    }

    static func geofenceID(fromRegionIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(regionIdentifierPrefix + ".") else { return nil }
        return ConnectorURLRouter.canonicalUUID(String(identifier.dropFirst(regionIdentifierPrefix.count + 1)))
    }
}

/// Safe single-line and multi-line text from Katana or the user.
enum SafeText {
    /// 1…`maxScalars` Unicode scalars, not only whitespace, no control characters.
    static func isValidLine(_ text: String, maxScalars: Int) -> Bool {
        let scalars = text.unicodeScalars
        return (1...maxScalars).contains(scalars.count)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Like `isValidLine`, but line breaks are allowed.
    static func isValidMultiline(_ text: String, maxScalars: Int) -> Bool {
        let scalars = text.unicodeScalars
        return (1...maxScalars).contains(scalars.count)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scalars.contains { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }
    }
}
