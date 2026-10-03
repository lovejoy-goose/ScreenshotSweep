import XCTest

final class EventDeliveryCoordinatorTests: XCTestCase {
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
    private func makeCoordinator(api: any ConnectorAPI, queue: EventQueue, sleeper: RecordingSleeper = RecordingSleeper(),
                                 policy: RetryPolicy = .default) -> EventDeliveryCoordinator {
        EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                 syncState: InMemorySyncStateStore(), retryPolicy: policy, sleeper: sleeper,
                                 random: { 0.5 }, now: { Fixtures.pairedAt })
    }

    private func filledQueue(_ count: Int) async throws -> EventQueue {
        let queue = EventQueue(store: store)
        for index in 1...count { try await queue.enqueue(EventFixtures.event(index), scope: EventFixtures.scope) }
        return queue
    }

    @MainActor
    func testDeliversAndRemovesAcceptedAndDuplicate() async throws {
        let queue = try await filledQueue(25)
        let api = MockConnectorAPI()
        api.batchHandler = { events in
            var results = MockConnectorAPI.results(events, .accepted)
            results[events[0].eventID] = EventDeliveryResult(eventID: events[0].eventID, status: .duplicate, code: nil)
            return results
        }
        let coordinator = makeCoordinator(api: api, queue: queue)
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(api.sentBatches.map(\.count), [20, 5])
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(coordinator.lastSuccessfulSync, Fixtures.pairedAt)
        XCTAssertEqual(coordinator.status, .idle)
    }

    @MainActor
    func testOnlyOneFlushAtATime() async throws {
        let queue = try await filledQueue(3)
        let api = MockConnectorAPI()
        api.batchHandler = { events in
            try await Task.sleep(nanoseconds: 50_000_000)
            return MockConnectorAPI.results(events, .accepted)
        }
        let coordinator = makeCoordinator(api: api, queue: queue)
        for _ in 0..<5 { coordinator.requestFlush() }
        XCTAssertTrue(coordinator.isFlushing)
        await coordinator.waitForFlush()

        XCTAssertEqual(api.maxInFlight, 1)
        XCTAssertEqual(api.batchCalls, 1)
        XCTAssertFalse(coordinator.isFlushing)
    }

    @MainActor
    func testRetryableErrorsKeepEventsAndUseInjectableBackoff() async throws {
        for error in [ConnectorAPIError.transport, .serverError(statusCode: 503), .rateLimited] {
            try? FileManager.default.removeItem(at: store.directoryURL)
            let queue = try await filledQueue(2)
            let api = MockConnectorAPI()
            api.batchHandler = { _ in throw error }
            let sleeper = RecordingSleeper()
            let coordinator = makeCoordinator(api: api, queue: queue, sleeper: sleeper,
                                              policy: RetryPolicy(baseDelay: 2, maxDelay: 60, jitterFraction: 0.2, maxAttemptsPerFlush: 4))
            coordinator.requestFlush()
            await coordinator.waitForFlush()

            XCTAssertEqual(api.batchCalls, 4, "\(error)")
            XCTAssertEqual(sleeper.delays, [2, 4, 8], "\(error)")
            let pending = try await queue.pendingCount()
            XCTAssertEqual(pending, 2, "\(error) must keep events")
            XCTAssertEqual(coordinator.lastSuccessfulSync, nil)
        }
    }

    @MainActor
    func testBackoffRecoversAfterTransientFailure() async throws {
        let queue = try await filledQueue(1)
        let api = MockConnectorAPI()
        let calls = Counter()
        api.batchHandler = { events in
            if calls.increment() <= 2 { throw ConnectorAPIError.serverError(statusCode: 500) }
            return MockConnectorAPI.results(events, .accepted)
        }
        let sleeper = RecordingSleeper()
        let coordinator = makeCoordinator(api: api, queue: queue, sleeper: sleeper)
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(sleeper.delays, [2, 4])
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testBackoffPolicyIsCappedWithJitter() {
        let policy = RetryPolicy(baseDelay: 2, maxDelay: 60, jitterFraction: 0.2, maxAttemptsPerFlush: 5)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0.5), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3, random: 0.5), 8)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0), 1.6, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0.999_999), 2.4, accuracy: 0.001)
        XCTAssertEqual(policy.delay(forAttempt: 20, random: 0.999_999), 60)
        XCTAssertLessThanOrEqual(policy.delay(forAttempt: 6, random: 0.999_999), 60)
    }

    @MainActor
    func testUnauthorizedRequiresRepairWithoutLosingQueue() async throws {
        let queue = try await filledQueue(3)
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.unauthorized }
        let sleeper = RecordingSleeper()
        let coordinator = makeCoordinator(api: api, queue: queue, sleeper: sleeper)
        var unauthorizedCalls = 0
        coordinator.onUnauthorized = { unauthorizedCalls += 1 }

        coordinator.requestFlush()
        await coordinator.waitForFlush()
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(coordinator.status, .requiresRepair)
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertEqual(sleeper.delays, [], "no network retries after 401")
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 3)
    }

    @MainActor
    func testUnauthorizedFlagsCredentialsAndStopsUsingThem() async throws {
        let queue = try await filledQueue(2)
        let tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        let client = URLSessionConnectorAPIClient(store: tokenStore,
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0")
        let pairing = PairingCoordinator(client: MockPairingClient(result: .success(Fixtures.response)), store: tokenStore)
        let coordinator = makeCoordinator(api: client, queue: queue)
        coordinator.onUnauthorized = { [weak pairing] in pairing?.markRequiresRepair() }
        MockURLProtocol.reply = .response(status: 401, body: Data("{}".utf8))

        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(pairing.status, .requiresRepair(Fixtures.credentials.device))
        XCTAssertEqual(tokenStore.credentials?.requiresRepair, true)
        XCTAssertEqual(tokenStore.deleteCount, 0)

        // The rejected token is never sent again, also by a fresh coordinator after "restart".
        let restarted = makeCoordinator(api: client, queue: queue)
        restarted.requestFlush()
        await restarted.waitForFlush()
        await restarted.checkConnection()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(restarted.lastCheck, .requiresRepair)
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 2)
    }

    @MainActor
    func testTimeoutKeepsQueue() async throws {
        let queue = try await filledQueue(2)
        let client = URLSessionConnectorAPIClient(store: InMemoryTokenStore(credentials: Fixtures.credentials),
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0")
        MockURLProtocol.reply = .failure(.timedOut)
        let coordinator = makeCoordinator(api: client, queue: queue,
                                          policy: RetryPolicy(baseDelay: 1, maxDelay: 60, jitterFraction: 0, maxAttemptsPerFlush: 2))
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertEqual(coordinator.status, .failed(.offline))
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 2)
    }

    @MainActor
    func testCancelledFlushKeepsEvents() async throws {
        let queue = try await filledQueue(2)
        let api = MockConnectorAPI()
        api.batchHandler = { events in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return MockConnectorAPI.results(events, .accepted)
        }
        let coordinator = makeCoordinator(api: api, queue: queue)
        coordinator.requestFlush()
        await waitUntil { api.batchCalls == 1 }
        coordinator.cancelFlush()
        await coordinator.waitForFlush()

        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 2)
        XCTAssertFalse(coordinator.isFlushing)
    }

    @MainActor
    func testRejectedBatchStopsWithoutRemovingEvents() async throws {
        let queue = try await filledQueue(2)
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.rejected(statusCode: 422) }
        let sleeper = RecordingSleeper()
        let coordinator = makeCoordinator(api: api, queue: queue, sleeper: sleeper)
        coordinator.requestFlush()
        await coordinator.waitForFlush()

        XCTAssertEqual(coordinator.status, .failed(.rejected))
        XCTAssertEqual(api.batchCalls, 1)
        XCTAssertEqual(sleeper.delays, [])
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 2)
    }

    @MainActor
    func testEnqueueTriggersFlushAndCapabilityReportOncePerLaunch() async throws {
        let queue = EventQueue(store: store)
        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: queue)
        await coordinator.prepare()

        try await coordinator.enqueue(EventFixtures.event(1))
        await coordinator.waitForFlush()
        XCTAssertEqual(api.batchCalls, 1)
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 0)

        coordinator.appBecameActive()
        await waitUntil { api.reportCalls == 1 }
        coordinator.appBecameActive()
        await coordinator.waitForFlush()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.reportCalls, 1, "automatic capability report runs once per launch")
    }

    @MainActor
    func testCheckConnectionResults() async {
        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: EventQueue(store: store))
        await coordinator.checkConnection()
        XCTAssertEqual(coordinator.lastCheck, .ok(serverTime: Fixtures.pairedAt, accountLabel: "Fixture"))

        api.checkHandler = { throw ConnectorAPIError.transport }
        await coordinator.checkConnection()
        XCTAssertEqual(coordinator.lastCheck, .failed(.offline))

        api.checkHandler = { throw ConnectorAPIError.notPaired }
        await coordinator.checkConnection()
        XCTAssertEqual(coordinator.lastCheck, .notPaired)
    }

    @MainActor
    func testCorruptedQueueIsReported() async throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL)
        let coordinator = makeCoordinator(api: MockConnectorAPI(), queue: EventQueue(store: store))
        await coordinator.prepare()
        XCTAssertEqual(coordinator.queueIssue, .corruptedStoreQuarantined)
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    @MainActor
    func testTokenAndPayloadNeverInDescriptions() async throws {
        let secretPayload = "payload-secret-value"
        let event = EventFixtures.event(1, payload: .object(["note": .string(secretPayload)]))
        let coordinator = makeCoordinator(api: MockConnectorAPI(), queue: EventQueue(store: store))
        let values: [Any] = [event, [event], EventBatchRequest(events: [event]), coordinator, coordinator.status,
                             ConnectorAPIError.unauthorized, EventQueueError.queueFull, Fixtures.credentials]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), dumped] {
                XCTAssertFalse(text.contains(secretPayload), "payload leaked in: \(text)")
                XCTAssertFalse(text.contains(Fixtures.token), "token leaked in: \(text)")
            }
        }
    }
}

/// Thread-safe call counter for async mock handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
