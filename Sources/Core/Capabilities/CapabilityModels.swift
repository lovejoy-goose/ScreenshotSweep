import Foundation

// A capability is described by three independent dimensions:
// whether the app can offer it at all (availability), what the user/system allowed
// (authorization), and whether a manual probe has confirmed it works (probe state).
// Raw values are wire values (snake_case) and must never change once shipped.

/// Can this build on this device offer the capability at all.
enum CapabilityAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case planned
    case missingEntitlement = "missing_entitlement"
    case unsupportedDevice = "unsupported_device"
}

/// Permission state as reported by the system. `unknown` means it has not been checked.
enum CapabilityAuthorization: String, Codable, CaseIterable, Sendable {
    case unknown
    case notRequired = "not_required"
    case notRequested = "not_requested"
    case granted
    case limited
    case denied
    case restricted
}

/// Result of the last manual probe (Capability Lab).
enum CapabilityProbeState: String, Codable, CaseIterable, Sendable {
    case notRun = "not_run"
    case passed
    case failed
}

/// Grouping used for display only.
enum CapabilityCategory: String, Codable, CaseIterable, Sendable {
    case media
    case documents
    case location
    case sensors
    case notifications
    case connectivity
    case personalData = "personal_data"
    case security
    case health
}

/// Static description of a capability: what it is, not its current state.
struct CapabilityDescriptor: Codable, Equatable, Sendable {
    let id: CapabilityID
    let title: String
    let category: CapabilityCategory
}

/// Current state of one capability. Contains no user data.
struct CapabilitySnapshot: Codable, Equatable, Sendable {
    let id: CapabilityID
    var availability: CapabilityAvailability
    var authorization: CapabilityAuthorization
    var probeState: CapabilityProbeState
    var checkedAt: Date?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case availability
        case authorization
        case probeState = "probe_state"
        case checkedAt = "checked_at"
        case detail
    }
}
