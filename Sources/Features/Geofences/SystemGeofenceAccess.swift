import CoreLocation
import UIKit

/// Geofence adapter (D-049): the only place with Always authorization and region registration.
/// Only latitude, longitude and horizontal accuracy of the preview fix leave this type. No
/// background location updates and no significant-change service.
@MainActor
final class SystemGeofenceAccess: NSObject, GeofenceSystem, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWait: ProbeOneShot?
    private var fixWait: ProbeOneShot?
    private var fix: LocationFix?
    private var handler: (@Sendable (String, GeofenceTransition) -> Void)?
    /// Crossings delivered before a handler was set (e.g. right after a background relaunch).
    private var buffered: [(String, GeofenceTransition)] = []

    override init() {
        super.init()
        // The delegate is set at launch so iOS can deliver a crossing that relaunched the app.
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Off the main thread, as Apple recommends for this call.
    func servicesEnabled() async -> Bool {
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    func isMonitoringAvailable() async -> Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
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

    /// iOS shows the «Всегда» prompt at most once and reports nothing if it does not show it, so
    /// the wait also ends when the app did not resign active shortly after the request, or when
    /// it became active again after the prompt.
    func requestAlwaysPermission() async -> LocationPermission {
        let before = manager.authorizationStatus
        guard before == .notDetermined || before == .authorizedWhenInUse else { return Self.map(before) }
        let wait = ProbeOneShot()
        authorizationWait = wait
        let flag = ResignFlag()
        let center = NotificationCenter.default
        let resignToken = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            flag.resigned = true
        }
        let activeToken = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if flag.resigned { wait.resolve(.success(())) }
        }
        manager.requestAlwaysAuthorization()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !flag.resigned { wait.resolve(.success(())) }
        }
        try? await wait.wait()
        center.removeObserver(resignToken)
        center.removeObserver(activeToken)
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
        manager.requestLocation()
        try await wait.wait()
        guard let fix else { throw CapabilityProbeError.systemError }
        return fix
    }

    func registeredRegionIdentifiers() async -> Set<String> {
        Set(manager.monitoredRegions.map(\.identifier))
    }

    func registerRegion(identifier: String, latitude: Double, longitude: Double, radiusMeters: Double) async throws {
        guard identifier.hasPrefix(GeofenceRules.regionIdentifierPrefix + "."),
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            throw CapabilityProbeError.unavailable
        }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                      radius: min(radiusMeters, manager.maximumRegionMonitoringDistance),
                                      identifier: identifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    /// Only regions of Connector are ever touched.
    func unregisterRegion(identifier: String) async {
        guard identifier.hasPrefix(GeofenceRules.regionIdentifierPrefix + ".") else { return }
        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
        }
    }

    func setTransitionHandler(_ handler: @escaping @Sendable (String, GeofenceTransition) -> Void) async {
        self.handler = handler
        let pending = buffered
        buffered = []
        for (identifier, transition) in pending { handler(identifier, transition) }
    }

    private func deliver(_ identifier: String, _ transition: GeofenceTransition) {
        guard identifier.hasPrefix(GeofenceRules.regionIdentifierPrefix + ".") else { return }
        if let handler {
            handler(identifier, transition)
        } else {
            buffered.append((identifier, transition))
        }
    }

    // MARK: CLLocationManagerDelegate

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

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor in self.deliver(identifier, .enter) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor in self.deliver(identifier, .exit) }
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

private final class ResignFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var resigned: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
