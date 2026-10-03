import CryptoKit
import XCTest

final class ConnectionScopeTests: XCTestCase {
    private var store: EventQueueStore!

    override func setUp() {
        super.setUp()
        store = EventFixtures.makeTemporaryStore()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directoryURL)
        super.tearDown()
    }

    @MainActor
    private func makeCoordinator(api: any ConnectorAPI, queue: EventQueue) -> EventDeliveryCoordinator {
        EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                 syncState: InMemorySyncStateStore(),
                                 retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0, maxAttemptsPerFlush: 1),
                                 sleeper: RecordingSleeper(), random: { 0.5 }, now: { Fixtures.pairedAt })
    }

    private func acceptedJSON(_ events: [ConnectorEvent]) -> Data {
        let results = events.map { #"{"event_id":"\#($0.eventID.uuidString.lowercased())","status":"accepted"}"# }
        return Data(#"{"results":[\#(results.joined(separator: ","))]}"#.utf8)
    }

    func testCanonicalScope() {
        let variants = ["https://katana.example", "https://KATANA.example/", "HTTPS://katana.example:443//"]
        for text in variants {
            XCTAssertEqual(ConnectionScope(baseURL: URL(string: text)!, deviceID: "dev_fixture"), EventFixtures.scope, text)
        }
        XCTAssertEqual(ConnectionScope(baseURL: URL(string: "https://katana.example:8443/app/")!, deviceID: "d").baseURL,
                       "https://katana.example:8443/app")
        XCTAssertEqual(ConnectionScope(device: Fixtures.credentials.device), EventFixtures.scope)
        XCTAssertNotEqual(EventFixtures.scope, EventFixtures.otherDeviceScope)
        XCTAssertNotEqual(EventFixtures.scope, EventFixtures.otherHostScope)
    }

    // 1
    @MainActor
    func testEventGetsScopeOfCurrentConnection() async throws {
        let queue = EventQueue(store: store)
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let coordinator = makeCoordinator(api: api, queue: queue)

        try await coordinator.enqueue(EventFixtures.event(1))
        await coordinator.waitForFlush()

        let entries = try await queue.pendingEntries()
        XCTAssertEqual(entries.map(\.scope), [EventFixtures.scope])

        api.scope = nil
        do {
            try await coordinator.enqueue(EventFixtures.event(2))
            XCTFail("Expected notPaired")
        } catch ConnectorAPIError.notPaired {}
        let count = try await queue.pendingCount()
        XCTAssertEqual(count, 1, "without a connection nothing is recorded")
    }

    // 2, 18
    @MainActor
    func testFlushSendsOnlyCurrentScope() async throws {
        let queue = EventQueue(store: store)
        try await queue.enqueue(EventFixtures.event(1), scope: EventFixtures.otherDeviceScope)
        try await queue.enqueue(EventFixtures.event(2), scope: EventFixtures.scope)
        try await queue.enqueue(EventFixtures.event(3), scope: EventFixtures.otherHostScope)
        try await queue.enqueue(EventFixtures.event(4), scope: EventFixtures.scope)

        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: queue)
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(api.sentBatches.flatMap { $0 }.map(\.eventID), [2, 4].map { EventFixtures.event($0).eventID })
        XCTAssertEqual(Set(api.sentScopes), [EventFixtures.scope])
        let remaining = try await queue.pendingEntries()
        XCTAssertEqual(remaining.map(\.event.eventID), [1, 3].map { EventFixtures.event($0).eventID })
        XCTAssertEqual(remaining.map(\.scope), [EventFixtures.otherDeviceScope, EventFixtures.otherHostScope])
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(coordinator.otherScopePendingCount, 2)
    }

    // 3, 4
    @MainActor
    func testOtherDeviceOrHostNeverGetsOldEvents() async throws {
        for newScope in [EventFixtures.otherDeviceScope, EventFixtures.otherHostScope] {
            try? FileManager.default.removeItem(at: store.directoryURL)
            let queue = EventQueue(store: store)
            try await queue.enqueue(EventFixtures.event(1), scope: EventFixtures.scope)
            try await queue.enqueue(EventFixtures.event(2), scope: EventFixtures.scope)

            let api = MockConnectorAPI()
            api.scope = newScope
            let coordinator = makeCoordinator(api: api, queue: queue)
            await coordinator.prepare()
            coordinator.requestFlush()
            await coordinator.waitForFlush()

            XCTAssertEqual(api.batchCalls, 0, "\(newScope)")
            let kept = try await queue.pendingEvents(scope: EventFixtures.scope)
            XCTAssertEqual(kept.count, 2, "old events stay locally")
            XCTAssertEqual(coordinator.pendingCount, 0)
            XCTAssertEqual(coordinator.otherScopePendingCount, 2)
        }
    }

    @MainActor
    func testClientRefusesScopeMismatchWithoutNetwork() async throws {
        let client = URLSessionConnectorAPIClient(store: InMemoryTokenStore(credentials: Fixtures.credentials),
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0")
        XCTAssertEqual(client.currentScope(), EventFixtures.scope)
        do {
            _ = try await client.sendEventBatch([EventFixtures.event(1)], scope: EventFixtures.otherDeviceScope)
            XCTFail("Expected scopeMismatch")
        } catch ConnectorAPIError.scopeMismatch {}
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // 5
    @MainActor
    func testRepairingSameScopeKeepsQueue() async throws {
        let queue = EventQueue(store: store)
        let events = [EventFixtures.event(1), EventFixtures.event(2)]
        for event in events { try await queue.enqueue(event, scope: EventFixtures.scope) }

        var flagged = Fixtures.credentials
        flagged.requiresRepair = true
        let tokenStore = InMemoryTokenStore(credentials: flagged)
        let client = URLSessionConnectorAPIClient(store: tokenStore,
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0")
        let coordinator = makeCoordinator(api: client, queue: queue)
        coordinator.requestFlush()
        await coordinator.waitForFlush()
        XCTAssertEqual(coordinator.status, .requiresRepair)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // New pairing: new token, same base_url (written differently) and device_id.
        tokenStore.credentials = PairingCredentials(
            token: DeviceToken("tok_new_fixture"),
            device: PairedDevice(deviceID: "dev_fixture", displayName: "iPhone", pairedAt: Fixtures.pairedAt,
                                 baseURL: URL(string: "https://Katana.example/")!))
        MockURLProtocol.reply = .response(status: 200, body: acceptedJSON(events))
        coordinator.pairingDidConnect()
        await coordinator.waitForFlush()

        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok_new_fixture")
        let remaining = try await queue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    // 6
    @MainActor
    func testLegacyEventsAreNeverAssignedToConnection() async throws {
        let legacyEvents = [EventFixtures.event(1), EventFixtures.event(2)]
        try writeV1File(events: legacyEvents)

        let queue = EventQueue(store: store)
        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: queue)
        await coordinator.prepare()
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(api.batchCalls, 0)
        let batch = try await queue.nextBatch(scope: EventFixtures.scope)
        XCTAssertEqual(batch, [])
        let legacy = try await queue.legacyEvents()
        XCTAssertEqual(legacy, legacyEvents)
        XCTAssertEqual(coordinator.otherScopePendingCount, 2)

        // Re-enqueueing a legacy event_id does not move it into a connection.
        let result = try await queue.enqueue(legacyEvents[0], scope: EventFixtures.scope)
        XCTAssertEqual(result, .alreadyQueued)
        let scoped = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(scoped, [])
    }

    // 7
    func testMigrationKeepsOriginalEvents() async throws {
        let legacyEvents = [EventFixtures.event(1, payload: .string("first")), EventFixtures.event(2)]
        let rejected = RejectedEventRecord(eventID: EventFixtures.event(9).eventID, type: "test.neutral_event",
                                           code: "bad", rejectedAt: Fixtures.pairedAt)
        let original = try writeV1File(events: legacyEvents, rejected: [rejected])

        let queue = EventQueue(store: store)
        try await queue.open()
        let migratedLegacy = try await queue.legacyEvents()
        let migratedRejected = try await queue.rejectedRecords()
        XCTAssertEqual(migratedLegacy, legacyEvents)
        XCTAssertEqual(migratedRejected, [rejected])

        let backup = try Data(contentsOf: store.directoryURL.appendingPathComponent(EventQueueStore.v1BackupFileName))
        XCTAssertEqual(backup, original, "the original v1 file is kept byte for byte")

        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(rewritten?["version"] as? Int, 2)

        let reopened = EventQueue(store: EventQueueStore(directoryURL: store.directoryURL))
        let reopenedLegacy = try await reopened.legacyEvents()
        XCTAssertEqual(reopenedLegacy, legacyEvents)
    }

    // 8
    func testScopeContainsNoTokenOrDerivative() throws {
        let token = Fixtures.token
        let derived = [
            token,
            SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(),
            Data(token.utf8).base64EncodedString(),
        ]
        let scope = ConnectionScope(device: Fixtures.credentials.device)
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(scope), as: UTF8.self)
        XCTAssertEqual(json, #"{"base_url":"https:\/\/katana.example","device_id":"dev_fixture"}"#)

        var dumped = ""
        dump(scope, to: &dumped)
        for text in [json, String(describing: scope), dumped] {
            for secret in derived {
                XCTAssertFalse(text.contains(secret))
            }
        }
        XCTAssertEqual(Mirror(reflecting: scope).children.compactMap(\.label).sorted(), ["baseURL", "deviceID"])
    }

    @discardableResult
    private func writeV1File(events: [ConnectorEvent], rejected: [RejectedEventRecord] = []) throws -> Data {
        struct V1: Encodable {
            let version = 1
            let events: [ConnectorEvent]
            let rejected: [RejectedEventRecord]
        }
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let data = try ConnectorJSON.makeEncoder().encode(V1(events: events, rejected: rejected))
        try data.write(to: store.fileURL)
        return data
    }
}
