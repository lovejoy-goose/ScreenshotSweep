import Foundation

/// How an NFC action reached the preview (D-048). Raw values are wire values.
enum NFCActionSource: String, Codable, CaseIterable, Sendable {
    /// Shortcuts NFC automation → URL v3 link.
    case shortcut
    /// Native Core NFC scan in Connector (requires the NFC entitlement, D-046).
    case coreNFC = "core_nfc"
}

enum NFCActionResult: String, Codable, CaseIterable, Sendable {
    /// «Выполнить».
    case confirmed
    /// «Отклонить».
    case declined
}

/// An NFC action registered on this iPhone from a Katana action draft. Only the opaque action
/// ID and the label from Katana — never a tag UID or NDEF payload.
struct NFCActionRegistration: Codable, Equatable, Identifiable, Sendable {
    /// Registrations expire after a year; Katana can issue a new draft.
    static let lifetime: TimeInterval = 365 * 24 * 60 * 60

    let actionID: UUID
    let label: String
    let createdAt: Date
    let expiresAt: Date
    var enabled: Bool
    let sourceDraftID: UUID

    var id: UUID { actionID }

    func isExpired(at date: Date) -> Bool { date >= expiresAt }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case label
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case enabled
        case sourceDraftID = "source_draft_id"
    }
}

/// A run shown in the preview and not decided yet. Persisted so a second tap reuses it and a
/// relaunch restores it (then `interrupted`).
struct NFCPendingExecution: Codable, Equatable, Sendable {
    /// A second trigger within this window shows the same run.
    static let reuseWindow: TimeInterval = 120
    /// Older pending runs are dropped on launch without an event.
    static let maxAge: TimeInterval = 600

    let executionID: UUID
    let actionID: UUID
    let source: NFCActionSource
    let openedAt: Date
    var restored: Bool

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case actionID = "action_id"
        case source
        case openedAt = "opened_at"
        case restored
    }
}

/// A decided run: the event and its delivery bookkeeping. No tag data.
struct NFCCompletedExecution: Codable, Equatable, Identifiable, Sendable {
    let executionID: UUID
    let actionID: UUID
    let eventID: UUID
    let source: NFCActionSource
    let confirmedAt: Date
    let result: NFCActionResult
    let interrupted: Bool
    var eventSaved: Bool

    var id: UUID { executionID }

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case actionID = "action_id"
        case eventID = "event_id"
        case source
        case confirmedAt = "confirmed_at"
        case result
        case interrupted
        case eventSaved = "event_saved"
    }

    private struct Payload: Encodable {
        let actionID: UUID
        let executionID: UUID
        let source: NFCActionSource
        let confirmedAt: Date
        let result: NFCActionResult
        let interrupted: Bool

        enum CodingKeys: String, CodingKey {
            case actionID = "action_id"
            case executionID = "execution_id"
            case source
            case confirmedAt = "confirmed_at"
            case result
            case interrupted
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(actionID.uuidString.lowercased(), forKey: .actionID)
            try container.encode(executionID.uuidString.lowercased(), forKey: .executionID)
            try container.encode(source, forKey: .source)
            try container.encode(confirmedAt, forKey: .confirmedAt)
            try container.encode(result, forKey: .result)
            try container.encode(interrupted, forKey: .interrupted)
        }
    }

    /// `nfc.action.completed` — envelope `session_id` is the execution ID.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.nfcActionCompleted, eventID: eventID, occurredAt: confirmedAt, sessionID: executionID,
                                         payload: Payload(actionID: actionID, executionID: executionID, source: source,
                                                          confirmedAt: confirmedAt, result: result, interrupted: interrupted))
    }
}

/// `nfc-actions.json` (D-052), format v1. No UID, no NDEF payload, no tokens.
struct NFCActionsFile: VersionedFileFormat {
    static let currentVersion = 1
    static let fileName = "nfc-actions.json"
    static let directoryName = "NFCActions"
    static let maxRegistrations = 50
    static let maxExecutions = 50
    static var empty: NFCActionsFile { NFCActionsFile() }

    var version = NFCActionsFile.currentVersion
    var registrations: [NFCActionRegistration] = []
    var pending: [NFCPendingExecution] = []
    var executions: [NFCCompletedExecution] = []

    static func applicationSupportStore() -> VersionedJSONFileStore<NFCActionsFile> {
        VersionedJSONFileStore(directoryURL: VersionedJSONFileStore<NFCActionsFile>.applicationSupportDirectory(directoryName),
                               fileName: fileName)
    }
}

// MARK: - Native Core NFC (gated, D-046)

/// Whether this build is provisioned for Core NFC. The main IPA of v0.3 has neither the NFC
/// entitlement nor `NFCReaderUsageDescription`, so native NFC is off and the UI says
/// `requires_entitlement`; Shortcuts + NFC is the working path.
enum CoreNFCAvailability {
    static let entitlementConfigured = false
    static let usageDescriptionKey = "NFCReaderUsageDescription"
}

enum CoreNFCStatus: Equatable, Sendable {
    case available
    case requiresEntitlement
    case unsupportedDevice
}

/// What a scan yields — only a Katana action link, never the tag UID or the raw NDEF message.
enum NFCReadResult: Equatable, Sendable {
    case actionLink(URL)
    /// The tag has content, but not a Katana action link; nothing of it is kept.
    case notKatana
    case empty
}

enum NFCTagError: Error, Equatable, Sendable {
    /// The user closed the system NFC sheet: a normal outcome, not an error to report.
    case cancelled
    case readOnly
    case unsupportedTag
    case tooSmall
    case notAvailable
    case systemError
}

/// Native Core NFC adapter (Features/NFCActions; mocked in tests). Never locks a tag.
protocol NFCTagSystem: Sendable {
    func status() async -> CoreNFCStatus
    /// One NDEF tag; the session ends after it.
    func readActionLink() async throws -> NFCReadResult
    /// Writes one URI record with `url` after checking the tag is NDEF read-write.
    func writeActionLink(_ url: URL) async throws
}
