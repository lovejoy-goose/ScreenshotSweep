import Foundation

/// Raw values are wire values (D-049, D-051).
enum GeofenceTransition: String, Codable, CaseIterable, Sendable {
    case enter
    case exit
}

enum GeofenceDeliveryContext: String, Codable, CaseIterable, Sendable {
    case foreground
    case background
}

enum GeofenceOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case actionDraft = "action_draft"
}

/// What iOS actually does with a geofence, shown next to it.
enum GeofenceSystemState: Equatable, Sendable {
    case active
    case disabled
    case notRegistered
    case noAlwaysPermission
}

/// A geofence the user registered. Coordinates (rounded to 4 decimals) are kept only to
/// re-register the system region; the name never leaves the iPhone.
struct GeofenceRecord: Codable, Equatable, Identifiable, Sendable {
    let geofenceID: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let createdAt: Date
    let origin: GeofenceOrigin
    var enabled: Bool
    /// The system region had to be registered again; the next transition reports `interrupted`.
    var reregistered: Bool
    let createdEventID: UUID
    var createdEventSaved: Bool

    var id: UUID { geofenceID }
    var regionIdentifier: String { GeofenceRules.regionIdentifier(for: geofenceID) }

    enum CodingKeys: String, CodingKey {
        case geofenceID = "geofence_id"
        case name, latitude, longitude, origin, enabled, reregistered
        case radiusMeters = "radius_m"
        case createdAt = "created_at"
        case createdEventID = "created_event_id"
        case createdEventSaved = "created_event_saved"
    }

    private struct Payload: Encodable {
        let geofenceID: UUID
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int
        let createdAt: Date
        let origin: GeofenceOrigin

        enum CodingKeys: String, CodingKey {
            case geofenceID = "geofence_id"
            case latitude, longitude, origin
            case radiusMeters = "radius_m"
            case createdAt = "created_at"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(geofenceID.uuidString.lowercased(), forKey: .geofenceID)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encode(radiusMeters, forKey: .radiusMeters)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(origin, forKey: .origin)
        }
    }

    /// `geofence.created` — the only event with coordinates (rounded); never the name.
    func makeCreatedEvent() throws -> ConnectorEvent {
        let digits = GeofenceRules.coordinateFractionDigits
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              CoordinateRounding.fractionDigits(of: latitude) <= digits, CoordinateRounding.fractionDigits(of: longitude) <= digits,
              GeofenceRules.allowedRadii.contains(radiusMeters) else {
            throw ContextEventError.invalidPayload
        }
        return try ContextEventSchema.makeEvent(.geofenceCreated, eventID: createdEventID, occurredAt: createdAt, sessionID: geofenceID,
                                                payload: Payload(geofenceID: geofenceID, latitude: latitude, longitude: longitude,
                                                                 radiusMeters: radiusMeters, createdAt: createdAt, origin: origin))
    }
}

/// A transition saved before it is queued, so it is retried with the same event ID. No coordinates.
struct GeofencePendingTransition: Codable, Equatable, Sendable {
    let transitionID: UUID
    let geofenceID: UUID
    let eventID: UUID
    let transition: GeofenceTransition
    let occurredAt: Date
    let deliveryContext: GeofenceDeliveryContext
    let interrupted: Bool

    enum CodingKeys: String, CodingKey {
        case transitionID = "transition_id"
        case geofenceID = "geofence_id"
        case eventID = "event_id"
        case transition
        case occurredAt = "occurred_at"
        case deliveryContext = "delivery_context"
        case interrupted
    }

    private struct Payload: Encodable {
        let value: GeofencePendingTransition

        enum CodingKeys: String, CodingKey {
            case geofenceID = "geofence_id"
            case transitionID = "transition_id"
            case transition
            case occurredAt = "occurred_at"
            case deliveryContext = "delivery_context"
            case interrupted
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value.geofenceID.uuidString.lowercased(), forKey: .geofenceID)
            try container.encode(value.transitionID.uuidString.lowercased(), forKey: .transitionID)
            try container.encode(value.transition, forKey: .transition)
            try container.encode(value.occurredAt, forKey: .occurredAt)
            try container.encode(value.deliveryContext, forKey: .deliveryContext)
            try container.encode(value.interrupted, forKey: .interrupted)
        }
    }

    /// `geofence.transitioned` — never coordinates.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.geofenceTransitioned, eventID: eventID, occurredAt: occurredAt, sessionID: transitionID,
                                         payload: Payload(value: self))
    }
}

/// The last accepted transition per geofence, to drop duplicate system callbacks.
struct GeofenceLastTransition: Codable, Equatable, Sendable {
    /// The same transition of the same geofence within this window is a duplicate.
    static let duplicateWindow: TimeInterval = 120

    let geofenceID: UUID
    let transition: GeofenceTransition
    let at: Date

    enum CodingKeys: String, CodingKey {
        case geofenceID = "geofence_id"
        case transition
        case at
    }
}

/// A removal whose event is not queued yet. The geofence and its coordinates are already gone.
struct GeofencePendingRemoval: Codable, Equatable, Sendable {
    let geofenceID: UUID
    let eventID: UUID
    let removedAt: Date

    enum CodingKeys: String, CodingKey {
        case geofenceID = "geofence_id"
        case eventID = "event_id"
        case removedAt = "removed_at"
    }

    private struct Payload: Encodable {
        let geofenceID: UUID
        let removedAt: Date

        enum CodingKeys: String, CodingKey {
            case geofenceID = "geofence_id"
            case removedAt = "removed_at"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(geofenceID.uuidString.lowercased(), forKey: .geofenceID)
            try container.encode(removedAt, forKey: .removedAt)
        }
    }

    /// `geofence.removed`.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.geofenceRemoved, eventID: eventID, occurredAt: removedAt, sessionID: geofenceID,
                                         payload: Payload(geofenceID: geofenceID, removedAt: removedAt))
    }
}

/// `geofences.json` (D-052), format v1. Rounded coordinates only for registered geofences;
/// no location samples, no routes, no tokens.
struct GeofencesFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "geofences.json"
    static let directoryName = "Geofences"
    static var empty: GeofencesFile { GeofencesFile() }

    var version = GeofencesFile.currentVersion
    var geofences: [GeofenceRecord] = []
    var pendingTransitions: [GeofencePendingTransition] = []
    var lastTransitions: [GeofenceLastTransition] = []
    var pendingRemovals: [GeofencePendingRemoval] = []

    enum CodingKeys: String, CodingKey {
        case version, geofences
        case pendingTransitions = "pending_transitions"
        case lastTransitions = "last_transitions"
        case pendingRemovals = "pending_removals"
    }

    static func applicationSupportStore() -> VersionedJSONFileStore<GeofencesFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<GeofencesFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}

/// Location access for geofences (Features/Geofences; mocked in tests). The only place with
/// Always authorization and region registration. No background location updates.
protocol GeofenceSystem: Sendable {
    func servicesEnabled() async -> Bool
    func isMonitoringAvailable() async -> Bool
    /// Reads the status without any prompt.
    func permission() async -> LocationPermission
    func requestWhenInUseAuthorization() async -> LocationPermission
    /// Only after «Зарегистрировать геозону» (or the Capability Lab button).
    func requestAlwaysPermission() async -> LocationPermission
    /// One current fix for the preview.
    func currentFix() async throws -> LocationFix
    func registeredRegionIdentifiers() async -> Set<String>
    func registerRegion(identifier: String, latitude: Double, longitude: Double, radiusMeters: Double) async throws
    func unregisterRegion(identifier: String) async
    /// Region crossings. Delivered on any thread; buffered until a handler is set.
    func setTransitionHandler(_ handler: @escaping @Sendable (String, GeofenceTransition) -> Void) async
}
