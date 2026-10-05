import XCTest

final class MockGeofenceSystem: GeofenceSystem, @unchecked Sendable {
    private let lock = NSLock()
    let log = CallLog()
    var servicesOn = true
    var monitoringAvailable = true
    var status: LocationPermission = .authorizedWhenInUse
    var statusAfterWhenInUse: LocationPermission = .authorizedWhenInUse
    var statusAfterAlways: LocationPermission = .authorizedAlways
    var fix = LocationFix(latitude: 55.75581449, longitude: 37.61763526, horizontalAccuracy: 12)
    var registerError: Error?
    private var _regions: [String: (Double, Double, Double)] = [:]
    private var handler: (@Sendable (String, GeofenceTransition) -> Void)?

    var regions: [String: (Double, Double, Double)] { lock.lock(); defer { lock.unlock() }; return _regions }

    func servicesEnabled() async -> Bool { servicesOn }
    func isMonitoringAvailable() async -> Bool { monitoringAvailable }
    func permission() async -> LocationPermission { lock.lock(); defer { lock.unlock() }; return status }

    func requestWhenInUseAuthorization() async -> LocationPermission {
        log.hit("requestWhenInUse")
        lock.lock(); defer { lock.unlock() }
        if status == .notDetermined { status = statusAfterWhenInUse }
        return status
    }

    func requestAlwaysPermission() async -> LocationPermission {
        log.hit("requestAlways")
        lock.lock(); defer { lock.unlock() }
        status = statusAfterAlways
        return status
    }

    func currentFix() async throws -> LocationFix {
        log.hit("fix")
        return fix
    }

    func registeredRegionIdentifiers() async -> Set<String> { Set(regions.keys) }

    func registerRegion(identifier: String, latitude: Double, longitude: Double, radiusMeters: Double) async throws {
        log.hit("register")
        if let registerError { throw registerError }
        lock.lock(); _regions[identifier] = (latitude, longitude, radiusMeters); lock.unlock()
    }

    func unregisterRegion(identifier: String) async {
        log.hit("unregister")
        lock.lock(); _regions[identifier] = nil; lock.unlock()
    }

    func setTransitionHandler(_ handler: @escaping @Sendable (String, GeofenceTransition) -> Void) async {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    /// Simulates iOS dropping or keeping regions (e.g. after a reinstall or a foreign region).
    func setRegion(_ identifier: String, present: Bool) {
        lock.lock(); _regions[identifier] = present ? (0, 0, 100) : nil; lock.unlock()
    }
}

/// V3-004: local geofences — permission flow, rounding, limit, create/remove, crossings.
final class GeofenceTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!
    private var system: MockGeofenceSystem!

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("Geofences")
        clock = TestClock()
        system = MockGeofenceSystem()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func makeGeofences(sink: RecordingEventSink? = nil, sleeper: any DeliverySleeper = NeverSleeper()) -> GeofenceCoordinator {
        let clock = self.clock!
        return GeofenceCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: GeofencesFile.fileName),
                                   system: system, sink: sink, sleeper: sleeper, now: { clock.now() })
    }

    @MainActor
    private func created(_ geofences: GeofenceCoordinator, name: String = "Дом", radius: Int = 200) async throws -> UUID {
        await geofences.locate()
        geofences.draftName = name
        geofences.draftRadius = radius
        await geofences.registerDraft()
        guard case .created(let id) = geofences.phase else {
            XCTFail("expected created, got \(geofences.phase)")
            throw CancellationError()
        }
        return id
    }

    // MARK: Permissions

    @MainActor
    func testNothingIsRequestedUntilButtonsAndAlwaysOnlyAtRegistration() async throws {
        system.status = .notDetermined
        let geofences = makeGeofences()
        await geofences.start()
        XCTAssertEqual(system.log.count("requestWhenInUse") + system.log.count("requestAlways") + system.log.count("fix"), 0,
                       "launch and reconcile ask nothing")
        await geofences.locate()
        XCTAssertEqual(system.log.count("requestWhenInUse"), 1)
        XCTAssertEqual(system.log.count("requestAlways"), 0, "Always is not asked for a preview")
        XCTAssertEqual(geofences.phase, .preview)
        await geofences.registerDraft()
        XCTAssertEqual(system.log.count("requestAlways"), 1)
        guard case .created = geofences.phase else { return XCTFail("expected created") }
    }

    @MainActor
    func testPermissionStates() async {
        system.servicesOn = false
        let off = makeGeofences()
        await off.locate()
        XCTAssertEqual(off.phase, .failed(.servicesDisabled))

        system.servicesOn = true
        system.status = .denied
        let denied = makeGeofences()
        await denied.locate()
        XCTAssertEqual(denied.phase, .failed(.permissionDenied))

        system.status = .restricted
        let restricted = makeGeofences()
        await restricted.locate()
        XCTAssertEqual(restricted.phase, .failed(.permissionRestricted))

        // When In Use, but «Всегда» declined: nothing is registered or promised.
        system.status = .authorizedWhenInUse
        system.statusAfterAlways = .authorizedWhenInUse
        let sink = RecordingEventSink()
        let noAlways = makeGeofences(sink: sink)
        await noAlways.locate()
        await noAlways.registerDraft()
        XCTAssertEqual(noAlways.phase, .failed(.alwaysRequired))
        XCTAssertTrue(noAlways.geofences.isEmpty)
        XCTAssertTrue(system.regions.isEmpty)
        XCTAssertTrue(sink.attempts.isEmpty)
        XCTAssertNotNil(noAlways.draft, "kept so the user can retry after Settings")

        system.monitoringAvailable = false
        system.statusAfterAlways = .authorizedAlways
        await noAlways.registerDraft()
        XCTAssertEqual(noAlways.phase, .failed(.monitoringUnavailable))
    }

    // MARK: Create, rounding, wire format

    @MainActor
    func testCreateRoundsAndSendsOnlyAfterConfirmation() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        await geofences.locate()
        XCTAssertEqual(geofences.draft?.latitude, 55.7558)
        XCTAssertEqual(geofences.draft?.longitude, 37.6176)
        XCTAssertTrue(sink.attempts.isEmpty, "a preview sends nothing")

        clock.advance(1.5)
        geofences.draftName = "Дом"
        geofences.draftRadius = 500
        await geofences.registerDraft()
        guard case .created(let id) = geofences.phase else { return XCTFail("expected created") }
        XCTAssertNil(geofences.draft)
        let region = try XCTUnwrap(system.regions[GeofenceRules.regionIdentifier(for: id)])
        XCTAssertEqual(region.0, 55.7558)
        XCTAssertEqual(region.2, 500)
        XCTAssertEqual(geofences.systemStates[id], .active)

        let event = try XCTUnwrap(sink.events.first)
        let json = try ContextFixtures.json(event)
        XCTAssertEqual(json["type"] as? String, "geofence.created")
        XCTAssertEqual(json["session_id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:21Z")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["geofence_id", "latitude", "longitude", "radius_m", "created_at", "origin"])
        XCTAssertEqual(payload["latitude"] as? Double, 55.7558)
        XCTAssertEqual(payload["longitude"] as? Double, 37.6176)
        XCTAssertEqual(payload["radius_m"] as? Int, 500)
        XCTAssertEqual(payload["origin"] as? String, "user")
        let text = try ContextFixtures.text(event)
        XCTAssertFalse(text.contains("Дом"), "the name stays on the iPhone")
        XCTAssertFalse(text.contains("55.75581"))
    }

    @MainActor
    func testNameRadiusAndSystemLimit() async throws {
        let geofences = makeGeofences(sink: RecordingEventSink())
        await geofences.locate()
        geofences.draftName = "   "
        await geofences.registerDraft()
        XCTAssertEqual(geofences.phase, .failed(.invalidName))
        geofences.draftName = String(repeating: "я", count: GeofenceRules.maxNameScalars + 1)
        await geofences.registerDraft()
        XCTAssertEqual(geofences.phase, .failed(.invalidName))
        XCTAssertEqual(GeofenceRules.allowedRadii, [100, 200, 500, 1000])
        XCTAssertEqual(GeofenceRules.maxGeofences, 20)

        for index in 0..<GeofenceRules.maxGeofences {
            _ = try await created(geofences, name: "Место \(index)")
        }
        XCTAssertEqual(system.regions.count, 20)
        await geofences.locate()
        await geofences.registerDraft()
        XCTAssertEqual(geofences.phase, .failed(.limitReached))
        XCTAssertEqual(system.regions.count, 20, "never more than the Core Location limit")
    }

    // MARK: Transitions

    @MainActor
    func testEnterExitHaveNoCoordinatesAndDuplicatesAreDropped() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        await geofences.start()
        let id = try await created(geofences)
        let region = GeofenceRules.regionIdentifier(for: id)

        geofences.isAppActive = false
        clock.advance(60)
        await geofences.handleTransition(regionIdentifier: region, transition: .enter)
        clock.advance(30)
        await geofences.handleTransition(regionIdentifier: region, transition: .enter)   // duplicate callback
        clock.advance(10)
        await geofences.handleTransition(regionIdentifier: region, transition: .exit)
        await geofences.handleTransition(regionIdentifier: "app.katana.connector.geofence.\(UUID().uuidString.lowercased())",
                                         transition: .enter)
        await geofences.handleTransition(regionIdentifier: "other.app.region", transition: .enter)

        let transitions = sink.events.filter { $0.type == "geofence.transitioned" }
        XCTAssertEqual(transitions.count, 2)
        let enter = try ContextFixtures.payload(XCTUnwrap(transitions.first))
        XCTAssertEqual(Set(enter.keys), ["geofence_id", "transition_id", "transition", "occurred_at", "delivery_context", "interrupted"])
        XCTAssertEqual(enter["transition"] as? String, "enter")
        XCTAssertEqual(enter["delivery_context"] as? String, "background")
        XCTAssertEqual(enter["interrupted"] as? Bool, false)
        XCTAssertEqual(enter["geofence_id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(try ContextFixtures.json(XCTUnwrap(transitions.first))["session_id"] as? String, enter["transition_id"] as? String)
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(transitions.last))["transition"] as? String, "exit")
        for event in transitions {
            let text = try ContextFixtures.text(event)
            for forbidden in ["latitude", "longitude", "55.7", "37.6", "radius", "Дом", "accuracy"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        }
        clock.advance(GeofenceLastTransition.duplicateWindow)
        await geofences.handleTransition(regionIdentifier: region, transition: .exit)
        XCTAssertEqual(sink.events.filter { $0.type == "geofence.transitioned" }.count, 3, "after the window a crossing counts again")
        XCTAssertEqual(GeofenceTransition.allCases.map(\.rawValue), ["enter", "exit"])
        XCTAssertEqual(GeofenceDeliveryContext.allCases.map(\.rawValue), ["foreground", "background"])
    }

    @MainActor
    func testDisabledGeofenceIgnoresCrossingsAndReEnableNeedsAlways() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        let id = try await created(geofences)
        await geofences.setEnabled(false, geofenceID: id)
        XCTAssertTrue(system.regions.isEmpty, "disabling removes the system region")
        XCTAssertEqual(geofences.systemStates[id], .disabled)
        await geofences.handleTransition(regionIdentifier: GeofenceRules.regionIdentifier(for: id), transition: .enter)
        XCTAssertEqual(sink.events.map(\.type), ["geofence.created"])

        system.status = .authorizedWhenInUse
        system.statusAfterAlways = .denied
        await geofences.setEnabled(true, geofenceID: id)
        XCTAssertEqual(geofences.recordFailures[id], .alwaysRequired)
        XCTAssertFalse(geofences.geofences.first?.enabled ?? true)
        // The user changes the setting to «Всегда» in Settings, then turns the geofence on again.
        system.status = .authorizedAlways
        await geofences.setEnabled(true, geofenceID: id)
        XCTAssertEqual(geofences.systemStates[id], .active)
        XCTAssertNil(geofences.recordFailures[id])
    }

    @MainActor
    func testRemoveErasesCoordinatesAndSendsRemoved() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        let id = try await created(geofences)
        clock.advance(5)
        await geofences.remove(geofenceID: id)
        XCTAssertTrue(geofences.geofences.isEmpty)
        XCTAssertTrue(system.regions.isEmpty)
        let removed = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(removed.type, "geofence.removed")
        XCTAssertEqual(Set(try ContextFixtures.payload(removed).keys), ["geofence_id", "removed_at"])
        let file = String(decoding: try Data(contentsOf: directory.appendingPathComponent(GeofencesFile.fileName)), as: UTF8.self)
        XCTAssertFalse(file.contains("55.7558"), "coordinates are erased with the geofence")
        XCTAssertFalse(file.contains("Дом"))
    }

    // MARK: Reconcile, relaunch, offline

    @MainActor
    func testReconcileRemovesHiddenRegionsAndReregistersAsInterrupted() async throws {
        let sink = RecordingEventSink()
        let first = makeGeofences(sink: sink)
        let id = try await created(first)
        let foreign = "app.katana.connector.geofence.\(UUID().uuidString.lowercased())"
        system.setRegion(foreign, present: true)
        system.setRegion("com.other.app.region", present: true)
        system.setRegion(GeofenceRules.regionIdentifier(for: id), present: false)   // lost (e.g. reinstall)

        let relaunched = makeGeofences(sink: sink)
        await relaunched.start()
        XCTAssertNil(system.regions[foreign], "no hidden geofences")
        XCTAssertNotNil(system.regions["com.other.app.region"], "regions of others are never touched")
        XCTAssertNotNil(system.regions[GeofenceRules.regionIdentifier(for: id)])
        XCTAssertEqual(relaunched.systemStates[id], .active)

        await relaunched.handleTransition(regionIdentifier: GeofenceRules.regionIdentifier(for: id), transition: .exit)
        let transition = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(try ContextFixtures.payload(transition)["interrupted"] as? Bool, true)

        system.status = .authorizedWhenInUse
        system.setRegion(GeofenceRules.regionIdentifier(for: id), present: false)
        await relaunched.reconcile()
        XCTAssertEqual(relaunched.systemStates[id], .noAlwaysPermission, "the real system state is shown")
    }

    @MainActor
    func testTransitionSavedBeforeQueueAndRetriedOnceAfterRelaunch() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        let id = try await created(geofences)
        sink.outcome = .failed
        await geofences.handleTransition(regionIdentifier: GeofenceRules.regionIdentifier(for: id), transition: .enter)
        XCTAssertEqual(geofences.pendingEventCount, 1)
        let failedAttempt = try XCTUnwrap(sink.attempts.last)

        sink.outcome = .saved
        let relaunched = makeGeofences(sink: sink)
        XCTAssertEqual(relaunched.pendingEventCount, 1, "survives a relaunch on disk")
        await relaunched.saveEvents()
        await relaunched.saveEvents()
        XCTAssertEqual(sink.events.filter { $0.type == "geofence.transitioned" }.map(\.eventID), [failedAttempt.eventID])
        XCTAssertEqual(relaunched.pendingEventCount, 0)
    }

    @MainActor
    func testOfflineQueueRelaunchExactOnce() async throws {
        let queueDirectory = ContextFixtures.temporaryDirectory("GeofenceQueue")
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let geofences = makeGeofences()
        geofences.sink = delivery
        let id = try await created(geofences)
        await geofences.handleTransition(regionIdentifier: GeofenceRules.regionIdentifier(for: id), transition: .enter)
        await delivery.waitForFlush()
        let pending = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(pending.map(\.type), ["geofence.created", "geofence.transitioned"])

        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        XCTAssertEqual(Set(api.sentBatches.flatMap { $0 }.map(\.eventID)), Set(pending.map(\.eventID)))
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Action draft

    @MainActor
    func testGeofenceDraftCreatesAfterConfirmationWithOrigin() async throws {
        let sink = RecordingEventSink()
        let geofences = makeGeofences(sink: sink)
        let draft = ActionDraft(draftID: ActionDraftFixtures.draftID, serverTime: ActionDraftFixtures.serverDate,
                                expiresAt: ActionDraftFixtures.serverDate.addingTimeInterval(600),
                                payload: .geofenceCreate(GeofenceDraftPayload(latitude: 55.7558, longitude: 37.6176,
                                                                              radiusMeters: 100, nameSuggestion: "Офис")))
        let drafts = ActionDraftCoordinator(store: VersionedJSONFileStore(directoryURL: directory.appendingPathComponent("Drafts"),
                                                                          fileName: ActionDraftStoreFile.fileName),
                                            fetcher: MockActionDraftFetcher(result: .success(draft)), sink: sink,
                                            now: { Fixtures.pairedAt })
        drafts.register(geofences, for: .geofenceCreate)
        await drafts.loadDraft(draft.draftID)
        XCTAssertEqual(system.log.count("requestAlways") + system.log.count("register"), 0, "loading registers nothing")
        await drafts.perform(draft.draftID)
        XCTAssertEqual(sink.events.map(\.type), ["geofence.created", "action_draft.accepted"])
        let created = try ContextFixtures.payload(XCTUnwrap(sink.events.first))
        XCTAssertEqual(created["origin"] as? String, "action_draft")
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.last))["result_ref"] as? String, created["geofence_id"] as? String)
        XCTAssertEqual(geofences.geofences.first?.name, "Офис")
    }

    // MARK: Storage

    @MainActor
    func testStoreFormatAndQuarantine() async throws {
        let geofences = makeGeofences(sink: RecordingEventSink())
        _ = try await created(geofences)
        let url = directory.appendingPathComponent(GeofencesFile.fileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "geofences", "pending_transitions", "last_transitions", "pending_removals"])
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("55.75581"), "only rounded coordinates are stored")
        XCTAssertFalse(text.contains("accuracy"))
        XCTAssertEqual(GeofencesFile.fileName, "geofences.json")
        XCTAssertEqual(GeofencesFile.currentVersion, 1)
        let path = GeofencesFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/Geofences/geofences.json"), path)
        try Data("nope".utf8).write(to: url)
        XCTAssertEqual(makeGeofences().storageIssue, .quarantined)
    }
}
