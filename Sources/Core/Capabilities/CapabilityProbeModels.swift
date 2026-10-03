import Foundation

/// Stable, safe outcome codes stored in `CapabilitySnapshot.detail` and sent in the capability
/// report. Never localized text, never raw system errors. Wire values must not change.
enum CapabilityProbeDetail: String, Codable, CaseIterable, Sendable {
    case cameraFrameReceived = "camera_frame_received"
    case locationFixReceived = "location_fix_received"
    case motionSampleReceived = "motion_sample_received"
    case testNotificationScheduled = "test_notification_scheduled"
    case permissionDenied = "permission_denied"
    case permissionRestricted = "permission_restricted"
    case unavailable
    case timedOut = "timed_out"
    case cancelled
    case systemError = "system_error"
}

/// Failures a system adapter may report. Mapped to `CapabilityProbeDetail`; the system error
/// itself is never stored.
enum CapabilityProbeError: Error, Equatable, Sendable {
    case unavailable
    case permissionDenied
    case systemError
}

// MARK: - Neutral permission states reported by adapters

enum CameraPermission: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted, unknown
}

enum LocationPermission: Equatable, Sendable {
    case notDetermined, authorizedWhenInUse, authorizedAlways, denied, restricted, unknown
}

enum MotionPermission: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted, unknown
}

enum NotificationPermission: Equatable, Sendable {
    case notDetermined, authorized, provisional, ephemeral, denied, unknown
}

/// The single mapping from system permission states to `CapabilityAuthorization`.
enum CapabilityAuthorizationMapping {
    static func camera(_ permission: CameraPermission) -> CapabilityAuthorization {
        switch permission {
        case .notDetermined: return .notRequested
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .unknown: return .unknown
        }
    }

    static func location(_ permission: LocationPermission) -> CapabilityAuthorization {
        switch permission {
        case .notDetermined: return .notRequested
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .unknown: return .unknown
        }
    }

    static func motion(_ permission: MotionPermission) -> CapabilityAuthorization {
        switch permission {
        case .notDetermined: return .notRequested
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .unknown: return .unknown
        }
    }

    static func notifications(_ permission: NotificationPermission) -> CapabilityAuthorization {
        switch permission {
        case .notDetermined: return .notRequested
        case .authorized: return .granted
        case .provisional, .ephemeral: return .limited
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

// MARK: - System adapters (implemented in Features/CapabilityLab, mocked in tests)
//
// Every method that touches data returns `Void`: frames, locations and motion samples
// never leave the adapter, so they cannot reach the store, the report or the UI.

protocol CameraSystem: Sendable {
    func hasCamera() async -> Bool
    /// Reads the status without any prompt.
    func permission() async -> CameraPermission
    func requestAccess() async
    /// Starts a minimal capture session, waits for one frame, stops the session and discards the frame.
    func captureOneFrame() async throws
}

protocol LocationSystem: Sendable {
    /// Reads the status without any prompt.
    func permission() async -> LocationPermission
    /// When In Use only. There is deliberately no API for any broader authorization.
    func requestWhenInUseAuthorization() async -> LocationPermission
    /// One current fix; updates stop right after it. The fix itself is discarded.
    func receiveOneFix() async throws
}

protocol MotionSystem: Sendable {
    func isActivityAvailable() async -> Bool
    /// Reads the status without any prompt.
    func permission() async -> MotionPermission
    /// Performs a short, user-initiated motion query that shows the Motion & Fitness prompt.
    func requestAuthorization() async -> MotionPermission
    /// One activity callback; updates stop right after it. The activity itself is discarded.
    func receiveOneSample() async throws
}

/// Neutral local test notification: no user or device data.
struct TestNotificationRequest: Equatable, Sendable {
    static let identifierPrefix = "app.katana.connector.capability-lab.test"

    let identifier: String
    let title: String
    let body: String
    let delay: TimeInterval

    static func make(id: UUID = UUID()) -> TestNotificationRequest {
        TestNotificationRequest(identifier: "\(identifierPrefix).\(id.uuidString.lowercased())",
                                title: "Katana Connector",
                                body: "Тестовое уведомление Capability Lab.",
                                delay: 5)
    }
}

protocol NotificationSystem: Sendable {
    /// Reads the settings without any prompt.
    func permission() async -> NotificationPermission
    func requestAuthorization() async throws
    func schedule(_ request: TestNotificationRequest) async throws
}
