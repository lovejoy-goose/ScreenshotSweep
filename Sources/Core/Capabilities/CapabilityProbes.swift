import Foundation

/// One manual Capability Lab check. The coordinator calls the steps in order:
/// availability → authorization → (request, only if not requested yet) → check with timeout.
protocol CapabilityProbe: Sendable {
    var id: CapabilityID { get }
    /// Upper bound for `check()`; permission prompts are not limited.
    var timeout: TimeInterval { get }
    func availability() async -> CapabilityAvailability
    /// Current status, no prompt.
    func authorization() async -> CapabilityAuthorization
    /// Shows this probe's own system prompt and returns the resulting status.
    func requestAuthorization() async -> CapabilityAuthorization
    /// The minimal real check; returns the success detail.
    func check() async throws -> CapabilityProbeDetail
}

struct CameraProbe: CapabilityProbe {
    let id = CapabilityID.camera
    let timeout: TimeInterval = 10
    let system: any CameraSystem

    func availability() async -> CapabilityAvailability {
        await system.hasCamera() ? .available : .unsupportedDevice
    }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.camera(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        await system.requestAccess()
        return await authorization()
    }

    func check() async throws -> CapabilityProbeDetail {
        try await system.captureOneFrame()
        return .cameraFrameReceived
    }
}

struct CurrentLocationProbe: CapabilityProbe {
    let id = CapabilityID.currentLocation
    let timeout: TimeInterval = 20
    let system: any LocationSystem

    func availability() async -> CapabilityAvailability { .available }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.location(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.location(await system.requestWhenInUseAuthorization())
    }

    func check() async throws -> CapabilityProbeDetail {
        try await system.receiveOneFix()
        return .locationFixReceived
    }
}

struct MotionProbe: CapabilityProbe {
    let id = CapabilityID.motion
    let timeout: TimeInterval = 15
    let system: any MotionSystem

    func availability() async -> CapabilityAvailability {
        await system.isActivityAvailable() ? .available : .unsupportedDevice
    }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.motion(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.motion(await system.requestAuthorization())
    }

    func check() async throws -> CapabilityProbeDetail {
        try await system.receiveOneSample()
        return .motionSampleReceived
    }
}

struct LocalNotificationsProbe: CapabilityProbe {
    let id = CapabilityID.localNotifications
    let timeout: TimeInterval = 10
    let system: any NotificationSystem

    func availability() async -> CapabilityAvailability { .available }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.notifications(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        try? await system.requestAuthorization()
        return await authorization()
    }

    /// Confirms permission and successful scheduling — not that the banner was shown.
    func check() async throws -> CapabilityProbeDetail {
        try await system.schedule(.make())
        return .testNotificationScheduled
    }
}

/// v0.3: is «Всегда» granted? Asks for it only from this probe's button (D-051).
struct LocationAlwaysProbe: CapabilityProbe {
    let id = CapabilityID.locationAlways
    let timeout: TimeInterval = 10
    let system: any LocationAlwaysSystem

    func availability() async -> CapabilityAvailability { .available }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.locationAlways(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.locationAlways(await system.requestAlwaysPermission())
    }

    /// With When In Use, iOS may offer the upgrade once; otherwise only Settings can change it.
    func check() async throws -> CapabilityProbeDetail {
        var permission = await system.permission()
        if permission == .authorizedWhenInUse { permission = await system.requestAlwaysPermission() }
        guard permission == .authorizedAlways else { throw CapabilityProbeError.requiresSettings }
        return .alwaysAuthorized
    }
}

/// v0.3: can geofences work here (device support and «Всегда»)? Registers no region.
struct RegionMonitoringProbe: CapabilityProbe {
    let id = CapabilityID.regionMonitoring
    let timeout: TimeInterval = 10
    let system: any LocationAlwaysSystem

    func availability() async -> CapabilityAvailability {
        await system.isMonitoringAvailable() ? .available : .unsupportedDevice
    }

    func authorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.locationAlways(await system.permission())
    }

    func requestAuthorization() async -> CapabilityAuthorization {
        CapabilityAuthorizationMapping.locationAlways(await system.requestAlwaysPermission())
    }

    func check() async throws -> CapabilityProbeDetail {
        guard await system.permission() == .authorizedAlways else { throw CapabilityProbeError.requiresSettings }
        return .regionMonitoringAvailable
    }
}

