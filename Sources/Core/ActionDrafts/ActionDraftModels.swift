import Foundation

/// Kinds of server-prepared actions (D-047). Raw values are wire values.
enum ActionDraftKind: String, Codable, CaseIterable, Sendable {
    case nfcAction = "nfc_action"
    case geofenceCreate = "geofence_create"
    case sharedCapture = "shared_capture"
}

struct NFCActionDraftPayload: Equatable, Sendable {
    static let maxLabelScalars = 60
    let actionID: UUID
    let label: String
}

struct GeofenceDraftPayload: Equatable, Sendable {
    /// Already rounded to `GeofenceRules.coordinateFractionDigits`.
    let latitude: Double
    let longitude: Double
    let radiusMeters: Int
    let nameSuggestion: String
}

struct CaptureDraftPayload: Equatable, Sendable {
    static let maxPromptScalars = 200
    let acceptedKinds: [CaptureKind]
    let prompt: String
}

enum ActionDraftPayload: Equatable, Sendable {
    case nfcAction(NFCActionDraftPayload)
    case geofenceCreate(GeofenceDraftPayload)
    case sharedCapture(CaptureDraftPayload)

    var kind: ActionDraftKind {
        switch self {
        case .nfcAction: return .nfcAction
        case .geofenceCreate: return .geofenceCreate
        case .sharedCapture: return .sharedCapture
        }
    }
}

/// A validated action draft. Its content is never logged.
struct ActionDraft: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Longest accepted lifetime, measured on the server clock.
    static let maxLifetime: TimeInterval = 7 * 24 * 60 * 60

    let draftID: UUID
    let serverTime: Date
    let expiresAt: Date
    let payload: ActionDraftPayload

    var kind: ActionDraftKind { payload.kind }

    /// TTL on the server clock: `serverTime` plus the time elapsed on this iPhone since loading.
    /// The iPhone's absolute clock is never compared with `expiresAt`.
    func isExpired(elapsedSinceLoad: TimeInterval) -> Bool {
        serverTime.addingTimeInterval(max(0, elapsedSinceLoad)) >= expiresAt
    }

    var description: String { "ActionDraft(\(kind.rawValue), \(draftID.uuidString.lowercased()))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["draftID": draftID, "kind": kind], displayStyle: .struct) }
}

/// Typed outcome of `GET /api/connector/action-drafts/{draft_id}`. Carries no bodies or tokens.
enum ActionDraftError: Error, Equatable, Sendable {
    case notPaired
    case unauthorized
    case notFound
    case expired
    case consumed
    case offline
    case rateLimited
    case serverError
    case invalidResponse

    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .serverError: return true
        default: return false
        }
    }

    static func classify(statusCode: Int) -> ActionDraftError? {
        switch statusCode {
        case 200...299: return nil
        case 401: return .unauthorized
        case 403, 404: return .notFound
        case 408: return .offline
        case 409: return .consumed
        case 410: return .expired
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .invalidResponse
        }
    }
}

/// Strict parser: exactly the documented keys at every level; anything unknown or missing is
/// `invalidResponse`. TTL is checked against `server_time` only.
enum ActionDraftParser {
    static let topLevelKeys: Set<String> = ["draft_id", "kind", "server_time", "expires_at", "payload"]

    static func payloadKeys(_ kind: ActionDraftKind) -> Set<String> {
        switch kind {
        case .nfcAction: return ["action_id", "label"]
        case .geofenceCreate: return ["latitude", "longitude", "radius_m", "name_suggestion"]
        case .sharedCapture: return ["accepted_kinds", "prompt"]
        }
    }

    static func parse(_ data: Data, requestedID: UUID) throws -> ActionDraft {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == topLevelKeys,
              let idText = object["draft_id"] as? String, ConnectorURLRouter.canonicalUUID(idText) == requestedID,
              let kindText = object["kind"] as? String, let kind = ActionDraftKind(rawValue: kindText),
              let serverTime = date(object["server_time"]), let expiresAt = date(object["expires_at"]),
              let payloadObject = object["payload"] as? [String: Any],
              Set(payloadObject.keys) == payloadKeys(kind) else {
            throw ActionDraftError.invalidResponse
        }
        let payload = try parsePayload(kind, payloadObject)
        guard expiresAt.timeIntervalSince(serverTime) <= ActionDraft.maxLifetime else { throw ActionDraftError.invalidResponse }
        let draft = ActionDraft(draftID: requestedID, serverTime: serverTime, expiresAt: expiresAt, payload: payload)
        guard !draft.isExpired(elapsedSinceLoad: 0) else { throw ActionDraftError.expired }
        return draft
    }

    private static func parsePayload(_ kind: ActionDraftKind, _ object: [String: Any]) throws -> ActionDraftPayload {
        switch kind {
        case .nfcAction:
            guard let idText = object["action_id"] as? String, let actionID = ConnectorURLRouter.canonicalUUID(idText),
                  let label = object["label"] as? String,
                  SafeText.isValidLine(label, maxScalars: NFCActionDraftPayload.maxLabelScalars) else {
                throw ActionDraftError.invalidResponse
            }
            return .nfcAction(NFCActionDraftPayload(actionID: actionID, label: label))
        case .geofenceCreate:
            guard let latitude = number(object["latitude"]), let longitude = number(object["longitude"]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  let radius = integer(object["radius_m"]), GeofenceRules.allowedRadii.contains(radius),
                  let name = object["name_suggestion"] as? String,
                  SafeText.isValidLine(name, maxScalars: GeofenceRules.maxNameScalars) else {
                throw ActionDraftError.invalidResponse
            }
            let digits = GeofenceRules.coordinateFractionDigits
            return .geofenceCreate(GeofenceDraftPayload(latitude: CoordinateRounding.round(latitude, fractionDigits: digits),
                                                        longitude: CoordinateRounding.round(longitude, fractionDigits: digits),
                                                        radiusMeters: radius, nameSuggestion: name))
        case .sharedCapture:
            guard let rawKinds = object["accepted_kinds"] as? [Any], !rawKinds.isEmpty,
                  let texts = rawKinds as? [String], Set(texts).count == texts.count,
                  let prompt = object["prompt"] as? String,
                  SafeText.isValidMultiline(prompt, maxScalars: CaptureDraftPayload.maxPromptScalars) else {
                throw ActionDraftError.invalidResponse
            }
            let kinds = texts.compactMap(CaptureKind.init(rawValue:))
            guard kinds.count == texts.count else { throw ActionDraftError.invalidResponse }
            return .sharedCapture(CaptureDraftPayload(acceptedKinds: kinds, prompt: prompt))
        }
    }

    /// A JSON number that is not a boolean.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double == double.rounded(), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Loads a draft (the authenticated API client; mocked in tests).
protocol ActionDraftFetching: Sendable {
    func fetchActionDraft(id: UUID) async throws -> ActionDraft
}

/// A draft this iPhone executed. Kept so it is never executed twice (D-047).
struct AcceptedActionDraft: Codable, Equatable, Identifiable, Sendable {
    let draftID: UUID
    let kind: ActionDraftKind
    let acceptedAt: Date
    /// `action_id`, `geofence_id` or `capture_id`.
    let resultRef: UUID
    let eventID: UUID
    var eventSaved: Bool

    var id: UUID { draftID }

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case kind
        case acceptedAt = "accepted_at"
        case resultRef = "result_ref"
        case eventID = "event_id"
        case eventSaved = "event_saved"
    }

    private struct Payload: Encodable {
        let draftID: UUID
        let kind: ActionDraftKind
        let acceptedAt: Date
        let resultRef: UUID

        enum CodingKeys: String, CodingKey {
            case draftID = "draft_id"
            case kind
            case acceptedAt = "accepted_at"
            case resultRef = "result_ref"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(draftID.uuidString.lowercased(), forKey: .draftID)
            try container.encode(kind, forKey: .kind)
            try container.encode(acceptedAt, forKey: .acceptedAt)
            try container.encode(resultRef.uuidString.lowercased(), forKey: .resultRef)
        }
    }

    /// `action_draft.accepted` — Katana consumes the draft atomically when it accepts this event.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.actionDraftAccepted, eventID: eventID, occurredAt: acceptedAt, sessionID: draftID,
                                         payload: Payload(draftID: draftID, kind: kind, acceptedAt: acceptedAt, resultRef: resultRef))
    }
}

/// `action-drafts.json` (D-052), format v1.
struct ActionDraftStoreFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "action-drafts.json"
    static let directoryName = "ActionDrafts"
    static let maxAccepted = 200
    static var empty: ActionDraftStoreFile { ActionDraftStoreFile() }

    var version = ActionDraftStoreFile.currentVersion
    var accepted: [AcceptedActionDraft] = []

    static func applicationSupportStore() -> VersionedJSONFileStore<ActionDraftStoreFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<ActionDraftStoreFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}
