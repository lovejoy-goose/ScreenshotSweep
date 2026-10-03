import XCTest

/// KC-009: end-to-end client regressions for v0.1 on mocks — real coordinators, real queue
/// files, real API client; only the network (URLProtocol) and system adapters are mocked.
final class ConnectorReleaseValidationTests: XCTestCase {
    private var queueStore: EventQueueStore!

    private let cleanupPath = "/api/connector/events/batch"
    private let reportPath = "/api/connector/capabilities/report"
    private let checkPath = "/api/connector/connection/check"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        queueStore = EventFixtures.makeTemporaryStore()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: queueStore.directoryURL)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// One app launch: real API client over the mocked network, a fresh queue instance over the same file.
    @MainActor
    private struct Launch {
        let tokenStore: InMemoryTokenStore
        let queue: EventQueue
        let delivery: EventDeliveryCoordinator
        let pairing: PairingCoordinator
        let recorder: CleanupSessionRecorder
        let navigator = AppNavigator()
    }

    @MainActor
    private func launch(tokenStore: InMemoryTokenStore, sleeper: any DeliverySleeper = RecordingSleeper(),
                        attempts: Int = 2, pairingClient: MockPairingClient = MockPairingClient(result: .success(Fixtures.response))) -> Launch {
        let queue = EventQueue(store: EventQueueStore(directoryURL: queueStore.directoryURL))
        let client = URLSessionConnectorAPIClient(store: tokenStore,
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0", now: { Fixtures.pairedAt })
        let delivery = EventDeliveryCoordinator(api: client, queue: queue, registry: CapabilityRegistry(),
                                                syncState: InMemorySyncStateStore(),
                                                retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0, maxAttemptsPerFlush: attempts),
                                                sleeper: sleeper, random: { 0.5 }, now: { Fixtures.pairedAt })
        let pairing = PairingCoordinator(client: pairingClient, store: tokenStore) { name in
            PairingDeviceInfo(displayName: name, platform: "ios", appVersion: "0.1.0", systemVersion: "18.0")
        }
        delivery.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        let recorder = CleanupSessionRecorder(sink: delivery, now: { Fixtures.pairedAt })
        return Launch(tokenStore: tokenStore, queue: queue, delivery: delivery, pairing: pairing, recorder: recorder)
    }

    @MainActor
    private func cleanupSession(_ recorder: CleanupSessionRecorder) {
        recorder.recordDecision(.keep, assetID: "LOCAL-ASSET-A/L0/001")
        recorder.recordDecision(.delete, assetID: "LOCAL-ASSET-B/L0/001")
        recorder.willDelete(assetIDs: ["LOCAL-ASSET-B/L0/001"])
        recorder.didFinishDeletion(assetIDs: ["LOCAL-ASSET-B/L0/001"], success: true)
        recorder.recordDecision(.keep, assetID: "LOCAL-ASSET-C/L0/001")
    }

    @MainActor
    private func completed(_ recorder: CleanupSessionRecorder) async throws -> CleanupSessionRecorder.Completion {
        let completion = await recorder.complete()
        return try XCTUnwrap(completion)
    }

    @MainActor
    private func completedEventID(_ recorder: CleanupSessionRecorder) async throws -> UUID {
        let completion = await recorder.complete()
        return try XCTUnwrap(completion?.eventID)
    }

    private func sentEventIDs() -> [String] {
        MockURLProtocol.requests(to: cleanupPath).flatMap { request -> [String] in
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return (json?["events"] as? [[String: Any]])?.compactMap { $0["event_id"] as? String } ?? []
        }
    }

    // MARK: 1. Happy path

    @MainActor
    func testHappyPathFromLinkToDeliveredEvent() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        XCTAssertEqual(app.pairing.status, .connected(Fixtures.credentials.device))
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")

        XCTAssertTrue(app.navigator.handle(ConnectorURLRouter.url(for: .screenshotCleanup)))
        XCTAssertEqual(app.navigator.path, [.screenshotCleanup])

        cleanupSession(app.recorder)
        let completion = try await completed(app.recorder)
        await app.delivery.waitForFlush()

        let eventID = try XCTUnwrap(completion.eventID)
        XCTAssertEqual(completion.outcome, .saved)
        XCTAssertEqual(sentEventIDs(), [eventID.uuidString.lowercased()])
        XCTAssertEqual(MockURLProtocol.requests(to: cleanupPath).first?.authorization, "Bearer \(Fixtures.token)")
        XCTAssertTrue(app.delivery.deliveredEventIDs.contains(eventID))
        let pending = try await app.queue.pendingCount()
        XCTAssertEqual(pending, 0)

        // Another flush (manual sync) sends nothing again.
        app.delivery.requestFlush()
        await app.delivery.waitForFlush()
        XCTAssertEqual(MockURLProtocol.requests(to: cleanupPath).count, 1)
        XCTAssertEqual(completion.summary.reviewedCount, 3)
        XCTAssertEqual(completion.summary.deletionRequestedCount, 1)
        XCTAssertTrue(completion.summary.deletionCompleted)
    }

    // MARK: 2. Exact-once within the client

    @MainActor
    func testDoubleCompletionCreatesOneEvent() async throws {
        let sink = FakeCleanupSink()
        let recorder = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        cleanupSession(recorder)

        async let first = recorder.complete()
        async let second = recorder.complete()
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNil(recorder.previewSummary(), "reopening the summary has nothing to complete")
        let third = await recorder.complete()
        XCTAssertNil(third)
        XCTAssertEqual(sink.events.count, 1)
    }

    @MainActor
    func testDuplicateResponseCountsAsDelivered() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("duplicate")
        cleanupSession(app.recorder)
        let completion = try await completed(app.recorder)
        await app.delivery.waitForFlush()

        let pending = try await app.queue.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(app.delivery.deliveredEventIDs.contains(try XCTUnwrap(completion.eventID)))
    }

    @MainActor
    func testRetryableErrorThenRelaunchSendsSameEventID() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let first = launch(tokenStore: tokenStore)
        MockURLProtocol.reply = .response(status: 503, body: Data())
        cleanupSession(first.recorder)
        let completion = try await completed(first.recorder)
        await first.delivery.waitForFlush()
        let eventID = try XCTUnwrap(completion.eventID).uuidString.lowercased()

        XCTAssertEqual(first.delivery.status, .failed(.serverError))
        XCTAssertEqual(Set(sentEventIDs()), [eventID], "retries reuse the same event_id")
        let stillQueued = try await first.queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(stillQueued.map { $0.eventID.uuidString.lowercased() }, [eventID])

        // "Relaunch": new coordinator and queue instance over the same file.
        MockURLProtocol.reset()
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        let second = launch(tokenStore: tokenStore)
        await second.delivery.prepare()
        second.delivery.requestFlush()
        await second.delivery.waitForFlush()

        XCTAssertEqual(sentEventIDs(), [eventID], "the same event_id, not a new one")
        let pending = try await second.queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: 3. Offline → online

    @MainActor
    func testOfflineThenOnlineKeepsFIFOAndScope() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let seed = EventQueue(store: queueStore)
        try await seed.enqueue(EventFixtures.event(9), scope: EventFixtures.otherDeviceScope)

        let offline = launch(tokenStore: tokenStore)
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        cleanupSession(offline.recorder)
        let firstID = try await completedEventID(offline.recorder)
        cleanupSession(offline.recorder)
        let secondID = try await completedEventID(offline.recorder)
        await offline.delivery.waitForFlush()
        XCTAssertEqual(offline.delivery.status, .failed(.offline))

        // On disk across a relaunch.
        let reopened = EventQueue(store: EventQueueStore(directoryURL: queueStore.directoryURL))
        let onDisk = try await reopened.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(onDisk.map(\.eventID), [firstID, secondID])

        // Online again; Katana acknowledges only the first event in this response.
        MockURLProtocol.reset()
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted", only: [firstID])
        let online = launch(tokenStore: tokenStore)
        online.delivery.requestFlush()
        await online.delivery.waitForFlush()
        XCTAssertEqual(sentEventIDs().first, firstID.uuidString.lowercased(), "FIFO")
        var remaining = try await online.queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(remaining.map(\.eventID), [secondID], "only the acknowledged event is removed")

        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        await online.delivery.synchronize()
        remaining = try await online.queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(remaining, [])
        let other = try await online.queue.pendingEvents(scope: EventFixtures.otherDeviceScope)
        XCTAssertEqual(other, [EventFixtures.event(9)], "another connection's event is never sent")
        XCTAssertFalse(sentEventIDs().contains(EventFixtures.event(9).eventID.uuidString.lowercased()))
    }

    // MARK: 4. Kill / relaunch during send

    @MainActor
    func testKillDuringSendLosesNothingAndRetriesSameEventID() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let api = MockConnectorAPI()
        let gotRequest = Counter()
        api.batchHandler = { _ in
            _ = gotRequest.increment()
            try await Task.sleep(nanoseconds: 60_000_000_000) // the request is in flight when the app dies
            return [:]
        }
        let queue = EventQueue(store: queueStore)
        let dying = EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                             syncState: InMemorySyncStateStore(), sleeper: RecordingSleeper(),
                                             random: { 0.5 }, now: { Fixtures.pairedAt })
        let recorder = CleanupSessionRecorder(sink: dying, now: { Fixtures.pairedAt })
        cleanupSession(recorder)
        let eventID = try await completedEventID(recorder)
        await waitUntil { api.batchCalls == 1 }
        dying.cancelFlush() // the process is killed: nothing after this point runs
        await dying.waitForFlush()

        // Relaunch. Katana may already have stored the first attempt → it answers duplicate.
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("duplicate")
        let relaunched = launch(tokenStore: tokenStore)
        await relaunched.delivery.prepare()
        XCTAssertEqual(relaunched.delivery.pendingCount, 1, "the unacknowledged event survived")
        relaunched.delivery.requestFlush()
        await relaunched.delivery.waitForFlush()

        XCTAssertEqual(api.sentBatches.first?.map(\.eventID), [eventID])
        XCTAssertEqual(sentEventIDs(), [eventID.uuidString.lowercased()], "same event_id on retry")
        let pending = try await relaunched.queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: 5. Revoke → 401 → repair

    @MainActor
    func testRevokeThenRepairSameAndOtherScope() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let app = launch(tokenStore: tokenStore)
        MockURLProtocol.reply = .response(status: 401, body: Data("{}".utf8))
        cleanupSession(app.recorder)
        let eventID = try await completedEventID(app.recorder)
        await app.delivery.waitForFlush()

        XCTAssertEqual(app.delivery.status, .requiresRepair)
        XCTAssertEqual(app.pairing.status, .requiresRepair(Fixtures.credentials.device), "UI offers to pair again")
        XCTAssertEqual(tokenStore.credentials?.requiresRepair, true)
        XCTAssertEqual(tokenStore.deleteCount, 0)
        let requestsAfter401 = MockURLProtocol.requestCount

        // Nothing automatic uses the revoked token any more — also after a relaunch.
        app.delivery.appBecameActive()
        await app.delivery.synchronize()
        let relaunch = launch(tokenStore: tokenStore)
        XCTAssertEqual(relaunch.pairing.status, .requiresRepair(Fixtures.credentials.device))
        relaunch.delivery.appBecameActive()
        await relaunch.delivery.waitForFlush()
        await relaunch.delivery.checkConnection()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(MockURLProtocol.requestCount, requestsAfter401)
        let kept = try await relaunch.queue.pendingCount()
        XCTAssertEqual(kept, 1, "the queue is kept")

        // Re-pair to the same Katana and device (new token): its queue is delivered.
        let samePair = MockPairingClient(result: .success(PairingCompleteResponse(
            deviceID: "dev_fixture", deviceToken: DeviceToken("tok_repaired_fixture"), displayName: "iPhone", pairedAt: Fixtures.pairedAt)))
        let repaired = launch(tokenStore: tokenStore, pairingClient: samePair)
        repaired.pairing.handleScannedCode(Fixtures.qr())
        XCTAssertEqual(repaired.pairing.deviceToReplace, Fixtures.credentials.device)
        await repaired.pairing.confirm(displayName: "iPhone")
        MockURLProtocol.reset()
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        repaired.delivery.pairingDidConnect()
        await repaired.delivery.waitForFlush()
        XCTAssertEqual(sentEventIDs(), [eventID.uuidString.lowercased()])
        XCTAssertEqual(MockURLProtocol.requests(to: cleanupPath).first?.authorization, "Bearer tok_repaired_fixture")

        // An event recorded now, then pairing to another device: it is not sent there.
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        MockURLProtocol.handler = nil
        cleanupSession(repaired.recorder)
        let pendingID = try await completedEventID(repaired.recorder)
        await repaired.delivery.waitForFlush()
        tokenStore.credentials = PairingCredentials(
            token: DeviceToken("tok_other_fixture"),
            device: PairedDevice(deviceID: "dev_other", displayName: "iPhone", pairedAt: Fixtures.pairedAt, baseURL: Fixtures.baseURL))
        MockURLProtocol.reset()
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        let other = launch(tokenStore: tokenStore)
        await other.delivery.prepare()
        other.delivery.requestFlush()
        await other.delivery.waitForFlush()
        XCTAssertEqual(MockURLProtocol.requests(to: cleanupPath).count, 0)
        XCTAssertEqual(other.delivery.otherScopePendingCount, 1)
        let stranded = try await other.queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(stranded.map(\.eventID), [pendingID])
    }

    // MARK: 6. Update over the existing app: stable identifiers

    func testStorageIdentifiersStayStable() throws {
        // Changing any of these makes an update look like a new app: pairing, queue or results would be lost.
        XCTAssertEqual(KeychainTokenStore.service, "app.katana.connector.pairing")
        XCTAssertEqual(KeychainTokenStore.account, "device-credentials")
        XCTAssertEqual(EventQueueStore.fileName, "event-queue.json")
        XCTAssertEqual(EventQueueFile.currentVersion, 2)
        XCTAssertEqual(CapabilitySnapshotStore.fileName, "capability-snapshots.json")
        XCTAssertEqual(CapabilitySnapshotFile.currentVersion, 1)

        let queueDirectory = EventQueueStore.applicationSupport().directoryURL.standardizedFileURL.path
        XCTAssertTrue(queueDirectory.hasSuffix("/Application Support/KatanaConnector/EventQueue"), queueDirectory)
        let capabilityDirectory = CapabilitySnapshotStore.applicationSupport().directoryURL.standardizedFileURL.path
        XCTAssertTrue(capabilityDirectory.hasSuffix("/Application Support/KatanaConnector/Capabilities"), capabilityDirectory)

        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: app.katana.connector\n"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_CFBundleDisplayName: Katana Connector"))

        let defaults = UserDefaults(suiteName: "ConnectorReleaseValidationTests")!
        defaults.removePersistentDomain(forName: "ConnectorReleaseValidationTests")
        UserDefaultsSyncStateStore(defaults: defaults).lastSuccessfulSync = Fixtures.pairedAt
        XCTAssertEqual(defaults.object(forKey: "connector.lastSuccessfulSyncAt") as? Date, Fixtures.pairedAt)
    }

    // MARK: 7. URL security

    @MainActor
    func testLinksOnlyNavigate() throws {
        XCTAssertEqual(ConnectorURLRouter.url(for: .screenshotCleanup).absoluteString, "katana-connector://open?v=1&feature=screenshot_cleanup")
        XCTAssertEqual(ConnectorURLRouter.url(for: .pairing).absoluteString, "katana-connector://open?v=1&feature=pairing")

        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let app = launch(tokenStore: tokenStore)
        for url in [ConnectorURLRouter.url(for: .screenshotCleanup), ConnectorURLRouter.url(for: .pairing)] {
            XCTAssertTrue(app.navigator.handle(url))
        }
        for text in ["katana-connector://open?v=1&feature=pairing&token=x",
                     "katana-connector://open?v=1&feature=pairing&code=x",
                     "katana-connector://open?v=1&feature=screenshot_cleanup&base_url=https%3A%2F%2Fevil.example",
                     "katana-connector://open?v=1&feature=delete_all"] {
            XCTAssertFalse(app.navigator.handle(URL(string: text)!), text)
        }
        XCTAssertEqual(app.navigator.path, [.pairing])
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no network")
        XCTAssertFalse(app.delivery.isFlushing, "no flush")
        XCTAssertEqual(app.pairing.status, .connected(Fixtures.credentials.device), "no pairing")
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertFalse(app.recorder.tracker.hasActivity, "no cleanup or deletion")
    }

    // MARK: 8. Privacy audit of serialized request bodies

    private static let forbiddenFragments = [
        Fixtures.token, Fixtures.code, "LOCAL-ASSET", "/L0/001", "file://", "/var/", "/Users/", "/private/",
        ".jpg", ".jpeg", ".png", ".heic", ".mov", "exif", "latitude", "longitude", "altitude", "coordinate",
        "localIdentifier", "thumbnail", "base64", "Error Domain", "NSError", "localizedDescription",
        "activity", "acceleration", "pairing_code", "device_token",
    ]

    private func assertClean(_ body: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: body), "\(name) is JSON text", file: file, line: line)
        for fragment in Self.forbiddenFragments {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(fragment), "\(name) contains \(fragment)", file: file, line: line)
        }
    }

    @MainActor
    func testCleanupRequestBodyHasExactlySevenAggregateFields() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        cleanupSession(app.recorder)
        _ = await app.recorder.complete()
        await app.delivery.waitForFlush()

        let body = try XCTUnwrap(MockURLProtocol.requests(to: cleanupPath).first?.body)
        assertClean(body, "events/batch")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["events"])
        let event = try XCTUnwrap((json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(event.keys), ["event_id", "type", "occurred_at", "session_id", "payload"])
        XCTAssertEqual(event["type"] as? String, "screenshot_cleanup.completed")
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["session_id", "started_at", "completed_at", "reviewed_count",
                                           "kept_count", "deletion_requested_count", "deletion_completed"])
        for (key, value) in payload {
            switch key {
            case "reviewed_count", "kept_count", "deletion_requested_count": XCTAssertTrue(value is NSNumber, key)
            case "deletion_completed": XCTAssertTrue((value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false, key)
            default: XCTAssertLessThanOrEqual((value as? String)?.count ?? 999, 36, key)
            }
        }
    }

    @MainActor
    func testCapabilityReportBodyIsClean() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = MockCameraSystem()
        camera.status = .authorized
        let location = MockLocationSystem()
        location.status = .authorizedWhenInUse
        let notifications = MockNotificationSystem()
        notifications.status = .authorized
        notifications.scheduleError = NSError(domain: "UNErrorDomain", code: 7,
                                              userInfo: [NSLocalizedDescriptionKey: "Error Domain raw system text"])
        let lab = CapabilityLabCoordinator(store: CapabilitySnapshotStore(directoryURL: directory),
                                           probes: [CameraProbe(system: camera), CurrentLocationProbe(system: location),
                                                    MotionProbe(system: MockMotionSystem()),
                                                    LocalNotificationsProbe(system: notifications)],
                                           sleeper: NeverSleeper(), now: { Fixtures.pairedAt })
        for id in [CapabilityID.camera, .currentLocation, .localNotifications] {
            lab.start(id)
            await lab.waitForProbe(id)
        }

        let client = URLSessionConnectorAPIClient(store: InMemoryTokenStore(credentials: Fixtures.credentials),
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0", now: { Fixtures.pairedAt })
        MockURLProtocol.reply = .response(status: 200, body: Data(#"{"ok":true}"#.utf8))
        try await client.reportCapabilities(lab.registry.snapshots())

        let body = try XCTUnwrap(MockURLProtocol.requests(to: reportPath).first?.body)
        assertClean(body, "capabilities/report")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["reported_at", "device", "capabilities"])
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertTrue(Set(device.keys).isSubset(of: ["device_id", "display_name", "app_version", "system_version",
                                                     "connection_state", "last_seen_at"]))
        let capabilities = try XCTUnwrap(json["capabilities"] as? [[String: Any]])
        XCTAssertEqual(capabilities.count, CapabilityID.allCases.count)
        let allowedDetails = Set(CapabilityProbeDetail.allCases.map(\.rawValue))
        for capability in capabilities {
            XCTAssertTrue(Set(capability.keys).isSubset(of: ["id", "availability", "authorization", "probe_state", "checked_at", "detail"]))
            if let detail = capability["detail"] as? String { XCTAssertTrue(allowedDetails.contains(detail), detail) }
        }
        XCTAssertEqual(capabilities.first { $0["id"] as? String == "local_notifications" }?["detail"] as? String, "system_error")
    }

    @MainActor
    func testNoRequestBodyCarriesSecrets() async throws {
        // Every request the client can send in a full session, scanned as bytes on the wire.
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        await app.delivery.checkConnection()
        _ = await app.delivery.reportCapabilities()
        cleanupSession(app.recorder)
        _ = await app.recorder.complete()
        await app.delivery.waitForFlush()

        XCTAssertEqual(Set(MockURLProtocol.recorded.map(\.path)), [checkPath, reportPath, cleanupPath])
        for request in MockURLProtocol.recorded {
            if request.method == "GET" {
                XCTAssertTrue(request.body.isEmpty)
            } else {
                assertClean(request.body, request.path)
            }
        }
    }

    // MARK: 9. Capability regressions

    @MainActor
    func testCapabilityLabCreatesNoEventsAndForegroundDoesNotProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = MockLocationSystem()
        let camera = MockCameraSystem()
        let lab = CapabilityLabCoordinator(store: CapabilitySnapshotStore(directoryURL: directory),
                                           probes: [CameraProbe(system: camera), CurrentLocationProbe(system: location),
                                                    MotionProbe(system: MockMotionSystem()),
                                                    LocalNotificationsProbe(system: MockNotificationSystem())],
                                           sleeper: NeverSleeper(), now: { Fixtures.pairedAt })
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        MockURLProtocol.handler = MockURLProtocol.acknowledgeEvents("accepted")
        lab.onSnapshotsChanged = { [weak delivery = app.delivery] in Task { await delivery?.reportCapabilities() } }

        // Foreground refresh: no prompt, no probe.
        await lab.refreshAuthorizations()
        XCTAssertEqual(location.log.count("requestWhenInUse") + location.log.count("fix"), 0)
        XCTAssertEqual(camera.log.count("request") + camera.log.count("capture"), 0)

        // Stale refresh vs. probe: the probe result stays.
        let gate = FirstCallGate()
        location.permissionGate = gate
        let refresh = Task { await lab.refreshAuthorizations() }
        await waitUntil { gate.isWaiting }
        lab.start(.currentLocation)
        await lab.waitForProbe(.currentLocation)
        gate.open()
        await refresh.value
        let snapshot = lab.snapshot(for: .currentLocation)
        XCTAssertEqual([snapshot.authorization.rawValue, snapshot.probeState.rawValue, snapshot.detail],
                       ["granted", "passed", "location_fix_received"])

        let pending = try await app.queue.pendingCount()
        XCTAssertEqual(pending, 0, "Capability Lab never creates Connector events")
        XCTAssertEqual(MockURLProtocol.requests(to: cleanupPath).count, 0)
    }
}
