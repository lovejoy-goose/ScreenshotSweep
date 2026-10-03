import CoreLocation

/// Current Location adapter: When In Use authorization and one fix. The fix (coordinates,
/// altitude, speed, course, accuracy) is never read, stored, shown, logged or sent.
@MainActor
final class SystemLocationAccess: NSObject, LocationSystem, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWait: ProbeOneShot?
    private var fixWait: ProbeOneShot?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func permission() async -> LocationPermission {
        // With Location Services switched off system-wide the app is effectively denied
        // (and no prompt would ever appear).
        guard await Self.servicesEnabled() else { return .denied }
        return Self.map(manager.authorizationStatus)
    }

    func requestWhenInUseAuthorization() async -> LocationPermission {
        guard await Self.servicesEnabled() else { return .denied }
        guard manager.authorizationStatus == .notDetermined else { return Self.map(manager.authorizationStatus) }
        let wait = ProbeOneShot()
        authorizationWait = wait
        manager.requestWhenInUseAuthorization()
        try? await wait.wait()
        authorizationWait = nil
        return Self.map(manager.authorizationStatus)
    }

    func receiveOneFix() async throws {
        let wait = ProbeOneShot()
        fixWait = wait
        defer {
            manager.stopUpdatingLocation()
            fixWait = nil
        }
        // One-shot request: Core Location stops by itself after the first fix.
        manager.requestLocation()
        try await wait.wait()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in self.authorizationWait?.resolve(.success(())) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Only the fact that a fix arrived matters; the locations are not touched.
        manager.stopUpdatingLocation()
        Task { @MainActor in self.fixWait?.resolve(.success(())) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        let failure: CapabilityProbeError = (error as? CLError)?.code == .denied ? .permissionDenied : .systemError
        Task { @MainActor in self.fixWait?.resolve(.failure(failure)) }
    }

    /// Off the main thread, as Apple recommends for this call.
    private static func servicesEnabled() async -> Bool {
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}
