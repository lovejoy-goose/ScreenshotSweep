import XCTest

@MainActor
final class FakeCleanupSink: CleanupEventSink {
    var outcome: CleanupEnqueueOutcome = .saved
    private(set) var events: [ConnectorEvent] = []

    func enqueueCleanupEvent(_ event: ConnectorEvent) async -> CleanupEnqueueOutcome {
        events.append(event)
        return outcome
    }
}

final class CleanupSessionTests: XCTestCase {
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

    private let assetIDs = ["8A1B2C3D-0000-4000-8000-ASSET0000001/L0/001",
                            "8A1B2C3D-0000-4000-8000-ASSET0000002/L0/001",
                            "8A1B2C3D-0000-4000-8000-ASSET0000003/L0/001",
                            "8A1B2C3D-0000-4000-8000-ASSET0000004/L0/001"]

    /// keep, delete, delete (+ one undone decision).
    @MainActor
    private func recordTypicalSession(_ recorder: CleanupSessionRecorder) {
        recorder.recordDecision(.keep, assetID: assetIDs[0])
        recorder.recordDecision(.delete, assetID: assetIDs[1])
        recorder.recordDecision(.delete, assetID: assetIDs[2])
        recorder.recordDecision(.keep, assetID: assetIDs[3])
        recorder.undo(assetID: assetIDs[3])
    }

    @MainActor
    private func makeCoordinator(api: any ConnectorAPI, queue: EventQueue) -> EventDeliveryCoordinator {
        EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                 syncState: InMemorySyncStateStore(),
                                 retryPolicy: RetryPolicy(baseDelay: 1, maxDelay: 1, jitterFraction: 0, maxAttemptsPerFlush: 1),
                                 sleeper: RecordingSleeper(), random: { 0.5 }, now: { Fixtures.pairedAt })
    }

    private let summary = CleanupSessionSummary(sessionID: EventFixtures.sessionID,
                                                startedAt: Fixtures.pairedAt,
                                                completedAt: Fixtures.pairedAt.addingTimeInterval(90),
                                                reviewedCount: 3, keptCount: 1, deletionRequestedCount: 2,
                                                deletionCompleted: false)

    // 9
    func testSummaryRoundTrip() throws {
        let data = try ConnectorJSON.makeEncoder().encode(summary)
        XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(CleanupSessionSummary.self, from: data), summary)
        XCTAssertTrue(summary.isValid)
    }

    // 10
    func testExactWireFormat() throws {
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(summary), as: UTF8.self)
        XCTAssertEqual(json, #"{"completed_at":"2026-09-21T14:14:50Z","deletion_completed":false,"deletion_requested_count":2,"#
            + #""kept_count":1,"reviewed_count":3,"session_id":"11111111-2222-3333-4444-555555555555","started_at":"2026-09-21T14:13:20Z"}"#)

        let event = try summary.makeEvent(eventID: EventFixtures.event(5).eventID)
        let eventJSON = String(decoding: try ConnectorJSON.makeEncoder().encode(event), as: UTF8.self)
        XCTAssertEqual(eventJSON, #"{"event_id":"00000000-0000-4000-8000-000000000005","occurred_at":"2026-09-21T14:14:50Z","#
            + #""payload":{"completed_at":"2026-09-21T14:14:50Z","deletion_completed":false,"deletion_requested_count":2,"#
            + #""kept_count":1,"reviewed_count":3,"session_id":"11111111-2222-3333-4444-555555555555","started_at":"2026-09-21T14:13:20Z"},"#
            + #""session_id":"11111111-2222-3333-4444-555555555555","type":"screenshot_cleanup.completed"}"#)
        XCTAssertTrue(event.hasValidType)
    }

    func testInvariants() {
        func make(_ reviewed: Int, _ kept: Int, _ requested: Int, _ completed: Bool, end: TimeInterval = 10) -> CleanupSessionSummary {
            CleanupSessionSummary(sessionID: UUID(), startedAt: Fixtures.pairedAt, completedAt: Fixtures.pairedAt.addingTimeInterval(end),
                                  reviewedCount: reviewed, keptCount: kept, deletionRequestedCount: requested, deletionCompleted: completed)
        }
        XCTAssertTrue(make(3, 1, 2, true).isValid)
        XCTAssertTrue(make(2, 2, 0, true).isValid)
        XCTAssertFalse(make(0, 0, 0, true).isValid, "empty sessions are not sent")
        XCTAssertFalse(make(3, 1, 1, true).isValid, "reviewed must equal kept + requested")
        XCTAssertFalse(make(2, 2, 0, false).isValid, "nothing requested means nothing pending")
        XCTAssertFalse(make(1, -1, 2, true).isValid)
        XCTAssertFalse(make(1, 1, 0, true, end: -5).isValid, "completed before started")
    }

    func testTrackerCountsDeletionsAndSurvivesEarlyLibraryChange() {
        var tracker = CleanupSessionTracker()
        tracker.record(.keep, assetID: "a", at: Fixtures.pairedAt)
        tracker.record(.delete, assetID: "b", at: Fixtures.pairedAt)
        tracker.record(.delete, assetID: "c", at: Fixtures.pairedAt)
        tracker.change(assetID: "c", to: .keep)
        tracker.change(assetID: "unknown", to: .delete)
        tracker.record(.delete, assetID: "d", at: Fixtures.pairedAt)

        // PhotoKit may report the change before the deletion request completes.
        tracker.beginDeletion(assetIDs: ["b", "d"])
        tracker.retainOnly(existing: ["a", "c"])
        tracker.finishDeletion(assetIDs: ["b", "d"], success: true)

        var summary = tracker.summary(completedAt: Fixtures.pairedAt)
        XCTAssertEqual(summary?.reviewedCount, 4)
        XCTAssertEqual(summary?.keptCount, 2)
        XCTAssertEqual(summary?.deletionRequestedCount, 2)
        XCTAssertEqual(summary?.deletionCompleted, true)

        // A cancelled system dialog leaves the screenshots marked, not deleted.
        tracker.record(.delete, assetID: "e", at: Fixtures.pairedAt)
        tracker.beginDeletion(assetIDs: ["e"])
        tracker.finishDeletion(assetIDs: ["e"], success: false)
        summary = tracker.summary(completedAt: Fixtures.pairedAt)
        XCTAssertEqual(summary?.deletionRequestedCount, 3)
        XCTAssertEqual(summary?.deletionCompleted, false)
        XCTAssertEqual(tracker.deletedCount, 2)

        XCTAssertNil(CleanupSessionTracker().summary(completedAt: Fixtures.pairedAt))
        XCTAssertFalse(String(describing: tracker).contains("\"b\""))
    }

    // 11
    @MainActor
    func testCompletionCreatesExactlyOneEvent() async throws {
        let sink = FakeCleanupSink()
        let recorder = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)

        let completion = await recorder.complete()
        let second = await recorder.complete()

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNil(second, "the session is closed after completion")
        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.type, "screenshot_cleanup.completed")
        XCTAssertEqual(completion?.outcome, .saved)
        XCTAssertEqual(completion?.eventID, event.eventID)
        XCTAssertEqual(completion?.summary.reviewedCount, 3)
        XCTAssertEqual(completion?.summary.keptCount, 1)
        XCTAssertEqual(completion?.summary.deletionRequestedCount, 2)
        XCTAssertEqual(completion?.summary.deletionCompleted, false)
        XCTAssertEqual(event.sessionID, completion?.summary.sessionID)
        XCTAssertFalse(recorder.tracker.hasActivity)
    }

    // 12
    @MainActor
    func testReopeningSummaryDoesNotDuplicate() async {
        let sink = FakeCleanupSink()
        let recorder = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)

        XCTAssertNotNil(recorder.previewSummary())
        XCTAssertNotNil(recorder.previewSummary())
        XCTAssertEqual(sink.events.count, 0, "previews create nothing")

        await recorder.complete()
        XCTAssertNil(recorder.previewSummary())
        await recorder.complete()
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(recorder.lastCompletion?.outcome, .saved)
    }

    // 13
    @MainActor
    func testCancelDoesNotCreateEvent() {
        let sink = FakeCleanupSink()
        let recorder = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)
        _ = recorder.previewSummary() // summary opened, then «Продолжить разбор»

        XCTAssertEqual(sink.events.count, 0)
        XCTAssertNil(recorder.lastCompletion)
        XCTAssertTrue(recorder.tracker.hasActivity, "the session continues")

        let empty = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        XCTAssertFalse(empty.canComplete)
    }

    // 14
    @MainActor
    func testOfflineKeepsEventInPersistentQueue() async throws {
        let queue = EventQueue(store: store)
        let client = URLSessionConnectorAPIClient(store: InMemoryTokenStore(credentials: Fixtures.credentials),
                                                  transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                                  appVersion: "0.1.0", systemVersion: "18.0")
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        let coordinator = makeCoordinator(api: client, queue: queue)
        let recorder = CleanupSessionRecorder(sink: coordinator, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)

        let completion = await recorder.complete()
        await coordinator.waitForFlush()

        XCTAssertEqual(completion?.outcome, .saved)
        XCTAssertEqual(coordinator.status, .failed(.offline))
        let reopened = EventQueue(store: EventQueueStore(directoryURL: store.directoryURL))
        let pending = try await reopened.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(pending.map(\.eventID), [completion?.eventID].compactMap { $0 })
        XCTAssertEqual(pending.first?.type, "screenshot_cleanup.completed")
    }

    // 15
    @MainActor
    func testQueueFailureLeavesLibraryStateUntouched() async {
        let queue = EventQueue(store: store, limits: EventQueueLimits(maxBatchSize: 20, maxEvents: 0, maxEventBytes: 16 * 1024, maxRejectedRecords: 100))
        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: queue)
        let recorder = CleanupSessionRecorder(sink: coordinator, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)
        let before = recorder.tracker

        let completion = await recorder.complete()

        XCTAssertEqual(completion?.outcome, .failed)
        XCTAssertNil(completion?.eventID)
        XCTAssertEqual(api.batchCalls, 0)
        // Completion only reads counters: nothing was marked deleted and the pending
        // deletion requests are reported as still pending. The recorder has no
        // photo-library access at all (Core cannot import Photos, D-024).
        XCTAssertEqual(before.deletedCount, 0)
        XCTAssertEqual(before.pendingDeletionCount, 2)
        XCTAssertEqual(completion?.summary.deletionCompleted, false)
    }

    // 16
    @MainActor
    func testPayloadContainsNoPhotoData() async throws {
        let sink = FakeCleanupSink()
        let recorder = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)
        await recorder.complete()

        let event = try XCTUnwrap(sink.events.first)
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(event), as: UTF8.self)
        for id in assetIDs {
            XCTAssertFalse(json.contains(id))
            XCTAssertFalse(json.contains(String(id.prefix(36))))
        }
        XCTAssertFalse(json.contains("ASSET"))
        guard case .object(let payload) = event.payload else { return XCTFail("payload must be an object") }
        XCTAssertEqual(payload.keys.sorted(), ["completed_at", "deletion_completed", "deletion_requested_count",
                                               "kept_count", "reviewed_count", "session_id", "started_at"])
    }

    // 17, 18
    @MainActor
    func testSuccessfulFlushRemovesOnlyCurrentScopeEvent() async throws {
        let queue = EventQueue(store: store)
        try await queue.enqueue(EventFixtures.event(1), scope: EventFixtures.otherDeviceScope)
        let api = MockConnectorAPI()
        let coordinator = makeCoordinator(api: api, queue: queue)
        let recorder = CleanupSessionRecorder(sink: coordinator, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)

        let completion = await recorder.complete()
        await coordinator.waitForFlush()

        let eventID = try XCTUnwrap(completion?.eventID)
        XCTAssertTrue(coordinator.deliveredEventIDs.contains(eventID))
        XCTAssertEqual(api.sentBatches.flatMap { $0 }.map(\.eventID), [eventID])
        let current = try await queue.pendingCount(scope: EventFixtures.scope)
        XCTAssertEqual(current, 0)
        let other = try await queue.pendingEvents(scope: EventFixtures.otherDeviceScope)
        XCTAssertEqual(other, [EventFixtures.event(1)], "another connection's event is untouched")
    }

    @MainActor
    func testNotPairedRecordsNothing() async throws {
        let queue = EventQueue(store: store)
        let api = MockConnectorAPI()
        api.scope = nil
        let coordinator = makeCoordinator(api: api, queue: queue)
        let recorder = CleanupSessionRecorder(sink: coordinator, now: { Fixtures.pairedAt })
        recordTypicalSession(recorder)

        let completion = await recorder.complete()
        XCTAssertEqual(completion?.outcome, .notPaired)
        let count = try await queue.pendingCount()
        XCTAssertEqual(count, 0)
    }
}
