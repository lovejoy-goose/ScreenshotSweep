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
    /// Local opt-in (D-055): an external NFC link runs the action without «Выполнить».
    /// Off by default; set only in Connector; never sent to Katana.
    var autoExecute = false

    var id: UUID { actionID }

    func isExpired(at date: Date) -> Bool { date >= expiresAt }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case label
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case enabled
        case sourceDraftID = "source_draft_id"
        case autoExecute = "auto_execute"
    }
}

extension NFCActionRegistration {
    /// Files written before D-055 have no `auto_execute`: it decodes as off.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try container.decode(UUID.self, forKey: .actionID)
        label = try container.decode(String.self, forKey: .label)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sourceDraftID = try container.decode(UUID.self, forKey: .sourceDraftID)
        autoExecute = try container.decodeIfPresent(Bool.self, forKey: .autoExecute) ?? false
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
    /// Local only (D-055): when the trigger opened this run; repeats within the reuse window
    /// show this result instead of running again.
    var openedAt: Date? = nil
    /// Local only (D-055): ran by the auto-execute opt-in, without «Выполнить». Not sent.
    var autoExecuted = false

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
        case openedAt = "opened_at"
        case autoExecuted = "auto_executed"
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

    /// `nfc.action.completed` — envelope `session_id` is the execution ID. The payload is the
    /// same for manual and automatic runs: the local opt-in never reaches Katana.
    func makeEvent() throws -> ConnectorEvent {
        try ContextEventSchema.makeEvent(.nfcActionCompleted, eventID: eventID, occurredAt: confirmedAt, sessionID: executionID,
                                         payload: Payload(actionID: actionID, executionID: executionID, source: source,
                                                          confirmedAt: confirmedAt, result: result, interrupted: interrupted))
    }
}

extension NFCCompletedExecution {
    /// Files written before D-055 have neither `opened_at` nor `auto_executed`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executionID = try container.decode(UUID.self, forKey: .executionID)
        actionID = try container.decode(UUID.self, forKey: .actionID)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        source = try container.decode(NFCActionSource.self, forKey: .source)
        confirmedAt = try container.decode(Date.self, forKey: .confirmedAt)
        result = try container.decode(NFCActionResult.self, forKey: .result)
        interrupted = try container.decode(Bool.self, forKey: .interrupted)
        eventSaved = try container.decode(Bool.self, forKey: .eventSaved)
        openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt)
        autoExecuted = try container.decodeIfPresent(Bool.self, forKey: .autoExecuted) ?? false
    }
}

/// `nfc-actions.json` (D-052), format v1. D-055 added the optional local keys `auto_execute`
/// (registration) and `opened_at` / `auto_executed` (execution); missing keys decode as off —
/// files of earlier builds load unchanged, no version bump. No UID, no NDEF payload, no tokens.
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
