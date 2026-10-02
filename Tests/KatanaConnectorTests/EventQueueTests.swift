import XCTest

final class EventQueueTests: XCTestCase {
    private var store: EventQueueStore!

    override func setUp() {
        super.setUp()
        store = EventFixtures.makeTemporaryStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.directoryURL)
        super.tearDown()
    }

    private func result(_ event: ConnectorEvent, _ status: EventDeliveryStatus, code: String? = nil) -> (UUID, EventDeliveryResult) {
        (event.eventID, EventDeliveryResult(eventID: event.eventID, status: status, code: code))
    }

    func testEnqueueSurvivesNewInstance() async throws {
        let first = EventQueue(store: store)
        try await first.enqueue(EventFixtures.event(1))
        try await first.enqueue(EventFixtures.event(2))

        let reopened = EventQueue(store: EventQueueStore(directoryURL: store.directoryURL))
        let events = try await reopened.pendingEvents()
        XCTAssertEqual(events, [EventFixtures.event(1), EventFixtures.event(2)])
    }

    func testFIFOOrder() async throws {
        let queue = EventQueue(store: store)
        for index in [3, 1, 2] { try await queue.enqueue(EventFixtures.event(index)) }
        let batch = try await queue.nextBatch()
        XCTAssertEqual(batch.map(\.eventID), [3, 1, 2].map { EventFixtures.event($0).eventID })
    }

    func testSameEventIDIsNotDuplicated() async throws {
        let queue = EventQueue(store: store)
        let first = try await queue.enqueue(EventFixtures.event(1))
        let again = try await queue.enqueue(EventFixtures.event(1, payload: .string("different")))
        XCTAssertEqual(first, .enqueued)
        XCTAssertEqual(again, .alreadyQueued)
        let events = try await queue.pendingEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload, .object(["n": .int(1)]), "the original payload is kept for retries")
    }

    func testBatchIsLimitedTo20() async throws {
        let queue = EventQueue(store: store)
        for index in 1...25 { try await queue.enqueue(EventFixtures.event(index)) }
        let batch = try await queue.nextBatch()
        XCTAssertEqual(batch.count, 20)
        XCTAssertEqual(batch.first?.eventID, EventFixtures.event(1).eventID)
        let largerRequested = try await queue.nextBatch(limit: 50)
        XCTAssertEqual(largerRequested.count, 20)
        XCTAssertEqual(EventQueueLimits.default.maxBatchSize, 20)
    }

    func testAcceptedDuplicateAndRejectedHandling() async throws {
        let queue = EventQueue(store: store)
        let events = (1...4).map { EventFixtures.event($0, payload: .string("payload-\($0)")) }
        for event in events { try await queue.enqueue(event) }

        // Event 4 has no result and must stay.
        let removed = try await queue.apply(Dictionary(uniqueKeysWithValues: [
            result(events[0], .accepted),
            result(events[1], .duplicate),
            result(events[2], .rejected, code: String(repeating: "x", count: 200)),
        ]), at: Fixtures.pairedAt)

        XCTAssertEqual(removed, 3)
        let remaining = try await queue.pendingEvents()
        XCTAssertEqual(remaining, [events[3]])

        // Rejected policy: removed from the active queue, metadata kept without payload.
        let rejected = try await queue.rejectedRecords()
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.eventID, events[2].eventID)
        XCTAssertEqual(rejected.first?.type, "test.neutral_event")
        XCTAssertEqual(rejected.first?.code?.count, RejectedEventRecord.maxCodeLength)

        let fileText = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        XCTAssertFalse(fileText.contains("payload-3"), "rejected payload is not kept")
        XCTAssertTrue(fileText.contains("payload-4"))

        // Survives restart.
        let reopened = EventQueue(store: EventQueueStore(directoryURL: store.directoryURL))
        let reopenedRemaining = try await reopened.pendingEvents()
        let reopenedRejected = try await reopened.rejectedRecords()
        XCTAssertEqual(reopenedRemaining, [events[3]])
        XCTAssertEqual(reopenedRejected.count, 1)
    }

    func testRejectedRecordsAreCapped() async throws {
        let queue = EventQueue(store: store, limits: EventQueueLimits(maxBatchSize: 20, maxEvents: 500, maxEventBytes: 16 * 1024, maxRejectedRecords: 2))
        let events = (1...3).map { EventFixtures.event($0) }
        for event in events { try await queue.enqueue(event) }
        try await queue.apply(MockConnectorAPI.results(events, .rejected), at: Fixtures.pairedAt)
        let rejected = try await queue.rejectedRecords()
        XCTAssertEqual(rejected.count, 2)
    }

    func testCorruptedFileIsQuarantinedNotLost() async throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: store.fileURL)

        let queue = EventQueue(store: store)
        var quarantinedName: String?
        do {
            try await queue.open()
            XCTFail("Expected corruptedStore")
        } catch EventQueueError.corruptedStore(let name) {
            quarantinedName = name
        }

        let name = try XCTUnwrap(quarantinedName)
        XCTAssertEqual(try Data(contentsOf: store.directoryURL.appendingPathComponent(name)), garbage,
                       "the original bytes are preserved for diagnostics")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        // The queue keeps working afterwards.
        try await queue.enqueue(EventFixtures.event(1))
        let count = try await queue.pendingCount()
        XCTAssertEqual(count, 1)
    }

    func testFileIsExcludedFromBackupAndProtected() async throws {
        let queue = EventQueue(store: store)
        try await queue.enqueue(EventFixtures.event(1))

        let directoryValues = try store.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
        let fileValues = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)

        // The simulator may not report data protection; check it when it does.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }

        let fileText = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        XCTAssertFalse(fileText.contains(Fixtures.token))
    }

    func testLimits() async throws {
        XCTAssertEqual(EventQueueLimits.default, EventQueueLimits(maxBatchSize: 20, maxEvents: 500, maxEventBytes: 16 * 1024, maxRejectedRecords: 100))

        let small = EventQueue(store: store, limits: EventQueueLimits(maxBatchSize: 20, maxEvents: 2, maxEventBytes: 1024, maxRejectedRecords: 100))
        try await small.enqueue(EventFixtures.event(1))
        try await small.enqueue(EventFixtures.event(2))
        do {
            try await small.enqueue(EventFixtures.event(3))
            XCTFail("Expected queueFull")
        } catch EventQueueError.queueFull {}

        let other = EventQueue(store: EventFixtures.makeTemporaryStore(),
                               limits: EventQueueLimits(maxBatchSize: 20, maxEvents: 10, maxEventBytes: 1024, maxRejectedRecords: 100))
        do {
            try await other.enqueue(EventFixtures.event(4, payload: .string(String(repeating: "a", count: 2000))))
            XCTFail("Expected eventTooLarge")
        } catch EventQueueError.eventTooLarge {}

        let invalidType = ConnectorEvent(type: "Bad Type!", occurredAt: Fixtures.pairedAt, sessionID: EventFixtures.sessionID, payload: .null)
        do {
            try await other.enqueue(invalidType)
            XCTFail("Expected invalidEvent")
        } catch EventQueueError.invalidEvent {}

        let remaining = try await small.pendingCount()
        XCTAssertEqual(remaining, 2, "a full queue never drops existing events")
    }

    func testEventWireFormat() throws {
        let event = EventFixtures.event(7, payload: .object(["viewed": .int(3), "ok": .bool(true), "note": .null]))
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(event), as: UTF8.self)
        XCTAssertEqual(json, #"{"event_id":"00000000-0000-4000-8000-000000000007","occurred_at":"2026-09-21T14:13:20Z","payload":{"note":null,"ok":true,"viewed":3},"session_id":"11111111-2222-3333-4444-555555555555","type":"test.neutral_event"}"#)
        XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(ConnectorEvent.self, from: Data(json.utf8)), event)
    }
}
