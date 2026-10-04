import Foundation

/// What the user chose to send (D-040). Raw values are wire values.
enum CheckInPrecision: String, Codable, CaseIterable, Sendable {
    /// Rounded to 2 decimal places (≈1 km).
    case approximate
    /// At most 6 decimal places.
    case precise

    var fractionDigits: Int {
        switch self {
        case .approximate: return 2
        case .precise: return 6
        }
    }
}

/// Horizontal accuracy as a bucket — the raw accuracy is never sent as a number.
enum HorizontalAccuracyBucket: String, Codable, CaseIterable, Sendable {
    case under25m = "under_25m"
    case under100m = "under_100m"
    case under1km = "under_1km"
    case over1km = "over_1km"
    case unknown

    /// Negative or non-finite accuracy means the system did not know it.
    init(accuracyMeters accuracy: Double) {
        guard accuracy.isFinite, accuracy >= 0 else {
            self = .unknown
            return
        }
        switch accuracy {
        case ..<25: self = .under25m
        case ..<100: self = .under100m
        case ..<1000: self = .under1km
        default: self = .over1km
        }
    }
}

enum CoordinateRounding {
    /// Rounds the shortest decimal spelling of `value` half away from zero, so 0.125 → 0.13
    /// regardless of binary floating-point noise.
    static func round(_ value: Double, fractionDigits: Int) -> Double {
        guard value.isFinite else { return value }
        let decimal = NSDecimalNumber(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
        let behavior = NSDecimalNumberHandler(roundingMode: .plain, scale: Int16(fractionDigits), raiseOnExactness: false,
                                              raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)
        let rounded = decimal.rounding(accordingToBehavior: behavior)
        // `doubleValue` is not exact (55.76 → 55.760000000000005); the shortest decimal spelling is.
        return Double(rounded.stringValue) ?? rounded.doubleValue
    }

    /// Decimal places in the shortest spelling of `value`.
    static func fractionDigits(of value: Double) -> Int {
        guard value.isFinite, let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            return Int.max
        }
        return max(0, -Int(decimal.exponent))
    }
}

/// One location fix as handed over by the adapter: coordinates and horizontal accuracy only —
/// no altitude, speed, course, floor or timestamp. Kept in memory only, never logged.
struct LocationFix: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double

    var description: String { "LocationFix(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [Mirror.Child](), displayStyle: .struct) }
}

/// Current Location adapter for check-ins (implemented in Features, mocked in tests).
/// When In Use only: there is deliberately no API for any broader or background location.
protocol CheckInLocationSystem: Sendable {
    func servicesEnabled() async -> Bool
    /// Reads the status without any prompt.
    func permission() async -> LocationPermission
    /// Shows the When In Use prompt (only after the user's button, only if not requested yet).
    func requestWhenInUseAuthorization() async -> LocationPermission
    /// One current fix; updates stop right after it.
    func currentFix() async throws -> LocationFix
}

/// The fix waiting for the user's decision. Lives only in memory, at most `lifetime`.
struct CheckInPreview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let lifetime: TimeInterval = 300

    let checkInID: UUID
    let eventID: UUID
    /// When the fix arrived (whole seconds).
    let occurredAt: Date
    let expiresAt: Date
    let accuracyBucket: HorizontalAccuracyBucket
    private let fix: LocationFix

    init(checkInID: UUID = UUID(), eventID: UUID = UUID(), fix: LocationFix, receivedAt: Date) {
        self.checkInID = checkInID
        self.eventID = eventID
        self.occurredAt = WholeSeconds.floor(receivedAt)
        self.expiresAt = occurredAt.addingTimeInterval(Self.lifetime)
        self.accuracyBucket = HorizontalAccuracyBucket(accuracyMeters: fix.horizontalAccuracy)
        self.fix = fix
    }

    /// Exactly the coordinates that would be sent with `precision`.
    func coordinates(_ precision: CheckInPrecision) -> (latitude: Double, longitude: Double) {
        (CoordinateRounding.round(fix.latitude, fractionDigits: precision.fractionDigits),
         CoordinateRounding.round(fix.longitude, fractionDigits: precision.fractionDigits))
    }

    func isExpired(at date: Date) -> Bool { date > expiresAt }

    /// `location.check_in.created`, rounded before it can reach the queue.
    func makeEvent(precision: CheckInPrecision, labelRequested: Bool) throws -> ConnectorEvent {
        let (latitude, longitude) = coordinates(precision)
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              CoordinateRounding.fractionDigits(of: latitude) <= precision.fractionDigits,
              CoordinateRounding.fractionDigits(of: longitude) <= precision.fractionDigits else {
            throw ContextEventError.invalidPayload
        }
        let payload = LocationCheckInPayload(checkInID: checkInID, occurredAt: occurredAt, latitude: latitude,
                                             longitude: longitude, precision: precision,
                                             accuracyBucket: accuracyBucket, labelRequested: labelRequested)
        return try ContextEventSchema.makeEvent(.locationCheckIn, eventID: eventID, occurredAt: occurredAt,
                                                sessionID: checkInID, payload: payload)
    }

    var description: String { "CheckInPreview(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["occurredAt": occurredAt, "accuracyBucket": accuracyBucket], displayStyle: .struct)
    }
}

private struct LocationCheckInPayload: Encodable {
    let checkInID: UUID
    let occurredAt: Date
    let latitude: Double
    let longitude: Double
    let precision: CheckInPrecision
    let accuracyBucket: HorizontalAccuracyBucket
    let labelRequested: Bool

    enum CodingKeys: String, CodingKey {
        case checkInID = "check_in_id"
        case occurredAt = "occurred_at"
        case latitude, longitude, precision
        case accuracyBucket = "horizontal_accuracy_bucket"
        case labelRequested = "label_requested"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checkInID.uuidString.lowercased(), forKey: .checkInID)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(precision, forKey: .precision)
        try container.encode(accuracyBucket, forKey: .accuracyBucket)
        try container.encode(labelRequested, forKey: .labelRequested)
    }
}

/// A sent check-in as kept in the local history: no coordinates.
struct CheckInHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let checkInID: UUID
    let eventID: UUID
    let occurredAt: Date
    let precision: CheckInPrecision
    let accuracyBucket: HorizontalAccuracyBucket
    let labelRequested: Bool

    var id: UUID { checkInID }

    enum CodingKeys: String, CodingKey {
        case checkInID = "check_in_id"
        case eventID = "event_id"
        case occurredAt = "occurred_at"
        case precision
        case accuracyBucket = "horizontal_accuracy_bucket"
        case labelRequested = "label_requested"
    }
}

/// `check-ins.json` (D-043), format v1. History only — never coordinates.
struct CheckInHistoryFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "check-ins.json"
    static let directoryName = "LocationCheckIn"
    static let maxHistory = 50
    static var empty: CheckInHistoryFile { CheckInHistoryFile() }

    var version = CheckInHistoryFile.currentVersion
    var history: [CheckInHistoryEntry] = []

    static func applicationSupportStore() -> VersionedJSONFileStore<CheckInHistoryFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<CheckInHistoryFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}
