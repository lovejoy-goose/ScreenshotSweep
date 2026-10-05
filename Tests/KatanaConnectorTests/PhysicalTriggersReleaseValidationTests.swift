import XCTest

/// V3-006: end-to-end client regressions for v0.3 — real coordinators, real queue and store files,
/// the real API client over a mocked network; only system adapters are mocked.
final class PhysicalTriggersReleaseValidationTests: XCTestCase {
    private var root: URL!
    private var clock: TestClock!

    private let batchPath = "/api/connector/events/batch"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        root = ContextFixtures.temporaryDirectory("PhysicalRelease")
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

    @MainActor
    private struct Launch {
        let tokenStore: InMemoryTokenStore
        let queue: EventQueue
        let delivery: EventDeliveryCoordinator
        let pairing: PairingCoordinator
        let drafts: ActionDraftCoordinator
        let nfc: NFCActionCoordinator
        let geofences: GeofenceCoordinator
        let capture: CaptureCoordinator
        let location: MockGeofenceSystem
        let tags: MockNFCTagSystem
    }

    @MainActor
    private func launch(tokenStore: InMemoryTokenStore) -> Launch {
        let clock = self.clock!
        let client = URLSessionConnectorAPIClient(store: tokenStore,
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.3.0", systemVersion: "18.0", now: { clock.now() })
        let queue = EventQueue(store: EventQueueStore(directoryURL: root.appendingPathComponent("EventQueue")))
        let delivery = EventDeliveryCoordinator(api: client, queue: queue, registry: CapabilityRegistry(),
                                                syncState: InMemorySyncStateStore(),
                                                retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0, maxAttemptsPerFlush: 1),
                                                sleeper: RecordingSleeper(), random: { 0.5 }, now: { clock.now() })
        let pairing = PairingCoordinator(client: MockPairingClient(result: .success(Fixtures.response)), store: tokenStore) { name in
            PairingDeviceInfo(displayName: name, platform: "ios", appVersion: "0.3.0", systemVersion: "18.0")
        }
        delivery.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        let drafts = ActionDraftCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("ActionDrafts"),
                                                                          fileName: ActionDraftStoreFile.fileName),
                                            fetcher: client, sink: delivery, now: { clock.now() })
        let tags = MockNFCTagSystem()
        let nfc = NFCActionCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("NFCActions"),
                                                                     fileName: NFCActionsFile.fileName),
                                       tags: tags, sink: delivery, now: { clock.now() })
        let location = MockGeofenceSystem()
        let geofences = GeofenceCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("Geofences"),
                                                                          fileName: GeofencesFile.fileName),
                                            system: location, sink: delivery, sleeper: NeverSleeper(), now: { clock.now() })
        let inbox = CaptureInboxStore(directoryURL: root.appendingPathComponent("CaptureInbox"))
        let capture = CaptureCoordinator(inboxes: [inbox],
                                         historyStore: VersionedJSONFileStore(directoryURL: inbox.directoryURL,
                                                                              fileName: CaptureHistoryFile.fileName),
                                         uploader: client, sink: delivery, now: { clock.now() })
        capture.actionDrafts = drafts
        drafts.register(nfc, for: .nfcAction)
        drafts.register(geofences, for: .geofenceCreate)
        drafts.register(capture, for: .sharedCapture)
        return Launch(tokenStore: tokenStore, queue: queue, delivery: delivery, pairing: pairing, drafts: drafts, nfc: nfc,
                      geofences: geofences, capture: capture, location: location, tags: tags)
    }

    /// Katana stand-in: serves an NFC draft, accepts uploads and acknowledges every event.
    private func serveKatana(eventStatus: String = "accepted", eventsOnline: Bool = true) {
        let acknowledge = MockURLProtocol.acknowledgeEvents(eventStatus)
        MockURLProtocol.handler = { request in
            if request.path.hasPrefix("/api/connector/action-drafts/") {
                return .response(status: 200, body: Data(ActionDraftFixtures.json().utf8))
            }
            if request.path.hasPrefix("/api/connector/captures/") {
                let id = request.path.components(separatedBy: "/").last ?? ""
                let sha = CaptureHash.sha256(request.body)
                return .response(status: 201, body: Data(
                    #"{"capture_id":"\#(id)","object_ref":"cap_1","size_bytes":\#(request.body.count),"sha256":"\#(sha)"}"#.utf8))
            }
            if request.path == "/api/connector/events/batch", !eventsOnline { return .failure(.notConnectedToInternet) }
            return acknowledge(request)
        }
    }

    /// Every v0.3 action once.
    @MainActor
    private func runAllActions(_ app: Launch) async throws {
        await app.drafts.loadDraft(ActionDraftFixtures.draftID)
        await app.drafts.perform(ActionDraftFixtures.draftID)                         // action_draft.accepted
        app.nfc.open(actionID: ActionDraftFixtures.actionID, source: .shortcut)
        await app.nfc.decide(actionID: ActionDraftFixtures.actionID, result: .confirmed)  // nfc.action.completed
        await app.geofences.locate()
        app.geofences.draftName = "Дом"
        await app.geofences.registerDraft()                                            // geofence.created
        guard case .created(let geofenceID) = app.geofences.phase else { return XCTFail("geofence not created") }
        await app.geofences.handleTransition(regionIdentifier: GeofenceRules.regionIdentifier(for: geofenceID), transition: .enter)
        await app.geofences.remove(geofenceID: geofenceID)                             // geofence.removed
        app.capture.importText(CaptureFixtures.secretText)
        let sent = try XCTUnwrap(app.capture.items.first?.captureID)
        await app.capture.confirm(sent)                                                // share.capture.created
        app.capture.importURL(CaptureFixtures.link)
        let cancelled = try XCTUnwrap(app.capture.items.first?.captureID)
        await app.capture.cancel(cancelled)                                            // share.capture.cancelled
        await app.delivery.waitForFlush()
    }

    private func sentEvents() -> [[String: Any]] {
        MockURLProtocol.requests(to: batchPath).flatMap { request -> [[String: Any]] in
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return json?["events"] as? [[String: Any]] ?? []
        }
    }

    // MARK: Happy path, exact payloads, privacy byte audit

    @MainActor
    func testAllV03ActionsReachKatanaOnceWithExactPayloads() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        serveKatana()
        try await runAllActions(app)

        let events = sentEvents()
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertEqual(Set(types), Set(ContextEventType.version03.map(\.rawValue)))
        XCTAssertEqual(types.count, 7, "exactly one event per action")
        for event in events {
            let type = try XCTUnwrap(ContextEventType(rawValue: try XCTUnwrap(event["type"] as? String)))
            XCTAssertEqual(Set(try XCTUnwrap(event["payload"] as? [String: Any]).keys), type.payloadKeys, type.rawValue)
        }
        let remaining = try await app.queue.pendingCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(MockURLProtocol.recorded.filter { $0.path.hasPrefix("/api/connector/action-drafts/") }.count, 1)
        XCTAssertEqual(MockURLProtocol.recorded.filter { $0.method == "PUT" }.count, 1, "only the confirmed capture is uploaded")
    }

    @MainActor
    func testEventBodiesCarryNoContentTagDataOrCoordinatesOfCrossings() async throws {
        let app = launch(tokenStore: InMemoryTokenStore(credentials: Fixtures.credentials))
        serveKatana()
        try await runAllActions(app)
        let forbidden = [Fixtures.token, "device_token", "Секретная", "example.invalid", "Открыть дверь", "Дом", "uid", "ndef",
                         "file://", "/Users/", "/var/", "localIdentifier", "exif", "gps", "55.75581", "Error Domain", "title", "body"]
        for request in MockURLProtocol.requests(to: batchPath) {
            let text = String(decoding: request.body, as: UTF8.self)
            for fragment in forbidden {
                XCTAssertFalse(text.lowercased().contains(fragment.lowercased()), "events/batch contains \(fragment)")
            }
        }
        for event in sentEvents() where (event["type"] as? String)?.hasPrefix("geofence.") == true {
            let payload = event["payload"] as? [String: Any] ?? [:]
            XCTAssertEqual(payload["latitude"] != nil, event["type"] as? String == "geofence.created",
                           "coordinates only when the geofence is created")
        }
        // The uploaded content is exactly what the user confirmed, and only in the PUT body.
        let put = try XCTUnwrap(MockURLProtocol.recorded.first { $0.method == "PUT" })
        XCTAssertEqual(put.body, Data(CaptureFixtures.secretText.utf8))
        XCTAssertNil(MockURLProtocol.lastRequest?.url?.query)
    }

    // MARK: Offline → relaunch → exact-once

    @MainActor
    func testOfflineRelaunchDeliversEveryEventOnce() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let first = launch(tokenStore: tokenStore)
        serveKatana(eventsOnline: false)
        try await runAllActions(first)
        let queued = try await first.queue.pendingEvents(scope: EventFixtures.scope).map(\.eventID)
        XCTAssertEqual(queued.count, 7, "everything is on disk while offline")

        MockURLProtocol.recorded = []
        serveKatana()
        let relaunched = launch(tokenStore: tokenStore)
        await relaunched.delivery.prepare()
        await relaunched.drafts.retryPendingEvents()
        await relaunched.nfc.retryPendingEvents()
        await relaunched.geofences.saveEvents()
        await relaunched.capture.resumePending()
        relaunched.delivery.requestFlush()
        await relaunched.delivery.waitForFlush()
        let sent = sentEvents().compactMap { $0["event_id"] as? String }
        XCTAssertEqual(Set(sent), Set(queued.map { $0.uuidString.lowercased() }))
        XCTAssertEqual(sent.count, 7, "no event is sent twice")
        XCTAssertEqual(relaunched.drafts.phase(for: ActionDraftFixtures.draftID), .accepted, "not executable again")
    }

    // MARK: Revoke / repair

    @MainActor
    func testRevokeStopsNetworkKeepsQueueAndRepairDelivers() async throws {
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let app = launch(tokenStore: tokenStore)
        serveKatana()
        await app.drafts.loadDraft(ActionDraftFixtures.draftID)
        await app.drafts.perform(ActionDraftFixtures.draftID)
        await app.delivery.waitForFlush()

        MockURLProtocol.handler = nil
        MockURLProtocol.reply = .response(status: 401, body: Data())
        app.nfc.open(actionID: ActionDraftFixtures.actionID, source: .shortcut)
        await app.nfc.decide(actionID: ActionDraftFixtures.actionID, result: .confirmed)
        await app.delivery.waitForFlush()
        XCTAssertEqual(app.delivery.status, .requiresRepair)
        XCTAssertEqual(tokenStore.credentials?.requiresRepair, true)

        let before = MockURLProtocol.requestCount
        await app.drafts.loadDraft(UUID())
        app.capture.importText("after revoke")
        await app.capture.confirm(try XCTUnwrap(app.capture.items.first?.captureID))
        XCTAssertEqual(MockURLProtocol.requestCount, before, "no request with the revoked token")
        XCTAssertEqual(app.capture.items.first?.state, .confirmed, "kept for after re-pairing")
        let kept = try await app.queue.pendingCount()
        XCTAssertEqual(kept, 1)

        serveKatana()
        app.pairing.handleScannedCode(Fixtures.qr())
        await app.pairing.confirm(displayName: "iPhone")
        app.delivery.pairingDidConnect()
        await app.capture.resumePending()
        await app.delivery.waitForFlush()
        await waitUntil { MockURLProtocol.requests(to: "/api/connector/capabilities/report").count == 1 }
        let left = try await app.queue.pendingCount()
        XCTAssertEqual(left, 0)
        XCTAssertTrue(app.capture.items.isEmpty)
    }

    // MARK: Identifiers, configuration, packaging, boundaries

    func testStorageIdentifiersOfAllVersionsStayStable() throws {
        XCTAssertEqual(KeychainTokenStore.service, "app.katana.connector.pairing")
        XCTAssertEqual(KeychainTokenStore.account, "device-credentials")
        XCTAssertEqual(EventQueueStore.fileName, "event-queue.json")
        XCTAssertEqual(EventQueueFile.currentVersion, 2)
        XCTAssertEqual(CapabilitySnapshotStore.fileName, "capability-snapshots.json")
        let expected: [(URL, String)] = [
            (ActivityJournalFile.applicationSupportStore().fileURL, "/KatanaConnector/ActivityJournal/activity-journal.json"),
            (CheckInHistoryFile.applicationSupportStore().fileURL, "/KatanaConnector/LocationCheckIn/check-ins.json"),
            (ReminderStoreFile.applicationSupportStore().fileURL, "/KatanaConnector/Reminders/reminders.json"),
            (ActionDraftStoreFile.applicationSupportStore().fileURL, "/KatanaConnector/ActionDrafts/action-drafts.json"),
            (NFCActionsFile.applicationSupportStore().fileURL, "/KatanaConnector/NFCActions/nfc-actions.json"),
            (GeofencesFile.applicationSupportStore().fileURL, "/KatanaConnector/Geofences/geofences.json"),
            (CaptureInboxStore.applicationSupport().directoryURL, "/KatanaConnector/CaptureInbox"),
        ]
        for (url, suffix) in expected {
            let path = url.standardizedFileURL.path
            XCTAssertTrue(path.hasSuffix("/Application Support" + suffix), path)
        }
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: app.katana.connector\n"), "main app Bundle ID unchanged")
        XCTAssertTrue(project.contains("MARKETING_VERSION: \"0.3.0\""))
    }

    func testInfoPlistEntitlementsAndExtensionPackaging() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        for forbidden in ["NSLocationAlwaysUsageDescription", "UIBackgroundModes", "CODE_SIGN_ENTITLEMENTS", "entitlements:",
                          "com.apple.security.application-groups", "nfc.readersession", "NFCReaderUsageDescription",
                          "aps-environment", "BGTaskScheduler"] {
            XCTAssertFalse(project.contains(forbidden), forbidden)
        }
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription:"))
        // The extension target exists but the app does not depend on it, so it is not embedded.
        XCTAssertTrue(project.contains("KatanaShareExtension:"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: app.katana.connector.share-extension"))
        let appTarget = try XCTUnwrap(project.components(separatedBy: "  KatanaShareExtension:").first)
        XCTAssertFalse(appTarget.contains("dependencies:"), "the main app embeds no extension in v0.3")
        XCTAssertTrue(appTarget.contains("\"ShareExtension/**\""), "extension sources are not compiled into the app")
        let workflow = try String(contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/build-ios.yml"))
        XCTAssertTrue(workflow.contains("-target KatanaShareExtension"))
        XCTAssertTrue(workflow.contains("test ! -d \"$APP/PlugIns\""))
        let fileManager = FileManager.default
        var entitlementFiles = ((try? fileManager.contentsOfDirectory(atPath: repositoryRoot.path)) ?? [])
            .filter { $0.hasSuffix(".entitlements") }
        for folder in ["Config", "Sources"] {
            let names = (fileManager.enumerator(atPath: repositoryRoot.appendingPathComponent(folder).path)?.allObjects as? [String]) ?? []
            entitlementFiles += names.filter { $0.hasSuffix(".entitlements") }
        }
        XCTAssertEqual(entitlementFiles, [], "no entitlement files in v0.3")
    }

    func testFrameworkBoundariesOfV03() throws {
        func text(_ path: String) throws -> String { try String(contentsOf: repositoryRoot.appendingPathComponent(path)) }
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let content = try String(contentsOf: url)
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            if content.contains("import CoreNFC") {
                XCTAssertTrue(relative.hasPrefix("Features/NFCActions/"), relative)
            }
            if content.contains("import ImageIO") || content.contains("import CryptoKit") {
                XCTAssertTrue(relative.hasPrefix("Core/Capture/"), relative)
            }
            if relative.hasPrefix("Core/") {
                for framework in ["CoreNFC", "CoreLocation", "UIKit", "SwiftUI", "PhotosUI", "UserNotifications"] {
                    XCTAssertFalse(content.contains("import \(framework)"), "\(relative) imports \(framework)")
                }
            }
            for logging in ["print(", "NSLog", "os_log", "Logger("] where relative.hasPrefix("Core/") || relative.hasPrefix("Features/")
                || relative.hasPrefix("ShareExtension/") {
                XCTAssertFalse(content.contains(logging), "\(relative) logs")
            }
        }
        let shareExtension = try text("Sources/ShareExtension/ShareViewController.swift")
        for forbidden in ["URLSession", "SecureTokenStoring", "KeychainTokenStore", "ConnectorAPI", "Authorization"] {
            XCTAssertFalse(shareExtension.contains(forbidden), "the extension never touches \(forbidden)")
        }
    }
}
