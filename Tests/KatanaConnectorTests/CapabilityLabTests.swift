import XCTest

// MARK: - Mock system adapters (no hardware, no real permission prompts)

/// What a mocked check does.
enum MockCheck: Sendable {
    case succeed
    /// Suspends until cancelled (to test timeout, cancellation and single-run).
    case hang
    case fail(CapabilityProbeError)

    func run() async throws {
        switch self {
        case .succeed: return
        case .hang: try await Task.sleep(nanoseconds: 60_000_000_000)
        case .fail(let error): throw error
        }
    }
}

/// Blocks only the first call that reaches it until `open()`; later calls pass straight through.
/// Used to hold a passive refresh inside its system status read.
final class FirstCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private var opened = false
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func passIfNeeded() async {
        lock.lock()
        if used || opened {
            lock.unlock()
            return
        }
        used = true
        waiting = true
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting && !opened
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Thread-safe counters shared by the mocks.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var active: Set<String> = []

    func hit(_ name: String) { lock.lock(); counts[name, default: 0] += 1; lock.unlock() }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
    func setActive(_ name: String, _ on: Bool) {
        lock.lock()
        if on { active.insert(name) } else { active.remove(name) }
        lock.unlock()
    }
    func isActive(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return active.contains(name) }
}

final class MockCameraSystem: CameraSystem, @unchecked Sendable {
    let log = CallLog()
    var hasCameraValue = true
    var status: CameraPermission = .notDetermined
    var statusAfterRequest: CameraPermission = .authorized
    var check: MockCheck = .succeed
    /// Stands for frame bytes the real adapter sees; the API cannot return it.
    let frameMarker = "FRAME-BYTES-0xCAFE"

    func hasCamera() async -> Bool { hasCameraValue }
    var permissionGate: FirstCallGate?
    /// The value is read before the (optional) gate, like a real status read that is already in flight.
    func permission() async -> CameraPermission {
        let value = status
        await permissionGate?.passIfNeeded()
        return value
    }
    func requestAccess() async {
        log.hit("request")
        status = statusAfterRequest
    }
    func captureOneFrame() async throws {
        log.hit("capture")
        log.setActive("session", true)
        defer { log.setActive("session", false) }
        try await check.run()
    }
}

final class MockLocationSystem: LocationSystem, @unchecked Sendable {
    let log = CallLog()
    var status: LocationPermission = .notDetermined
    var statusAfterRequest: LocationPermission = .authorizedWhenInUse
    var check: MockCheck = .succeed
    /// Stands for a real fix; the API cannot return it.
    let secretFix = "55.755826,37.6173"

    var permissionGate: FirstCallGate?
    func permission() async -> LocationPermission {
        let value = status
        await permissionGate?.passIfNeeded()
        return value
    }
    func requestWhenInUseAuthorization() async -> LocationPermission {
        log.hit("requestWhenInUse")
        status = statusAfterRequest
        return status
    }
    func receiveOneFix() async throws {
        log.hit("fix")
        log.setActive("updates", true)
        defer { log.setActive("updates", false) }
        try await check.run()
    }
}

final class MockMotionSystem: MotionSystem, @unchecked Sendable {
    let log = CallLog()
    var available = true
    var status: MotionPermission = .notDetermined
    var statusAfterRequest: MotionPermission = .authorized
    var check: MockCheck = .succeed
    /// Stands for a real activity sample; the API cannot return it.
    let secretActivity = "automotive-walking-steps-1234"

    func isActivityAvailable() async -> Bool { available }
    var permissionGate: FirstCallGate?
    func permission() async -> MotionPermission {
        let value = status
        await permissionGate?.passIfNeeded()
        return value
    }
    func requestAuthorization() async -> MotionPermission {
        log.hit("request")
        status = statusAfterRequest
        return status
    }
    func receiveOneSample() async throws {
        log.hit("sample")
        log.setActive("updates", true)
        defer { log.setActive("updates", false) }
        try await check.run()
    }
}

final class MockNotificationSystem: NotificationSystem, @unchecked Sendable {
    let log = CallLog()
    var status: NotificationPermission = .notDetermined
    var statusAfterRequest: NotificationPermission = .authorized
    var scheduleError: Error?
    var requestGate: MockCheck = .succeed
    private(set) var scheduled: [TestNotificationRequest] = []

    var permissionGate: FirstCallGate?
    func permission() async -> NotificationPermission {
        let value = status
        await permissionGate?.passIfNeeded()
        return value
    }
    func requestAuthorization() async throws {
        log.hit("request")
        try await requestGate.run()
        status = statusAfterRequest
    }
    func schedule(_ request: TestNotificationRequest) async throws {
        log.hit("schedule")
        if let scheduleError { throw scheduleError }
        scheduled.append(request)
    }
}

/// Never fires unless cancelled — lets successful checks win the race against the timeout.
struct NeverSleeper: DeliverySleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

// MARK: - Tests

final class CapabilityLabTests: XCTestCase {
    private var directory: URL!
    private let camera = MockCameraSystem()
    private let location = MockLocationSystem()
    private let motion = MockMotionSystem()
    private let notifications = MockNotificationSystem()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CapabilityLabTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor
    private func makeLab(sleeper: any DeliverySleeper = NeverSleeper()) -> CapabilityLabCoordinator {
        CapabilityLabCoordinator(store: CapabilitySnapshotStore(directoryURL: directory),
                                 probes: [CameraProbe(system: camera), CurrentLocationProbe(system: location),
                                          MotionProbe(system: motion), LocalNotificationsProbe(system: notifications)],
                                 sleeper: sleeper, now: { Fixtures.pairedAt })
    }

    @MainActor
    private func run(_ lab: CapabilityLabCoordinator, _ id: CapabilityID) async -> CapabilitySnapshot {
        lab.start(id)
        await lab.waitForProbe(id)
        return lab.snapshot(for: id)
    }

    /// Everything the lab exposes or persists: snapshots (descriptions and dumps), the
    /// encoded report payload and the store file. (The mocks themselves hold the markers.)
    @MainActor
    private func everything(_ lab: CapabilityLabCoordinator, store: URL) -> String {
        var text = ""
        let snapshots = lab.registry.snapshots()
        for snapshot in snapshots {
            dump(snapshot, to: &text)
            text += String(describing: snapshot) + String(reflecting: snapshot)
        }
        text += String(describing: lab)
        if let report = try? ConnectorJSON.makeEncoder().encode(snapshots) { text += String(decoding: report, as: UTF8.self) }
        text += (try? String(contentsOf: store.appendingPathComponent(CapabilitySnapshotStore.fileName))) ?? ""
        return text
    }

    // MARK: Common (1–14)

    @MainActor
    func testProbeChangesOnlyItsOwnSnapshot() async {   // 1
        let lab = makeLab()
        let before = lab.registry.snapshots()
        camera.status = .authorized
        let result = await run(lab, .camera)

        XCTAssertEqual(result.probeState, .passed)
        for (old, new) in zip(before, lab.registry.snapshots()) where old.id != .camera {
            XCTAssertEqual(old, new, "\(old.id)")
        }
    }

    @MainActor
    func testProbesAreIndependentAndDenialDoesNotSpread() async {   // 2, 7
        let lab = makeLab()
        location.statusAfterRequest = .denied
        camera.status = .authorized
        notifications.status = .authorized

        let deniedLocation = await run(lab, .currentLocation)
        let cameraResult = await run(lab, .camera)
        let notificationResult = await run(lab, .localNotifications)

        XCTAssertEqual(deniedLocation.probeState, .failed)
        XCTAssertEqual(deniedLocation.detail, "permission_denied")
        XCTAssertEqual(cameraResult.probeState, .passed)
        XCTAssertEqual(notificationResult.probeState, .passed)
        XCTAssertEqual(camera.log.count("capture"), 1)
        XCTAssertEqual(motion.log.count("request") + motion.log.count("sample"), 0, "other probes are not started")
        XCTAssertEqual(lab.snapshot(for: .motion).probeState, .notRun)
    }

    @MainActor
    func testOneRunAtATimeAndRepeatedTapDoesNotPromptTwice() async {   // 3, 4
        let lab = makeLab()
        camera.check = .hang
        lab.start(.camera)
        lab.start(.camera)
        await waitUntil { self.camera.log.count("capture") == 1 }
        lab.start(.camera)

        XCTAssertTrue(lab.isRunning(.camera))
        XCTAssertEqual(camera.log.count("request"), 1, "one system prompt")
        XCTAssertEqual(camera.log.count("capture"), 1)

        lab.cancel(.camera)
        await lab.waitForProbe(.camera)
        XCTAssertFalse(lab.isRunning(.camera))
    }

    @MainActor
    func testTimeoutFails() async {   // 5
        let sleeper = RecordingSleeper()
        let lab = makeLab(sleeper: sleeper)
        location.status = .authorizedWhenInUse
        location.check = .hang

        let result = await run(lab, .currentLocation)

        XCTAssertEqual(result.probeState, .failed)
        XCTAssertEqual(result.detail, "timed_out")
        XCTAssertEqual(sleeper.delays, [20])
        XCTAssertFalse(location.log.isActive("updates"), "updates stopped after timeout")
    }

    @MainActor
    func testCancellationIsSafe() async {   // 6
        let lab = makeLab()
        camera.status = .authorized
        camera.check = .hang
        lab.start(.camera)
        await waitUntil { self.camera.log.count("capture") == 1 }
        lab.cancel(.camera)
        await lab.waitForProbe(.camera)

        let cancelled = lab.snapshot(for: .camera)
        XCTAssertEqual(cancelled.probeState, .failed)
        XCTAssertEqual(cancelled.detail, "cancelled")
        XCTAssertFalse(camera.log.isActive("session"), "capture session stopped")
        XCTAssertEqual(lab.snapshot(for: .motion).probeState, .notRun)

        camera.check = .succeed
        let again = await run(lab, .camera)
        XCTAssertEqual(again.probeState, .passed)
    }

    @MainActor
    func testSnapshotIsPersistedAndRestored() async throws {   // 8, 35
        let lab = makeLab()
        notifications.status = .authorized
        let result = await run(lab, .localNotifications)

        let reopened = CapabilitySnapshotStore(directoryURL: directory)
        XCTAssertEqual(reopened.snapshot(for: .localNotifications), result)
        XCTAssertEqual(reopened.storedSnapshots().map(\.id), [.localNotifications])

        let data = try Data(contentsOf: reopened.fileURL)
        let file = try ConnectorJSON.makeDecoder().decode(CapabilitySnapshotFile.self, from: data)
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.snapshots, [result])
        let roundTrip = try ConnectorJSON.makeDecoder().decode(CapabilitySnapshotFile.self,
                                                               from: ConnectorJSON.makeEncoder().encode(file))
        XCTAssertEqual(roundTrip, file)
    }

    func testCorruptedOrUnknownStoreDoesNotCrash() throws {   // 9
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(CapabilitySnapshotStore.fileName)

        try Data("{not json".utf8).write(to: fileURL)
        let corrupted = CapabilitySnapshotStore(directoryURL: directory)
        XCTAssertEqual(corrupted.loadIssue, .quarantined)
        XCTAssertEqual(corrupted.snapshot(for: .camera), StaticCapabilitySnapshotProvider().snapshot(for: .camera))

        try Data(#"{"version":99,"snapshots":[]}"#.utf8).write(to: fileURL)
        XCTAssertEqual(CapabilitySnapshotStore(directoryURL: directory).loadIssue, .quarantined)

        try Data(#"{"version":1,"snapshots":[{"id":"invented_capability","availability":"available","authorization":"granted","probe_state":"passed"}]}"#.utf8)
            .write(to: fileURL)
        let unknownID = CapabilitySnapshotStore(directoryURL: directory)
        XCTAssertEqual(unknownID.loadIssue, .quarantined, "the store never creates new capability IDs")
        XCTAssertEqual(unknownID.storedSnapshots(), [])

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }
        XCTAssertEqual(quarantined.count, 3, "originals are kept for diagnostics")
    }

    @MainActor
    func testRegistryStaysCompleteAndOrdered() async {   // 10
        let lab = makeLab()
        camera.status = .authorized
        _ = await run(lab, .camera)
        XCTAssertEqual(lab.registry.descriptors.map(\.id), CapabilityRegistry.catalog.map(\.id))
        XCTAssertEqual(lab.registry.snapshots().map(\.id), CapabilityRegistry.catalog.map(\.id))
        XCTAssertEqual(lab.registry.snapshots().count, CapabilityID.allCases.count)
        XCTAssertEqual(lab.snapshot(for: .healthKit).availability, .missingEntitlement)
        XCTAssertEqual(lab.snapshot(for: .coreNFC).availability, .missingEntitlement)
        XCTAssertEqual(lab.snapshot(for: .backgroundLocation).availability, .planned)
    }

    @MainActor
    private func connect(_ lab: CapabilityLabCoordinator, api: MockConnectorAPI) -> EventDeliveryCoordinator {
        let delivery = EventDeliveryCoordinator(api: api, queue: EventQueue(store: EventFixtures.makeTemporaryStore()),
                                                registry: lab.registry, syncState: InMemorySyncStateStore(),
                                                sleeper: RecordingSleeper(), random: { 0.5 }, now: { Fixtures.pairedAt })
        lab.onSnapshotsChanged = { [weak delivery] in Task { await delivery?.reportCapabilities() } }
        return delivery
    }

    @MainActor
    func testCapabilityReportCarriesUpdatedSnapshotsOnly() async throws {   // 11, 12
        let lab = makeLab()
        let api = MockConnectorAPI()
        let delivery = connect(lab, api: api)
        camera.status = .authorized
        location.status = .authorizedWhenInUse
        motion.status = .authorized

        _ = await run(lab, .camera)
        _ = await run(lab, .currentLocation)
        _ = await run(lab, .motion)
        await waitUntil { api.reportCalls == 3 }
        _ = delivery

        let last = try XCTUnwrap(api.reportedCapabilities.last)
        XCTAssertEqual(last.map(\.id), CapabilityRegistry.catalog.map(\.id))
        XCTAssertEqual(last.first { $0.id == .camera }?.detail, "camera_frame_received")
        XCTAssertEqual(last.first { $0.id == .currentLocation }?.probeState, .passed)

        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(last), as: UTF8.self)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let allowedKeys: Set<String> = ["id", "availability", "authorization", "probe_state", "checked_at", "detail"]
        let allowedDetails = Set(CapabilityProbeDetail.allCases.map(\.rawValue))
        for object in objects {
            XCTAssertTrue(Set(object.keys).isSubset(of: allowedKeys), "\(object.keys)")
            if let detail = object["detail"] as? String { XCTAssertTrue(allowedDetails.contains(detail), detail) }
        }
        for secret in [camera.frameMarker, location.secretFix, "55.75", motion.secretActivity, "latitude", "longitude"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertEqual(api.batchCalls, 0, "probes never create events")
    }

    @MainActor
    func testNetworkErrorKeepsLocalResult() async {   // 13
        let lab = makeLab()
        let api = MockConnectorAPI()
        api.reportHandler = { throw ConnectorAPIError.transport }
        let delivery = connect(lab, api: api)
        notifications.status = .authorized

        let result = await run(lab, .localNotifications)
        await waitUntil { api.reportCalls == 1 }
        _ = delivery

        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(CapabilitySnapshotStore(directoryURL: directory).snapshot(for: .localNotifications), result)
    }

    @MainActor
    func testForegroundRefreshNeverPromptsOrProbes() async {   // 14
        let lab = makeLab()
        camera.status = .authorized
        let passed = await run(lab, .camera)
        let probeCallsBefore = camera.log.count("capture")

        camera.status = .denied            // changed in Settings while in background
        notifications.status = .provisional
        motion.available = false
        await lab.refreshAuthorizations()

        let refreshed = lab.snapshot(for: .camera)
        XCTAssertEqual(refreshed.authorization, .denied)
        XCTAssertEqual(refreshed.probeState, passed.probeState, "probe state is not faked")
        XCTAssertEqual(refreshed.checkedAt, passed.checkedAt)
        XCTAssertEqual(refreshed.detail, passed.detail)
        XCTAssertEqual(lab.snapshot(for: .localNotifications).authorization, .limited)
        XCTAssertEqual(lab.snapshot(for: .localNotifications).probeState, .notRun)
        XCTAssertEqual(lab.snapshot(for: .motion).availability, .unsupportedDevice)
        XCTAssertNil(lab.snapshot(for: .motion).checkedAt)

        XCTAssertEqual(camera.log.count("request"), 0)
        XCTAssertEqual(camera.log.count("capture"), probeCallsBefore)
        XCTAssertEqual(location.log.count("requestWhenInUse") + location.log.count("fix"), 0)
        XCTAssertEqual(motion.log.count("request") + motion.log.count("sample"), 0)
        XCTAssertEqual(notifications.log.count("request") + notifications.log.count("schedule"), 0)
    }

    // MARK: Camera (15–18)

    @MainActor
    func testCameraRequestThenOneFrame() async {   // 15
        let lab = makeLab()
        let result = await run(lab, .camera)
        XCTAssertEqual(camera.log.count("request"), 1)
        XCTAssertEqual(camera.log.count("capture"), 1)
        XCTAssertFalse(camera.log.isActive("session"))
        XCTAssertEqual(result.authorization, .granted)
        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(result.detail, "camera_frame_received")
        XCTAssertEqual(result.checkedAt, Fixtures.pairedAt)
    }

    @MainActor
    func testCameraDeniedOrRestrictedNeverCaptures() async {   // 16
        for (status, detail) in [(CameraPermission.denied, "permission_denied"), (.restricted, "permission_restricted")] {
            camera.status = status
            let result = await run(makeLab(), .camera)
            XCTAssertEqual(result.probeState, .failed)
            XCTAssertEqual(result.detail, detail)
        }
        camera.status = .notDetermined
        camera.statusAfterRequest = .denied
        _ = await run(makeLab(), .camera)
        XCTAssertEqual(camera.log.count("capture"), 0)
    }

    @MainActor
    func testCameraFrameIsNeverStoredOrSent() async {   // 17
        let lab = makeLab()
        camera.status = .authorized
        _ = await run(lab, .camera)
        // `captureOneFrame()` returns Void: the frame cannot leave the adapter.
        XCTAssertFalse(everything(lab, store: directory).contains(camera.frameMarker))
        XCTAssertEqual(lab.snapshot(for: .camera).detail, "camera_frame_received")
    }

    @MainActor
    func testNoCameraIsUnsupportedDevice() async {   // 18
        camera.hasCameraValue = false
        let lab = makeLab()
        let result = await run(lab, .camera)
        XCTAssertEqual(result.availability, .unsupportedDevice)
        XCTAssertEqual(result.probeState, .failed)
        XCTAssertEqual(result.detail, "unavailable")
        XCTAssertEqual(camera.log.count("request") + camera.log.count("capture"), 0)
    }

    // MARK: Location (19–23)

    @MainActor
    func testLocationRequestsWhenInUseThenOneFix() async {   // 19, 20
        let lab = makeLab()
        let result = await run(lab, .currentLocation)
        XCTAssertEqual(location.log.count("requestWhenInUse"), 1)
        XCTAssertEqual(location.log.count("fix"), 1)
        XCTAssertFalse(location.log.isActive("updates"), "updates stopped after the fix")
        XCTAssertEqual(result.authorization, .granted)
        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(result.detail, "location_fix_received")

        location.status = .authorizedAlways // granted elsewhere: still just one fix, no new prompt
        _ = await run(lab, .currentLocation)
        XCTAssertEqual(location.log.count("requestWhenInUse"), 1)
    }

    @MainActor
    func testLocationDeniedOrRestrictedNeverStartsUpdates() async {   // 21
        for status in [LocationPermission.denied, .restricted] {
            location.status = status
            let result = await run(makeLab(), .currentLocation)
            XCTAssertEqual(result.probeState, .failed)
        }
        XCTAssertEqual(location.log.count("fix"), 0)
    }

    @MainActor
    func testCoordinatesNeverStored() async {   // 22
        let lab = makeLab()
        location.status = .authorizedWhenInUse
        _ = await run(lab, .currentLocation)
        let text = everything(lab, store: directory)
        for secret in [location.secretFix, "55.75", "37.61", "latitude", "longitude", "altitude", "course", "speed"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testAlwaysLocationIsNeverRequested() throws {   // 23
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            scanned += 1
            XCTAssertFalse(text.contains("requestAlwaysAuthorization"), url.lastPathComponent)
            XCTAssertFalse(text.contains("allowsBackgroundLocationUpdates"), url.lastPathComponent)
            XCTAssertFalse(text.contains("startMonitoring"), url.lastPathComponent)
        }
        XCTAssertGreaterThan(scanned, 20)
    }

    // MARK: Motion (24–27)

    @MainActor
    func testMotionOneSample() async {   // 24
        let lab = makeLab()
        let result = await run(lab, .motion)
        XCTAssertEqual(motion.log.count("request"), 1)
        XCTAssertEqual(motion.log.count("sample"), 1)
        XCTAssertFalse(motion.log.isActive("updates"))
        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(result.detail, "motion_sample_received")
    }

    @MainActor
    func testMotionDeniedOrRestrictedNeverStartsUpdates() async {   // 25
        for status in [MotionPermission.denied, .restricted] {
            motion.status = status
            let result = await run(makeLab(), .motion)
            XCTAssertEqual(result.probeState, .failed)
        }
        motion.status = .notDetermined
        motion.statusAfterRequest = .denied
        let declined = await run(makeLab(), .motion)
        XCTAssertEqual(declined.detail, "permission_denied")
        XCTAssertEqual(motion.log.count("sample"), 0)
    }

    @MainActor
    func testMotionSampleNeverStored() async {   // 26
        let lab = makeLab()
        motion.status = .authorized
        _ = await run(lab, .motion)
        let text = everything(lab, store: directory)
        for secret in [motion.secretActivity, "walking", "automotive", "steps", "acceleration"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    @MainActor
    func testMotionUnsupportedDevice() async {   // 27
        motion.available = false
        let lab = makeLab()
        await lab.refreshAuthorizations()
        XCTAssertEqual(lab.snapshot(for: .motion).availability, .unsupportedDevice)

        let result = await run(lab, .motion)
        XCTAssertEqual(result.availability, .unsupportedDevice)
        XCTAssertEqual(result.probeState, .failed)
        XCTAssertEqual(result.detail, "unavailable")
        XCTAssertEqual(motion.log.count("request") + motion.log.count("sample"), 0)
    }

    // MARK: Notifications (28–33)

    @MainActor
    func testNotificationRequestedExactlyOnce() async {   // 28
        let lab = makeLab()
        notifications.requestGate = .hang
        lab.start(.localNotifications)
        lab.start(.localNotifications)
        await waitUntil { self.notifications.log.count("request") == 1 }
        lab.start(.localNotifications)
        XCTAssertEqual(notifications.log.count("request"), 1)
        lab.cancel(.localNotifications)
        await lab.waitForProbe(.localNotifications)
    }

    @MainActor
    func testNotificationGrantedSchedulesOne() async {   // 29
        let lab = makeLab()
        let result = await run(lab, .localNotifications)
        XCTAssertEqual(notifications.log.count("request"), 1)
        XCTAssertEqual(notifications.scheduled.count, 1)
        XCTAssertEqual(result.authorization, .granted)
        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(result.detail, "test_notification_scheduled")
    }

    @MainActor
    func testNotificationDeniedSchedulesNothing() async {   // 30
        notifications.status = .denied
        let result = await run(makeLab(), .localNotifications)
        XCTAssertEqual(result.detail, "permission_denied")
        XCTAssertEqual(notifications.log.count("schedule"), 0)
    }

    @MainActor
    func testProvisionalAndEphemeralAreLimited() async {   // 31
        for status in [NotificationPermission.provisional, .ephemeral] {
            notifications.status = status
            let result = await run(makeLab(), .localNotifications)
            XCTAssertEqual(result.authorization, .limited)
            XCTAssertEqual(result.probeState, .passed)
        }
        XCTAssertEqual(notifications.log.count("request"), 0)
    }

    func testNotificationContentIsNeutral() throws {   // 32
        let request = TestNotificationRequest.make()
        XCTAssertTrue(request.identifier.hasPrefix("app.katana.connector.capability-lab.test."))
        let suffix = String(request.identifier.dropFirst(TestNotificationRequest.identifierPrefix.count + 1))
        XCTAssertNotNil(UUID(uuidString: suffix), "only a random id after the prefix")
        XCTAssertEqual(request.title, "Katana Connector")
        XCTAssertEqual(request.body, "Тестовое уведомление Capability Lab.")
        XCTAssertEqual(request.delay, 5)
        XCTAssertNotEqual(TestNotificationRequest.make().identifier, request.identifier)
    }

    @MainActor
    func testNotificationSchedulingErrorIsSystemError() async {   // 33
        notifications.status = .authorized
        notifications.scheduleError = NSError(domain: "UNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "raw system text"])
        let lab = makeLab()
        let result = await run(lab, .localNotifications)
        XCTAssertEqual(result.probeState, .failed)
        XCTAssertEqual(result.detail, "system_error")
        XCTAssertFalse(everything(lab, store: directory).contains("raw system text"))
    }

    // MARK: Wire, mapping, Info.plist (34–40)

    func testDetailWireValues() {   // 34
        XCTAssertEqual(CapabilityProbeDetail.allCases.map(\.rawValue), [
            "camera_frame_received", "location_fix_received", "motion_sample_received", "test_notification_scheduled",
            "permission_denied", "permission_restricted", "unavailable", "timed_out", "cancelled", "system_error",
        ])
    }

    func testAuthorizationMapping() {
        XCTAssertEqual([CameraPermission.notDetermined, .authorized, .denied, .restricted].map(CapabilityAuthorizationMapping.camera),
                       [.notRequested, .granted, .denied, .restricted])
        XCTAssertEqual([LocationPermission.notDetermined, .authorizedWhenInUse, .authorizedAlways, .denied, .restricted]
                        .map(CapabilityAuthorizationMapping.location),
                       [.notRequested, .granted, .granted, .denied, .restricted])
        XCTAssertEqual([MotionPermission.notDetermined, .authorized, .denied, .restricted].map(CapabilityAuthorizationMapping.motion),
                       [.notRequested, .granted, .denied, .restricted])
        XCTAssertEqual([NotificationPermission.notDetermined, .authorized, .provisional, .ephemeral, .denied]
                        .map(CapabilityAuthorizationMapping.notifications),
                       [.notRequested, .granted, .limited, .limited, .denied])
    }

    func testInfoPlistKeysAndNoBackgroundModes() throws {   // 36–40
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription:"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSMotionUsageDescription:"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSCameraUsageDescription:"))
        XCTAssertTrue(project.contains("Capability Lab"), "camera text covers QR pairing and the manual probe")
        XCTAssertTrue(project.contains("INFOPLIST_FILE: Config/KatanaConnector-Info.plist"))
        for forbidden in ["NSLocationAlways", "UIBackgroundModes", "CODE_SIGN_ENTITLEMENTS", "entitlements", "aps-environment"] {
            XCTAssertFalse(project.contains(forbidden), forbidden)
        }

        let plistData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Config/KatanaConnector-Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(Set(plist.keys), ["CFBundleURLTypes"], "only the URL scheme lives in the base plist")
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleURLSchemes"] as? [String], ["katana-connector"])
    }

    func testCoreHasNoHardwareFrameworks() throws {
        let core = repositoryRoot.appendingPathComponent("Sources/Core")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            for framework in ["AVFoundation", "CoreLocation", "CoreMotion", "UserNotifications", "UIKit", "SwiftUI", "Photos"] {
                XCTAssertFalse(text.contains("import \(framework)"), "\(url.lastPathComponent) imports \(framework)")
            }
        }
    }

    // MARK: Regression: stale passive refresh must not overwrite a newer probe result

    /// Installs a gate on the status read of `id` and returns it.
    private func gate(_ id: CapabilityID) -> FirstCallGate {
        let gate = FirstCallGate()
        switch id {
        case .camera: camera.permissionGate = gate
        case .currentLocation: location.permissionGate = gate
        case .motion: motion.permissionGate = gate
        case .localNotifications: notifications.permissionGate = gate
        default: XCTFail("not a lab capability")
        }
        return gate
    }

    private func successDetail(_ id: CapabilityID) -> String {
        switch id {
        case .camera: return "camera_frame_received"
        case .currentLocation: return "location_fix_received"
        case .motion: return "motion_sample_received"
        default: return "test_notification_scheduled"
        }
    }

    /// The refresh blocks inside authorization() with a stale `not_requested`; meanwhile the
    /// probe asks for permission, gets it and finishes; then the old refresh resumes.
    @MainActor
    private func raceProbeAgainstStaleRefresh(_ id: CapabilityID, lab: CapabilityLabCoordinator) async -> CapabilitySnapshot {
        let gate = gate(id)
        let refresh = Task { await lab.refreshAuthorizations() }
        await waitUntil { gate.isWaiting }

        lab.start(id)
        await lab.waitForProbe(id)
        let probeResult = lab.snapshot(for: id)

        gate.open()
        await refresh.value
        XCTAssertEqual(lab.snapshot(for: id), probeResult, "\(id): stale refresh must not overwrite the probe result")
        return lab.snapshot(for: id)
    }

    @MainActor
    func testStaleRefreshDoesNotOverwriteLocationProbe() async {
        let lab = makeLab()
        let result = await raceProbeAgainstStaleRefresh(.currentLocation, lab: lab)

        XCTAssertEqual(result.authorization, .granted)
        XCTAssertEqual(result.probeState, .passed)
        XCTAssertEqual(result.detail, "location_fix_received")
        XCTAssertEqual(CapabilitySnapshotStore(directoryURL: directory).snapshot(for: .currentLocation), result,
                       "the persisted snapshot is the consistent one")
    }

    @MainActor
    func testStaleRefreshDoesNotOverwriteAnyProbe() async {
        for id in CapabilityLabCoordinator.labCapabilities {
            try? FileManager.default.removeItem(at: directory)
            let lab = makeLab()
            let result = await raceProbeAgainstStaleRefresh(id, lab: lab)
            XCTAssertEqual(result.authorization, .granted, "\(id)")
            XCTAssertEqual(result.probeState, .passed, "\(id)")
            XCTAssertEqual(result.detail, successDetail(id), "\(id)")
        }
    }

    @MainActor
    func testFreshRefreshAfterProbeReportsCurrentStatusHonestly() async {
        let lab = makeLab()
        let passed = await run(lab, .currentLocation)
        XCTAssertEqual(passed.authorization, .granted)

        location.status = .notDetermined // e.g. Reset Location & Privacy
        await lab.refreshAuthorizations()

        let refreshed = lab.snapshot(for: .currentLocation)
        XCTAssertEqual(refreshed.authorization, .notRequested)
        XCTAssertEqual(refreshed.probeState, .passed, "the last probe result is kept, not faked")
        XCTAssertEqual(refreshed.checkedAt, passed.checkedAt)
    }

    @MainActor
    func testStaleRefreshDoesNotOverwriteDeniedOrCancelledProbe() async {
        // Denied during the probe.
        location.statusAfterRequest = .denied
        let deniedLab = makeLab()
        let denied = await raceProbeAgainstStaleRefresh(.currentLocation, lab: deniedLab)
        XCTAssertEqual(denied.authorization, .denied)
        XCTAssertEqual(denied.detail, "permission_denied")

        // Cancelled while checking.
        try? FileManager.default.removeItem(at: directory)
        camera.status = .notDetermined
        camera.check = .hang
        let lab = makeLab()
        let gate = gate(.camera)
        let refresh = Task { await lab.refreshAuthorizations() }
        await waitUntil { gate.isWaiting }
        lab.start(.camera)
        await waitUntil { self.camera.log.count("capture") == 1 }
        lab.cancel(.camera)
        await lab.waitForProbe(.camera)
        let cancelled = lab.snapshot(for: .camera)
        gate.open()
        await refresh.value

        XCTAssertEqual(cancelled.authorization, .granted)
        XCTAssertEqual(cancelled.detail, "cancelled")
        XCTAssertEqual(lab.snapshot(for: .camera), cancelled)
    }

    @MainActor
    func testRefreshStartedDuringProbeIsDropped() async {
        let lab = makeLab()
        location.status = .authorizedWhenInUse
        location.check = .hang
        lab.start(.currentLocation)
        await waitUntil { self.location.log.count("fix") == 1 }

        location.status = .denied // a refresh now would read a different value
        await lab.refreshAuthorizations()
        XCTAssertEqual(lab.snapshot(for: .currentLocation).authorization, .unknown,
                       "nothing is written for a capability while its probe runs")

        lab.cancel(.currentLocation)
        await lab.waitForProbe(.currentLocation)
    }

    @MainActor
    func testReportAfterRaceIsConsistent() async throws {
        let lab = makeLab()
        let api = MockConnectorAPI()
        let delivery = connect(lab, api: api)

        _ = await raceProbeAgainstStaleRefresh(.currentLocation, lab: lab)
        await waitUntil { api.reportCalls >= 1 }
        await delivery.reportCapabilities()

        let reported = try XCTUnwrap(api.reportedCapabilities.last?.first { $0.id == .currentLocation })
        XCTAssertEqual(reported.authorization, .granted)
        XCTAssertEqual(reported.probeState, .passed)
        XCTAssertEqual(reported.detail, "location_fix_received")
    }
}
