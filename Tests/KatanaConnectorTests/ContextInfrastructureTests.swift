import XCTest

/// V2-002: shared storage, event schema, event sink and URL v2.
final class ContextInfrastructureTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("ContextStore")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private struct SampleFile: VersionedFileFormat {
        static let currentVersion = 2
        static var empty: SampleFile { SampleFile() }
        var version = SampleFile.currentVersion
        var items: [String] = []
    }

    private struct SampleFileV1: Decodable {
        let version: Int
        let names: [String]
    }

    private func makeStore(migrations: [Int: VersionedJSONFileStore<SampleFile>.Migration] = [:]) -> VersionedJSONFileStore<SampleFile> {
        VersionedJSONFileStore(directoryURL: directory, fileName: "sample.json", migrations: migrations)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent("sample.json"))
    }

    // MARK: VersionedJSONFileStore

    func testMissingFileIsEmptyAndRoundTripSurvivesNewInstance() throws {
        XCTAssertEqual(try makeStore().load(), SampleFile())
        try makeStore().save(SampleFile(items: ["a", "b"]))
        XCTAssertEqual(try makeStore().load().items, ["a", "b"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "sample.json" }
        XCTAssertEqual(leftovers, [], "atomic write leaves no temporary files")
    }

    func testCorruptAndUnknownVersionAreQuarantinedNotDeleted() throws {
        for content in ["{broken", #"{"version":3,"items":[]}"#, #"{"items":[]}"#, #"{"version":2,"items":"x"}"#] {
            try write(content)
            XCTAssertThrowsError(try makeStore().load(), content) { error in
                guard case VersionedFileStoreError.quarantined(let name)? = error as? VersionedFileStoreError else {
                    return XCTFail("expected quarantine, got \(error)")
                }
                XCTAssertTrue(name.hasPrefix("sample.corrupt-"), name)
                let moved = try? Data(contentsOf: self.directory.appendingPathComponent(name))
                XCTAssertEqual(moved.map { String(decoding: $0, as: UTF8.self) }, content, "original bytes kept")
            }
            XCTAssertEqual(try makeStore().load(), SampleFile(), "continues empty afterwards")
        }
    }

    func testRegisteredMigrationUpgradesOlderVersion() throws {
        try write(#"{"version":1,"names":["x"]}"#)
        let store = makeStore(migrations: [1: { data in
            let old = try JSONDecoder().decode(SampleFileV1.self, from: data)
            return SampleFile(items: old.names)
        }])
        XCTAssertEqual(try store.load().items, ["x"])
        XCTAssertEqual(try makeStore().load().items, ["x"], "migrated file is saved in the current version")
    }

    func testFileProtectionAndBackupExclusion() throws {
        try makeStore().save(SampleFile(items: ["a"]))
        let url = directory.appendingPathComponent("sample.json")
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }

    func testV02StorageIdentifiers() {
        XCTAssertEqual(ActivityJournalFile.fileName, "activity-journal.json")
        XCTAssertEqual(ActivityJournalFile.directoryName, "ActivityJournal")
        XCTAssertEqual(ActivityJournalFile.currentVersion, 1)
        let path = ActivityJournalFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/ActivityJournal/activity-journal.json"), path)
    }

    func testWholeSecondsTruncates() {
        XCTAssertEqual(WholeSeconds.floor(Date(timeIntervalSince1970: 10.999)), Date(timeIntervalSince1970: 10))
    }

    // MARK: ContextEventSchema

    private struct LooseSnapshotPayload: Encodable {
        let activity = "walking"
        let confidence = "high"
        let checked_at = "2026-10-04T10:00:00Z"
        let source = "motion_activity"
        let interrupted = false
    }

    func testSchemaRequiresExactKeys() throws {
        XCTAssertNoThrow(try ContextEventSchema.makeEvent(.activitySnapshot, eventID: UUID(), occurredAt: Fixtures.pairedAt,
                                                          sessionID: UUID(), payload: LooseSnapshotPayload()))
        let base: [String: JSONValue] = ["activity": .string("walking"), "confidence": .string("high"),
                                         "checked_at": .string("2026-10-04T10:00:00Z"), "source": .string("motion_activity"),
                                         "interrupted": .bool(false)]
        var extra = base
        extra["latitude"] = .double(55.75)
        var missing = base
        missing["source"] = nil
        var nested = base
        nested["source"] = .object(["raw": .string("x")])
        for payload in [extra, missing, nested] {
            let event = ConnectorEvent(type: ContextEventType.activitySnapshot.rawValue, occurredAt: Fixtures.pairedAt,
                                       sessionID: UUID(), payload: .object(payload))
            XCTAssertThrowsError(try ContextEventSchema.validate(event))
        }
        let unknownType = ConnectorEvent(type: "activity.raw_samples", occurredAt: Fixtures.pairedAt, sessionID: UUID(),
                                         payload: .object(base))
        XCTAssertThrowsError(try ContextEventSchema.validate(unknownType))
        XCTAssertThrowsError(try ContextEventSchema.validate(EventFixtures.event(1)), "v0.1 test events are not v0.2 types")
    }

    func testEventTypesAndKeyCountsAreStable() {
        XCTAssertEqual(ContextEventType.version02.map(\.rawValue), [
            "activity.snapshot.completed", "activity.session.completed", "location.check_in.created",
            "reminder.local.scheduled", "reminder.local.cancelled",
        ])
        XCTAssertEqual(ContextEventType.version02.map(\.payloadKeys.count), [5, 12, 7, 5, 3])
        XCTAssertEqual(ContextEventType.allCases, ContextEventType.version02 + ContextEventType.version03,
                       "v0.2 wire values unchanged; v0.3 only adds")
        for type in ContextEventType.allCases {
            XCTAssertTrue(ConnectorEvent(type: type.rawValue, occurredAt: Date(), sessionID: UUID(), payload: .null).hasValidType)
            for forbidden in ["title", "body", "token", "device_token", "code", "base_url", "device_id", "altitude", "speed",
                              "course", "floor", "horizontal_accuracy", "samples"] {
                XCTAssertFalse(type.payloadKeys.contains(forbidden), "\(type.rawValue) allows \(forbidden)")
            }
        }
    }

    // MARK: ConnectorEventSink on the delivery coordinator

    @MainActor
    func testSinkSavesReportsStatesAndUnauthorized() async throws {
        let api = MockConnectorAPI()
        let (_, delivery) = ContextFixtures.delivery(queueDirectory: directory, api: api)
        var unauthorizedCalls = 0
        delivery.onUnauthorized = { unauthorizedCalls += 1 }

        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let pendingEvent = EventFixtures.event(1)
        let saved = await delivery.enqueueEvent(pendingEvent)
        XCTAssertEqual(saved, .saved)
        await delivery.waitForFlush()
        let pendingState = await delivery.localDeliveryState(of: pendingEvent.eventID)
        XCTAssertEqual(pendingState, .pending)

        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        delivery.requestFlush()
        await delivery.waitForFlush()
        let deliveredState = await delivery.localDeliveryState(of: pendingEvent.eventID)
        XCTAssertEqual(deliveredState, .delivered)

        api.batchHandler = { events in MockConnectorAPI.results(events, .rejected) }
        let rejectedEvent = EventFixtures.event(2)
        _ = await delivery.enqueueEvent(rejectedEvent)
        await delivery.waitForFlush()
        let rejectedState = await delivery.localDeliveryState(of: rejectedEvent.eventID)
        XCTAssertEqual(rejectedState, .rejected)

        api.scope = nil
        let notPaired = await delivery.enqueueEvent(EventFixtures.event(3))
        XCTAssertEqual(notPaired, .notPaired, "no connection → nothing is recorded")

        delivery.reportUnauthorized()
        delivery.reportUnauthorized()
        XCTAssertEqual(delivery.status, .requiresRepair)
        XCTAssertEqual(unauthorizedCalls, 1, "pairing is told once")
    }

    // MARK: URL v2 (V2-003 part: activity_journal)

    private func assertRejects(_ text: String, _ expected: ConnectorURLError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ConnectorURLRouter.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? ConnectorURLError, expected, text, file: file, line: line)
        }
    }

    @MainActor
    func testActivityJournalLinkOnlyNavigates() throws {
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=2&feature=activity_journal"),
                       .openDestination(.activityJournal))
        XCTAssertEqual(ConnectorURLRouter.url(for: .activityJournal).absoluteString,
                       "katana-connector://open?v=2&feature=activity_journal")
        let navigator = AppNavigator(path: [.capabilityLab])
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .activityJournal)))
        XCTAssertEqual(navigator.path, [.activityJournal])
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .activityJournal)))
        XCTAssertEqual(navigator.path, [.activityJournal], "repeating the link does not stack screens")
    }

    func testVersion2IsStrict() {
        assertRejects("katana-connector://open?v=2&feature=activity_journal&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
                      .invalidDraftID)
        assertRejects("katana-connector://open?v=2&feature=pairing", .unsupportedVersion)
        assertRejects("katana-connector://open?v=2&feature=screenshot_cleanup", .unsupportedVersion)
        assertRejects("katana-connector://open?v=2&feature=health_kit", .unknownFeature)
        assertRejects("katana-connector://open?v=2", .missingFeature)
        assertRejects("katana-connector://open?v=2&feature=activity%5Fjournal", .malformed)
        assertRejects("katana-connector://open?v=2&v=2&feature=activity_journal", .duplicateParameter)
        assertRejects("katana-connector://open?v=3&feature=activity_journal", .unsupportedVersion)
        for name in ["token", "code", "base_url", "device_id", "title", "body", "fire_at", "ref"] {
            assertRejects("katana-connector://open?v=2&feature=activity_journal&\(name)=x", .unknownParameter)
        }
    }

    func testVersion1IsUnchanged() throws {
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=1&feature=pairing"), .open(.pairing))
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=1&feature=screenshot_cleanup"), .open(.screenshotCleanup))
        assertRejects("katana-connector://open?v=1&feature=activity_journal", .unknownFeature)
        assertRejects("katana-connector://open?v=1&feature=pairing&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", .unknownParameter)
    }
}
