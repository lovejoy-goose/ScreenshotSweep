import XCTest

final class MockLocationAlwaysSystem: LocationAlwaysSystem, @unchecked Sendable {
    private let lock = NSLock()
    let log = CallLog()
    var status: LocationPermission = .notDetermined
    var statusAfterRequest: LocationPermission = .authorizedAlways
    var monitoringAvailable = true

    func permission() async -> LocationPermission { lock.lock(); defer { lock.unlock() }; return status }

    func requestAlwaysPermission() async -> LocationPermission {
        log.hit("requestAlways")
        lock.lock(); defer { lock.unlock() }
        status = statusAfterRequest
        return status
    }

    func isMonitoringAvailable() async -> Bool { monitoringAvailable }
}

/// V3-006: Capability Lab probes for «Всегда» and region monitoring, gated capabilities.
final class CapabilityTriggerProbeTests: XCTestCase {
    private var directory: URL!
    private var system: MockLocationAlwaysSystem!

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("TriggerProbes")
        system = MockLocationAlwaysSystem()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func makeLab() -> CapabilityLabCoordinator {
        CapabilityLabCoordinator(store: CapabilitySnapshotStore(directoryURL: directory),
                                 probes: [LocationAlwaysProbe(system: system), RegionMonitoringProbe(system: system)],
                                 sleeper: NeverSleeper(), now: { Fixtures.pairedAt })
    }

    @MainActor
    private func run(_ lab: CapabilityLabCoordinator, _ id: CapabilityID) async -> CapabilitySnapshot {
        lab.start(id)
        await lab.waitForProbe(id)
        return lab.snapshot(for: id)
    }

    @MainActor
    func testRefreshNeverAsksAndShowsSeparateDimensions() async {
        let lab = makeLab()
        await lab.refreshAuthorizations()
        XCTAssertEqual(system.log.count("requestAlways"), 0, "launch/foreground never asks for «Всегда»")
        let always = lab.snapshot(for: .locationAlways)
        XCTAssertEqual(always.availability, .available)
        XCTAssertEqual(always.authorization, .notRequested)
        XCTAssertEqual(always.probeState, .notRun)
        system.status = .authorizedWhenInUse
        await lab.refreshAuthorizations()
        XCTAssertEqual(lab.snapshot(for: .locationAlways).authorization, .limited, "When In Use is a partial grant")
        system.monitoringAvailable = false
        await lab.refreshAuthorizations()
        XCTAssertEqual(lab.snapshot(for: .regionMonitoring).availability, .unsupportedDevice)
    }

    @MainActor
    func testAlwaysProbeAsksOnlyFromItsButton() async {
        let lab = makeLab()
        let passed = await run(lab, .locationAlways)
        XCTAssertEqual(system.log.count("requestAlways"), 1)
        XCTAssertEqual([passed.authorization.rawValue, passed.probeState.rawValue, passed.detail], ["granted", "passed", "always_authorized"])

        system.status = .authorizedWhenInUse
        system.statusAfterRequest = .authorizedWhenInUse   // upgrade declined or not offered
        let declined = await run(lab, .locationAlways)
        XCTAssertEqual([declined.probeState.rawValue, declined.detail], ["failed", "requires_settings"])
        XCTAssertEqual(declined.authorization, .limited)

        system.status = .denied
        let denied = await run(lab, .locationAlways)
        XCTAssertEqual([denied.authorization.rawValue, denied.detail], ["denied", "permission_denied"])
    }

    @MainActor
    func testRegionMonitoringProbeRegistersNothing() async {
        system.status = .authorizedAlways
        let lab = makeLab()
        let passed = await run(lab, .regionMonitoring)
        XCTAssertEqual([passed.probeState.rawValue, passed.detail], ["passed", "region_monitoring_available"])
        XCTAssertEqual(system.log.count("requestAlways"), 0)

        system.status = .authorizedWhenInUse
        let partial = await run(lab, .regionMonitoring)
        XCTAssertEqual(partial.detail, "requires_settings")

        system.monitoringAvailable = false
        let unsupported = await run(lab, .regionMonitoring)
        XCTAssertEqual([unsupported.availability.rawValue, unsupported.detail], ["unsupported_device", "unavailable"])
    }

    func testGatedCapabilitiesAreHonest() {
        let registry = CapabilityRegistry()
        for id in [CapabilityID.coreNFC, .coreNFCWrite, .appGroup, .shareExtension] {
            XCTAssertEqual(registry.snapshot(for: id).availability, .missingEntitlement, "\(id)")
        }
        XCTAssertEqual(registry.snapshot(for: .backgroundLocation).availability, .planned, "not used by geofences")
        XCTAssertEqual(CapabilityLabCoordinator.triggerCapabilities, [.locationAlways, .regionMonitoring])
        XCTAssertEqual(CapabilityLabCoordinator.labCapabilities, [.camera, .currentLocation, .motion, .localNotifications],
                       "the v0.1 probes are unchanged")
        XCTAssertTrue(Set(CapabilityLabCoordinator.gatedCapabilities).isDisjoint(with: CapabilityLabCoordinator.allProbeCapabilities),
                      "gated capabilities have no probe button")
        XCTAssertEqual(CapabilityAuthorizationMapping.locationAlways(.authorizedWhenInUse), .limited)
        XCTAssertEqual(CapabilityAuthorizationMapping.locationAlways(.authorizedAlways), .granted)
        XCTAssertEqual(CapabilityAuthorizationMapping.location(.authorizedWhenInUse), .granted, "v0.1 mapping unchanged")
    }
}
