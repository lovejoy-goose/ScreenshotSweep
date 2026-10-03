import XCTest

/// V2-006: end-to-end client regressions for v0.2 — real coordinators, real queue files and the
/// real API client over a mocked network; only system adapters are mocked.
final class ContextReleaseValidationTests: XCTestCase {
    private var root: URL!
    private var clock: TestClock!

    private let batchPath = "/api/connector/events/batch"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        root = ContextFixtures.temporaryDirectory("ContextRelease")
        clock = TestClock()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// One app launch wired like `KatanaConnectorApp`, over files in `root`.
    @MainActor
    private struct Launch {
        let tokenStore: InMemoryTokenStore
        let client: URLSessionConnectorAPIClient
        let queue: EventQueue
        let delivery: EventDeliveryCoordinator
        let pairing: PairingCoordinator
        let journal: ActivityJournalCoordinator
        let checkIn: LocationCheckInCoordinator
        let reminders: ReminderCoordinator
        let motion: MockActivitySystem
        let location: MockCheckInLocationSystem
        let notifications: MockReminderNotifications
        let navigator = AppNavigator()
    }

    @MainActor
    private func launch(tokenStore: InMemoryTokenStore) -> Launch {
        let clock = self.clock!
        let client = URLSessionConnectorAPIClient(store: tokenStore,
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.2.0", systemVersion: "18.0", now: { clock.now() })
        let queue = EventQueue(store: EventQueueStore(directoryURL: root.appendingPathComponent("EventQueue")))
        let delivery = EventDeliveryCoordinator(api: client, queue: queue, registry: CapabilityRegistry(),
                                                syncState: InMemorySyncStateStore(),
                                                retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0, maxAttemptsPerFlush: 1),
                                                sleeper: RecordingSleeper(), random: { 0.5 }, now: { clock.now() })
        let pairing = PairingCoordinator(client: MockPairingClient(result: .success(Fixtures.response)), store: tokenStore) { name in
            PairingDeviceInfo(displayName: name, platform: "ios", appVersion: "0.2.0", systemVersion: "18.0")
        }
        delivery.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        let motion = MockActivitySystem()
        let location = MockCheckInLocationSystem()
        let notifications = MockReminderNotifications()
        let journal = ActivityJournalCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("ActivityJournal"),
                                                                               fileName: ActivityJournalFile.fileName),
                                                 system: motion, sink: delivery, sleeper: NeverSleeper(), now: { clock.now() })
        let checkIn = LocationCheckInCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("LocationCheckIn"),
                                                                               fileName: CheckInHistoryFile.fileName),
                                                 system: location, sink: delivery, sleeper: NeverSleeper(), now: { clock.now() })
        let reminders = ReminderCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("Reminders"),
                                                                          fileName: ReminderStoreFile.fileName),
                                            fetcher: client, notifications: notifications, sink: delivery, now: { clock.now() })
        return Launch(tokenStore: tokenStore, client: client, queue: queue, delivery: delivery, pairing: pairing, journal: journal,
                      checkIn: checkIn, reminders: reminders, motion: motion, location: location, notifications: notifications)
    }

    /// Katana stand-in: serves the draft and acknowledges every sent event.
    private func serveKatana(eventStatus: String = "accepted") {
        let acknowledge = MockURLProtocol.acknowledgeEvents(eventStatus)
        MockURLProtocol.handler = { request in
            if request.path.hasPrefix("/api/connector/reminder-drafts/") {
                return .response(status: 200, body: Data(ReminderFixtures.responseJSON().utf8))
            }
            return acknowledge(request)
        }
    }

    /// Every v0.2 action once: snapshot, session, check-in, reminder scheduled + cancelled.
    @MainActor
    private func runAllActions(_ app: Launch) async {
        await app.journal.checkCurrentActivity()
        await app.journal.sendSnapshot()
        await app.journal.startSession()
        clock.advance(30)
        await app.journal.finishSession()
        await app.journal.confirmSession()
        await app.checkIn.locate()
        app.checkIn.precision = .approximate
        await app.checkIn.send()
        await app.reminders.loadDraft(ReminderFixtures.draftID)
        await app.reminders.createReminder(ReminderFixtures.draftID)
        clock.advance(10)
        await app.reminders.cancelReminder(ReminderFixtures.draftID)
        await app.delivery.waitForFlush()
    }

    private func sentEvents() -> [[String: Any]] {
        MockURLProtocol.requests(to: batchPath).flatMap { request -> [[String: Any]] in
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return json?["events"] as? [[String: Any]] ?? []
        }
    }

    // MARK: Happy path and privacy audit of request bodies

    @MainActor
    func testAllContextActionsReachKatanaOnceWithExactPayloads() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        serveKatana()
        await runAllActions(app)

        let events = sentEvents()
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertEqual(Set(types), Set(ContextEventType.allCases.map(\.rawValue)))
        XCTAssertEqual(types.count, 5, "exactly one event per action")
        XCTAssertEqual(Set(events.compactMap { $0["event_id"] as? String }).count, 5)
        for event in events {
            XCTAssertEqual(Set(event.keys), ["event_id", "type", "occurred_at", "session_id", "payload"])
            let type = try XCTUnwrap(ContextEventType(rawValue: try XCTUnwrap(event["type"] as? String)))
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            XCTAssertEqual(Set(payload.keys), type.payloadKeys, type.rawValue)
        }
        for request in MockURLProtocol.requests(to: batchPath) {
            XCTAssertEqual(request.authorization, "Bearer \(Fixtures.token)")
        }
        let remaining = try await app.queue.pendingCount()
        XCTAssertEqual(remaining, 0)

        // The draft GET has no body; nothing but Bearer identifies the device.
        let draftRequests = MockURLProtocol.recorded.filter { $0.path.hasPrefix("/api/connector/reminder-drafts/") }
        XCTAssertEqual(draftRequests.count, 1)
        XCTAssertTrue(draftRequests.allSatisfy { $0.method == "GET" && $0.body.isEmpty })
    }

    @MainActor
    func testRequestBodiesCarryNoSecretsTextOrRawSensorData() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        serveKatana()
        app.location.fix = LocationFix(latitude: 55.7558149, longitude: 37.6176351, horizontalAccuracy: 17.25)
        await runAllActions(app)

        let forbidden = [Fixtures.token, Fixtures.code, "device_token", "pairing_code", "base_url", "device_id",
                         ReminderFixtures.title, ReminderFixtures.body, "\"title\"", "\"body\"",
                         "altitude", "speed", "course", "floor", "17.25", "vertical", "55.7558", "37.6176",
                         "samples", "timestamp", "segment", "file://", "/Users/", "Error Domain", "localizedDescription"]
        for request in MockURLProtocol.recorded where request.method == "POST" {
            let text = String(decoding: request.body, as: UTF8.self)
            for fragment in forbidden {
                XCTAssertFalse(text.contains(fragment), "\(request.path) contains \(fragment)")
            }
        }
        // Coordinates appear only in the check-in event, rounded as chosen.
        for event in sentEvents() {
            let payload = event["payload"] as? [String: Any] ?? [:]
            let isCheckIn = event["type"] as? String == "location.check_in.created"
            XCTAssertEqual(payload["latitude"] != nil, isCheckIn)
            if isCheckIn {
                XCTAssertEqual(payload["latitude"] as? Double, 55.76)
                XCTAssertEqual(payload["longitude"] as? Double, 37.62)
            }
        }
        XCTAssertNil(app.checkIn.preview, "coordinates are gone from state after enqueue")
    }

    // MARK: Offline → relaunch → exact-once

    @MainActor
    func testOfflineRelaunchDeliversEveryEventExactlyOnce() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let first = launch(tokenStore: tokenStore)
        MockURLProtocol.handler = { request in
            if request.path.hasPrefix("/api/connector/reminder-drafts/") {
                return .response(status: 200, body: Data(ReminderFixtures.responseJSON().utf8))
            }
            return .failure(.notConnectedToInternet)
        }
        await runAllActions(first)
        let queued = try await first.queue.pendingEvents(scope: EventFixtures.scope).map(\.eventID)
        XCTAssertEqual(queued.count, 5, "everything is on disk while offline")

        serveKatana(eventStatus: "accepted")
        let relaunched = launch(tokenStore: tokenStore)
        await relaunched.delivery.prepare()
        relaunched.delivery.requestFlush()
        await relaunched.delivery.waitForFlush()
        let acknowledged = sentEvents().compactMap { $0["event_id"] as? String }
        XCTAssertEqual(Set(acknowledged), Set(queued.map { $0.uuidString.lowercased() }), "same event IDs after relaunch")
        let remaining = try await relaunched.queue.pendingCount()
        XCTAssertEqual(remaining, 0)

        // Local histories survived the relaunch; nothing unconfirmed did.
        XCTAssertEqual(relaunched.journal.history.count, 2)
        XCTAssertEqual(relaunched.checkIn.history.count, 1)
        XCTAssertNil(relaunched.checkIn.preview)
        XCTAssertEqual(relaunched.reminders.record(for: ReminderFixtures.draftID)?.status, .cancelled)
        await relaunched.reminders.retryPendingEvents()
        relaunched.delivery.requestFlush()
        await relaunched.delivery.waitForFlush()
        XCTAssertEqual(sentEvents().count, acknowledged.count, "no event is sent twice")
    }

    // MARK: Revoke / repair

    @MainActor
    func testRevokeKeepsQueueStopsNetworkAndRepairDelivers() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let app = launch(tokenStore: tokenStore)
        MockURLProtocol.reply = .response(status: 401, body: Data())
        await app.journal.checkCurrentActivity()
        await app.journal.sendSnapshot()
        await app.delivery.waitForFlush()
        XCTAssertEqual(app.delivery.status, .requiresRepair)
        XCTAssertEqual(tokenStore.credentials?.requiresRepair, true)
        let kept = try await app.queue.pendingCount()
        XCTAssertEqual(kept, 1, "the queue survives 401")

        // With rejected credentials nothing is sent: not the queue, not a reminder draft.
        let requestsBefore = MockURLProtocol.requestCount
        await app.reminders.loadDraft(ReminderFixtures.draftID)
        XCTAssertEqual(app.reminders.phase(for: ReminderFixtures.draftID), .failed(.requiresRepair))
        app.delivery.requestFlush()
        await app.delivery.waitForFlush()
        XCTAssertEqual(MockURLProtocol.requestCount, requestsBefore, "the old token is never used again")
        await app.checkIn.locate()
        await app.checkIn.send()
        let stillQueued = try await app.queue.pendingCount()
        XCTAssertEqual(stillQueued, 2, "new results are still saved for this connection")

        // Re-pair to the same scope with a new token: the queue is delivered.
        serveKatana()
        app.pairing.handleScannedCode(Fixtures.qr())
        await app.pairing.confirm(displayName: "iPhone")
        XCTAssertEqual(tokenStore.credentials?.requiresRepair, false)
        app.delivery.pairingDidConnect()
        await app.delivery.waitForFlush()
        // pairingDidConnect also starts a capability report; let it finish inside this test.
        await waitUntil { MockURLProtocol.requests(to: "/api/connector/capabilities/report").count == 1 }
        let delivered = try await app.queue.pendingCount()
        XCTAssertEqual(delivered, 0)
    }

    @MainActor
    func testEventsNeverReachAnotherConnection() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        await app.checkIn.locate()
        await app.checkIn.send()
        await app.delivery.waitForFlush()

        let other = PairingCredentials(token: DeviceToken("tok_other_device"),
                                   device: PairedDevice(deviceID: "dev_other", displayName: "Other", pairedAt: Fixtures.pairedAt,
                                                        baseURL: Fixtures.baseURL))
        MockURLProtocol.recorded = []   // forget the failed offline attempt
        serveKatana()
        let relaunched = launch(tokenStore: InMemoryTokenStore(credentials: other))
        await relaunched.delivery.prepare()
        relaunched.delivery.requestFlush()
        await relaunched.delivery.waitForFlush()
        XCTAssertTrue(sentEvents().isEmpty, "another device never receives this check-in")
        XCTAssertEqual(relaunched.delivery.otherScopePendingCount, 1)
    }

    // MARK: Links

    @MainActor
    func testAllLinksOnlyNavigate() throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        let links: [(URL, [AppRoute])] = [
            (ConnectorURLRouter.url(for: .screenshotCleanup), [.screenshotCleanup]),
            (ConnectorURLRouter.url(for: .pairing), [.pairing]),
            (ConnectorURLRouter.url(for: .activityJournal), [.activityJournal]),
            (ConnectorURLRouter.url(for: .locationCheckIn), [.locationCheckIn]),
            (ConnectorURLRouter.url(for: .reminderDraft(ReminderFixtures.draftID)), [.reminders, .reminderDraft(ReminderFixtures.draftID)]),
        ]
        for (url, path) in links {
            XCTAssertTrue(app.navigator.handle(url), url.absoluteString)
            XCTAssertEqual(app.navigator.path, path)
        }
        XCTAssertEqual(ConnectorURLRouter.url(for: .screenshotCleanup).absoluteString, "katana-connector://open?v=1&feature=screenshot_cleanup")
        XCTAssertEqual(ConnectorURLRouter.url(for: .pairing).absoluteString, "katana-connector://open?v=1&feature=pairing")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no network")
        XCTAssertFalse(app.delivery.isFlushing, "no flush")
        XCTAssertEqual(app.motion.log.count("request") + app.motion.log.count("reading") + app.motion.log.count("start"), 0)
        XCTAssertEqual(app.location.log.count("requestWhenInUse") + app.location.log.count("fix"), 0)
        XCTAssertEqual(app.notifications.log.count("request") + app.notifications.log.count("schedule"), 0)
        XCTAssertEqual(app.reminders.phase(for: ReminderFixtures.draftID), .idle)
        XCTAssertNil(app.journal.session)
        XCTAssertNil(app.checkIn.preview)
    }

    // MARK: Update over the existing app, configuration, boundaries

    func testStorageIdentifiersOfV01AndV02StayStable() throws {
        XCTAssertEqual(KeychainTokenStore.service, "app.katana.connector.pairing")
        XCTAssertEqual(KeychainTokenStore.account, "device-credentials")
        XCTAssertEqual(EventQueueStore.fileName, "event-queue.json")
        XCTAssertEqual(EventQueueFile.currentVersion, 2)
        XCTAssertEqual(CapabilitySnapshotStore.fileName, "capability-snapshots.json")
        XCTAssertEqual(CapabilitySnapshotFile.currentVersion, 1)
        let expected: [(URL, String)] = [
            (ActivityJournalFile.applicationSupportStore().fileURL, "/KatanaConnector/ActivityJournal/activity-journal.json"),
            (CheckInHistoryFile.applicationSupportStore().fileURL, "/KatanaConnector/LocationCheckIn/check-ins.json"),
            (ReminderStoreFile.applicationSupportStore().fileURL, "/KatanaConnector/Reminders/reminders.json"),
            (EventQueueStore.applicationSupport().fileURL, "/KatanaConnector/EventQueue/event-queue.json"),
        ]
        for (url, suffix) in expected {
            let path = url.standardizedFileURL.path
            XCTAssertTrue(path.hasSuffix("/Application Support" + suffix), path)
        }
        XCTAssertEqual([ActivityJournalFile.currentVersion, CheckInHistoryFile.currentVersion, ReminderStoreFile.currentVersion], [1, 1, 1])

        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: app.katana.connector\n"))
        XCTAssertTrue(project.contains("MARKETING_VERSION: \"0.2.0\""))
    }

    func testInfoPlistHasNoAlwaysBackgroundOrEntitlements() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        for forbidden in ["NSLocationAlways", "UIBackgroundModes", "CODE_SIGN_ENTITLEMENTS", "entitlements", "aps-environment",
                          "NSBluetooth", "NFCReaderUsageDescription", "NSHealth", "BGTaskScheduler"] {
            XCTAssertFalse(project.contains(forbidden), forbidden)
        }
        let usageKeys = project.split(separator: "\n").filter { $0.contains("UsageDescription") }
        XCTAssertEqual(usageKeys.count, 4, "camera, location (When In Use), motion, photos — nothing new in v0.2")
        let location = try XCTUnwrap(usageKeys.first { $0.contains("NSLocationWhenInUseUsageDescription") })
        XCTAssertTrue(location.contains("Location Check-in") && location.contains("подтверждения"))
        let motion = try XCTUnwrap(usageKeys.first { $0.contains("NSMotionUsageDescription") })
        XCTAssertTrue(motion.contains("Activity Journal"))
        let plist = try Data(contentsOf: repositoryRoot.appendingPathComponent("Config/KatanaConnector-Info.plist"))
        let keys = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["CFBundleURLTypes"])
    }

    func testNewCodeKeepsFrameworkBoundariesAndLogsNothing() throws {
        let fileManager = FileManager.default
        let newDirectories = ["Sources/Core/Activity", "Sources/Core/LocationCheckIn", "Sources/Core/Reminders", "Sources/Core/Storage",
                              "Sources/Features/ActivityJournal", "Sources/Features/LocationCheckIn", "Sources/Features/Reminders"]
        var scanned = 0
        for directory in newDirectories {
            let url = repositoryRoot.appendingPathComponent(directory)
            for name in try fileManager.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(name))
                scanned += 1
                for forbidden in ["print(", "NSLog", "os_log", "Logger(", "UserDefaults", "import HealthKit", "import CoreNFC",
                                  "import CoreBluetooth", "BGTaskScheduler", "registerForRemoteNotifications"] {
                    XCTAssertFalse(text.contains(forbidden), "\(name) uses \(forbidden)")
                }
                if directory.hasPrefix("Sources/Core") {
                    XCTAssertFalse(text.contains("import Security"), name)
                    if text.contains("import Combine") {
                        XCTAssertTrue(name.hasSuffix("Coordinator.swift"), "Combine only in coordinators (D-024): \(name)")
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 13)
    }
}
