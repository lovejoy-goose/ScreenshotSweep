import CoreLocation

/// Location Check-in adapter: When In Use authorization and one fix via `requestLocation`.
/// Only latitude, longitude and horizontal accuracy leave this type; no other property of the
/// fix is read. No background location, no region or significant-change APIs.
@MainActor
final class SystemCheckInLocationAccess: NSObject, CheckInLocationSystem, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWait: ProbeOneShot?
    private var fixWait: ProbeOneShot?
    private var fix: LocationFix?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Off the main thread, as Apple recommends for this call.
    func servicesEnabled() async -> Bool {
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    func permission() async -> LocationPermission {
        Self.map(manager.authorizationStatus)
    }

    func requestWhenInUseAuthorization() async -> LocationPermission {
        guard manager.authorizationStatus == .notDetermined else { return Self.map(manager.authorizationStatus) }
        let wait = ProbeOneShot()
        authorizationWait = wait
        manager.requestWhenInUseAuthorization()
        try? await wait.wait()
        authorizationWait = nil
        return Self.map(manager.authorizationStatus)
    }

    func currentFix() async throws -> LocationFix {
        let wait = ProbeOneShot()
        fixWait = wait
        fix = nil
        defer {
            manager.stopUpdatingLocation()
            fixWait = nil
            fix = nil
        }
        // One-shot request: Core Location stops by itself after the first fix.
        manager.requestLocation()
        try await wait.wait()
        guard let fix else { throw CapabilityProbeError.systemError }
        return fix
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in self.authorizationWait?.resolve(.success(())) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        guard let location = locations.last else { return }
        let reduced = LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                  horizontalAccuracy: location.horizontalAccuracy)
        Task { @MainActor in
            guard self.fix == nil else { return }
            self.fix = reduced
            self.fixWait?.resolve(.success(()))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        let failure: CapabilityProbeError = (error as? CLError)?.code == .denied ? .permissionDenied : .systemError
        Task { @MainActor in self.fixWait?.resolve(.failure(failure)) }
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
