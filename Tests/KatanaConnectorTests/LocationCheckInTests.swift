import XCTest

/// V2-004: Location Check-in on mocks — no Core Location, no real prompts, no network.
final class LocationCheckInTests: XCTestCase {
    private var directory: URL!
    private var system: MockCheckInLocationSystem!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("CheckIn")
        system = MockCheckInLocationSystem()
        clock = TestClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor
    private func makeCheckIn(sink: RecordingEventSink? = nil, sleeper: any DeliverySleeper = NeverSleeper()) -> LocationCheckInCoordinator {
        let clock = self.clock!
        return LocationCheckInCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: CheckInHistoryFile.fileName),
                                          system: system, sink: sink, sleeper: sleeper, now: { clock.now() })
    }

    // MARK: Permissions

    @MainActor
    func testWhenInUseRequestedOnlyByTheButtonAndOnlyOnce() async {
        system.status = .notDetermined
        let checkIn = makeCheckIn()
        XCTAssertEqual(system.log.count("requestWhenInUse") + system.log.count("fix"), 0, "creating the screen asks nothing")
        await checkIn.locate()
        XCTAssertEqual(system.log.count("requestWhenInUse"), 1)
        XCTAssertEqual(system.log.count("fix"), 1)
        XCTAssertEqual(checkIn.phase, .preview)
        checkIn.cancel()
        await checkIn.locate()
        XCTAssertEqual(system.log.count("requestWhenInUse"), 1, "no second prompt")
    }

    @MainActor
    func testDeniedRestrictedAndServicesDisabled() async {
        system.status = .denied
        let denied = makeCheckIn()
        await denied.locate()
        XCTAssertEqual(denied.phase, .failed(.permissionDenied))

        system.status = .restricted
        let restricted = makeCheckIn()
        await restricted.locate()
        XCTAssertEqual(restricted.phase, .failed(.permissionRestricted))

        system.status = .notDetermined
        system.statusAfterRequest = .denied
        let declined = makeCheckIn()
        await declined.locate()
        XCTAssertEqual(declined.phase, .failed(.permissionDenied))

        system.servicesOn = false
        system.status = .notDetermined
        let disabled = makeCheckIn()
        await disabled.locate()
        XCTAssertEqual(disabled.phase, .failed(.servicesDisabled))
        XCTAssertEqual(system.log.count("requestWhenInUse"), 1, "no prompt while Location Services are off")
        XCTAssertEqual(system.log.count("fix"), 0, "no fix without permission")
        XCTAssertNil(disabled.preview)
    }

    @MainActor
    func testTimeoutAndSystemErrorLeaveNoPreview() async {
        system.hangsOnFix = true
        let slow = makeCheckIn(sleeper: ImmediateSleeper())
        await slow.locate()
        XCTAssertEqual(slow.phase, .failed(.timedOut))
        XCTAssertNil(slow.preview)

        system.hangsOnFix = false
        system.fixError = .systemError
        let failing = makeCheckIn()
        await failing.locate()
        XCTAssertEqual(failing.phase, .failed(.systemError))
    }

    func testOnlyWhenInUseAPIsExistInSources() throws {
        let adapter = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/Features/LocationCheckIn/SystemCheckInLocationAccess.swift"))
        XCTAssertTrue(adapter.contains("requestWhenInUseAuthorization()"))
        XCTAssertTrue(adapter.contains("requestLocation()"))
        for forbidden in ["startUpdatingLocation", "SignificantLocationChange", "CLCircularRegion", "CLMonitor",
                          "allowsBackgroundLocationUpdates", "showsBackgroundLocationIndicator", "altitude", ".speed",
                          ".course", ".floor", "timestamp"] {
            XCTAssertFalse(adapter.contains(forbidden), forbidden)
        }
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.contains("Location Check-in"), "usage text names the feature honestly")
        XCTAssertFalse(project.contains("NSLocationAlways"))
        XCTAssertFalse(project.contains("UIBackgroundModes"))
    }

    // MARK: Preview, confirmation, cancel

    @MainActor
    func testPreviewComesBeforeAnyEvent() async throws {
        let sink = RecordingEventSink()
        let checkIn = makeCheckIn(sink: sink)
        await checkIn.locate()
        let preview = try XCTUnwrap(checkIn.preview)
        XCTAssertTrue(sink.attempts.isEmpty, "a fix alone creates nothing")
        XCTAssertEqual(preview.occurredAt, Fixtures.pairedAt)
        XCTAssertEqual(preview.accuracyBucket, .under100m)
        XCTAssertEqual(checkIn.precision, .approximate, "approximate by default")
        XCTAssertEqual(preview.coordinates(.approximate).latitude, 55.76)

        await checkIn.send()
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNil(checkIn.preview, "coordinates are cleared after enqueue")
        guard case .saved(let entry) = checkIn.phase else { return XCTFail("expected saved, got \(checkIn.phase)") }
        XCTAssertEqual(entry.eventID, sink.events.first?.eventID)
    }

    @MainActor
    func testCancelAndLeavingCreateNoEvent() async {
        let sink = RecordingEventSink()
        let checkIn = makeCheckIn(sink: sink)
        await checkIn.locate()
        checkIn.cancel()
        XCTAssertNil(checkIn.preview)
        XCTAssertEqual(checkIn.phase, .idle)
        await checkIn.send()
        await checkIn.locate()
        checkIn.discardPreview()   // left the screen / app went to the background
        XCTAssertNil(checkIn.preview)
        await checkIn.send()
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    @MainActor
    func testExpiredPreviewIsDroppedWithoutEvent() async {
        let sink = RecordingEventSink()
        let checkIn = makeCheckIn(sink: sink)
        await checkIn.locate()
        clock.advance(CheckInPreview.lifetime + 1)
        await checkIn.send()
        XCTAssertEqual(checkIn.phase, .failed(.previewExpired))
        XCTAssertNil(checkIn.preview)
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    @MainActor
    func testDoubleTapCreatesOneEventAndNotPairedRetryReusesIDs() async throws {
        let sink = RecordingEventSink()
        sink.outcome = .notPaired
        let checkIn = makeCheckIn(sink: sink)
        await checkIn.locate()
        await checkIn.send()
        XCTAssertEqual(checkIn.phase, .failed(.notPaired))
        XCTAssertNotNil(checkIn.preview, "kept (in memory) so the user can retry after pairing")

        sink.outcome = .saved
        async let one: Void = checkIn.send()
        async let two: Void = checkIn.send()
        _ = await (one, two)
        await checkIn.send()
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(Set(sink.attempts.map(\.eventID)).count, 1, "retry reuses the event ID")
        XCTAssertEqual(Set(sink.attempts.map(\.sessionID)).count, 1, "and the check-in ID")
    }

    // MARK: Rounding, buckets, wire format

    func testApproximateRoundsToTwoDecimals() {
        XCTAssertEqual(CoordinateRounding.round(55.755814, fractionDigits: 2), 55.76)
        XCTAssertEqual(CoordinateRounding.round(37.617635, fractionDigits: 2), 37.62)
        XCTAssertEqual(CoordinateRounding.round(-33.868819, fractionDigits: 2), -33.87)
        XCTAssertEqual(CoordinateRounding.round(0.125, fractionDigits: 2), 0.13, "half away from zero")
        XCTAssertEqual(CoordinateRounding.round(-0.125, fractionDigits: 2), -0.13)
        XCTAssertEqual(CoordinateRounding.round(55.755, fractionDigits: 2), 55.76, "decimal spelling, not binary noise")
        XCTAssertEqual(CoordinateRounding.round(90, fractionDigits: 2), 90)
    }

    func testPreciseKeepsAtMostSixDecimals() {
        XCTAssertEqual(CoordinateRounding.round(55.7558149, fractionDigits: 6), 55.755815)
        XCTAssertEqual(CoordinateRounding.round(-122.0312186, fractionDigits: 6), -122.031219)
        XCTAssertEqual(CoordinateRounding.round(37.617635, fractionDigits: 6), 37.617635)
        XCTAssertEqual(CoordinateRounding.fractionDigits(of: 55.755815), 6)
        XCTAssertEqual(CoordinateRounding.fractionDigits(of: 55.76), 2)
        XCTAssertEqual(CoordinateRounding.fractionDigits(of: 0.000001), 6)
    }

    func testAccuracyBuckets() {
        let cases: [(Double, HorizontalAccuracyBucket)] = [
            (0, .under25m), (24.9, .under25m), (25, .under100m), (99.9, .under100m), (100, .under1km),
            (999.9, .under1km), (1000, .over1km), (65_000, .over1km), (-1, .unknown), (.nan, .unknown), (.infinity, .unknown),
        ]
        for (accuracy, bucket) in cases {
            XCTAssertEqual(HorizontalAccuracyBucket(accuracyMeters: accuracy), bucket, "\(accuracy)")
        }
        XCTAssertEqual(HorizontalAccuracyBucket.allCases.map(\.rawValue), ["under_25m", "under_100m", "under_1km", "over_1km", "unknown"])
        XCTAssertEqual(CheckInPrecision.allCases.map(\.rawValue), ["approximate", "precise"])
    }

    func testEventWireFormatForBothPrecisions() throws {
        let preview = CheckInPreview(fix: LocationFix(latitude: 55.7558149, longitude: -37.6176351, horizontalAccuracy: 8),
                                     receivedAt: Fixtures.pairedAt.addingTimeInterval(0.6))
        for (precision, latitude, longitude) in [(CheckInPrecision.approximate, 55.76, -37.62),
                                                 (.precise, 55.755815, -37.617635)] {
            let event = try preview.makeEvent(precision: precision, labelRequested: precision == .approximate)
            let json = try ContextFixtures.json(event)
            XCTAssertEqual(json["type"] as? String, "location.check_in.created")
            XCTAssertEqual(json["session_id"] as? String, preview.checkInID.uuidString.lowercased())
            XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:20Z")
            let payload = try ContextFixtures.payload(event)
            XCTAssertEqual(Set(payload.keys), ["check_in_id", "occurred_at", "latitude", "longitude", "precision",
                                               "horizontal_accuracy_bucket", "label_requested"])
            XCTAssertEqual(payload["check_in_id"] as? String, preview.checkInID.uuidString.lowercased())
            XCTAssertEqual(payload["latitude"] as? Double, latitude)
            XCTAssertEqual(payload["longitude"] as? Double, longitude)
            XCTAssertEqual(payload["precision"] as? String, precision.rawValue)
            XCTAssertEqual(payload["horizontal_accuracy_bucket"] as? String, "under_25m")
            XCTAssertEqual(payload["label_requested"] as? Bool, precision == .approximate)

            // On the wire the numbers have no more digits than allowed.
            let text = try ContextFixtures.text(event)
            for value in [latitude, longitude] {
                XCTAssertTrue(text.contains("\(value)"), "\(value) in \(text)")
            }
            XCTAssertFalse(text.contains("55.7558149"))
        }
    }

    func testNoForbiddenLocationFieldsAnywhere() throws {
        let preview = CheckInPreview(fix: LocationFix(latitude: 55.755814, longitude: 37.617635, horizontalAccuracy: 42.123),
                                     receivedAt: Fixtures.pairedAt)
        let text = try ContextFixtures.text(preview.makeEvent(precision: .precise, labelRequested: false))
        for forbidden in ["altitude", "speed", "course", "floor", "horizontal_accuracy\"", "42.123", "vertical", "timestamp",
                          "exif", "photo"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        // Coordinates never appear in descriptions or mirrors.
        for value in [preview as Any, LocationFix(latitude: 55.755814, longitude: 37.617635, horizontalAccuracy: 5) as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            for rendered in [String(describing: value), String(reflecting: value), dumped] {
                XCTAssertFalse(rendered.contains("55.75"), rendered)
                XCTAssertFalse(rendered.contains("37.61"), rendered)
            }
        }
    }

    func testOutOfRangeCoordinatesAreRejected() {
        let preview = CheckInPreview(fix: LocationFix(latitude: 91, longitude: 0, horizontalAccuracy: 5), receivedAt: Fixtures.pairedAt)
        XCTAssertThrowsError(try preview.makeEvent(precision: .precise, labelRequested: false))
        let nan = CheckInPreview(fix: LocationFix(latitude: .nan, longitude: 0, horizontalAccuracy: 5), receivedAt: Fixtures.pairedAt)
        XCTAssertThrowsError(try nan.makeEvent(precision: .approximate, labelRequested: false))
    }

    // MARK: History and storage

    @MainActor
    func testHistoryHasNoCoordinatesAndSurvivesRelaunch() async throws {
        let sink = RecordingEventSink()
        let checkIn = makeCheckIn(sink: sink)
        checkIn.precision = .precise
        await checkIn.locate()
        await checkIn.send()

        let relaunched = makeCheckIn(sink: sink)
        XCTAssertEqual(relaunched.history.count, 1)
        XCTAssertEqual(relaunched.history.first?.precision, .precise)
        XCTAssertNil(relaunched.preview, "nothing unconfirmed survives a relaunch")
        let file = String(decoding: try Data(contentsOf: directory.appendingPathComponent(CheckInHistoryFile.fileName)), as: UTF8.self)
        for forbidden in ["55.75", "37.61", "latitude", "longitude", "token"] {
            XCTAssertFalse(file.contains(forbidden), forbidden)
        }
        XCTAssertEqual(CheckInHistoryFile.fileName, "check-ins.json")
        XCTAssertEqual(CheckInHistoryFile.directoryName, "LocationCheckIn")
        XCTAssertEqual(CheckInHistoryFile.currentVersion, 1)
        let path = CheckInHistoryFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/LocationCheckIn/check-ins.json"), path)
    }

    @MainActor
    func testCorruptHistoryIsQuarantined() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: directory.appendingPathComponent(CheckInHistoryFile.fileName))
        let checkIn = makeCheckIn()
        XCTAssertEqual(checkIn.storageIssue, .quarantined)
        XCTAssertTrue(checkIn.history.isEmpty)
    }

    // MARK: Queue: offline, relaunch, exact-once, scope

    @MainActor
    func testOfflineRelaunchDeliversOnceAndOnlyToItsScope() async throws {
        let queueDirectory = ContextFixtures.temporaryDirectory("CheckInQueue")
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let checkIn = makeCheckIn()
        checkIn.sink = delivery
        await checkIn.locate()
        await checkIn.send()
        await delivery.waitForFlush()
        let saved = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(saved.map(\.type), ["location.check_in.created"])
        let eventID = try XCTUnwrap(saved.first?.eventID)

        // Another connection (different device) must never receive it.
        api.scope = EventFixtures.otherDeviceScope
        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        let (_, other) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await other.prepare()
        other.requestFlush()
        await other.waitForFlush()
        XCTAssertFalse(api.sentScopes.contains(EventFixtures.otherDeviceScope))
        XCTAssertEqual(other.otherScopePendingCount, 1)

        // Back on the original connection after a relaunch: same event_id, once.
        api.scope = EventFixtures.scope
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        let sent = api.sentBatches.flatMap { $0 }.map(\.eventID)
        XCTAssertTrue(sent.allSatisfy { $0 == eventID })
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Link

    @MainActor
    func testLocationLinkOnlyNavigates() throws {
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=2&feature=location_check_in"),
                       .openDestination(.locationCheckIn))
        XCTAssertEqual(ConnectorURLRouter.url(for: .locationCheckIn).absoluteString,
                       "katana-connector://open?v=2&feature=location_check_in")
        for text in ["katana-connector://open?v=2&feature=location_check_in&latitude=1",
                     "katana-connector://open?v=2&feature=location_check_in&precision=precise"] {
            XCTAssertThrowsError(try ConnectorURLRouter.parse(text), text)
        }
        let system = self.system!
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .locationCheckIn)))
        XCTAssertEqual(navigator.path, [.locationCheckIn])
        XCTAssertEqual(system.log.count("services") + system.log.count("requestWhenInUse") + system.log.count("fix"), 0,
                       "the link touches no location API")
    }
}
