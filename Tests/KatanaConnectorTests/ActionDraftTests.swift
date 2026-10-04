import XCTest

@MainActor
final class MockActionDraftHandler: ActionDraftHandler {
    var result: ActionDraftHandlerResult
    private(set) var performed: [ActionDraft] = []

    init(result: ActionDraftHandlerResult) {
        self.result = result
    }

    func performActionDraft(_ draft: ActionDraft) async -> ActionDraftHandlerResult {
        performed.append(draft)
        return result
    }
}

final class MockActionDraftFetcher: ActionDraftFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [UUID] = []
    var result: Result<ActionDraft, ActionDraftError>

    init(result: Result<ActionDraft, ActionDraftError>) {
        self.result = result
    }

    var requested: [UUID] { lock.lock(); defer { lock.unlock() }; return _requested }

    func fetchActionDraft(id: UUID) async throws -> ActionDraft {
        lock.lock(); _requested.append(id); lock.unlock()
        return try result.get()
    }
}

enum ActionDraftFixtures {
    static let draftID = UUID(uuidString: "0B9F6C1E-2D3A-4B5C-8D6E-7F8091A2B3C4")!
    static let draftText = "0b9f6c1e-2d3a-4b5c-8d6e-7f8091a2b3c4"
    static let actionID = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!
    static let serverTime = "2026-10-05T09:00:00Z"
    static let serverDate = Date(timeIntervalSince1970: 1_791_190_800)   // 2026-10-05T09:00:00Z

    static func json(kind: String = "nfc_action", id: String = draftText, serverTime: String = serverTime,
                     expiresAt: String = "2026-10-05T10:00:00Z", payload: String? = nil, extra: String = "") -> String {
        let body = payload ?? defaultPayload(kind)
        return #"{"draft_id":"\#(id)","kind":"\#(kind)","server_time":"\#(serverTime)","expires_at":"\#(expiresAt)","payload":\#(body)\#(extra)}"#
    }

    static func defaultPayload(_ kind: String) -> String {
        switch kind {
        case "geofence_create": return #"{"latitude":55.755814,"longitude":37.617635,"radius_m":200,"name_suggestion":"Офис"}"#
        case "shared_capture": return #"{"accepted_kinds":["image","pdf"],"prompt":"Пришлите фото чека"}"#
        default: return #"{"action_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","label":"Открыть дверь"}"#
        }
    }

    static func nfcDraft(expiresIn: TimeInterval = 3600) -> ActionDraft {
        ActionDraft(draftID: draftID, serverTime: serverDate, expiresAt: serverDate.addingTimeInterval(expiresIn),
                    payload: .nfcAction(NFCActionDraftPayload(actionID: actionID, label: "Открыть дверь")))
    }
}

/// V3-002: URL v3, strict action draft schema and fetch, execute-once coordinator.
final class ActionDraftTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        directory = ContextFixtures.temporaryDirectory("ActionDrafts")
        clock = TestClock()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func client(_ store: InMemoryTokenStore = InMemoryTokenStore(credentials: Fixtures.credentials),
                        now: Date = Fixtures.pairedAt) -> URLSessionConnectorAPIClient {
        URLSessionConnectorAPIClient(store: store, transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                     appVersion: "0.3.0", systemVersion: "18.0", now: { now })
    }

    private func reply(_ status: Int, _ body: String) {
        MockURLProtocol.reply = .response(status: status, body: Data(body.utf8))
    }

    private func assertFetch(_ expected: ActionDraftError, _ client: URLSessionConnectorAPIClient? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await (client ?? self.client()).fetchActionDraft(id: ActionDraftFixtures.draftID)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ActionDraftError, expected, file: file, line: line)
        }
    }

    @MainActor
    private func makeCoordinator(fetcher: MockActionDraftFetcher, sink: RecordingEventSink? = nil) -> ActionDraftCoordinator {
        let clock = self.clock!
        return ActionDraftCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: ActionDraftStoreFile.fileName),
                                      fetcher: fetcher, sink: sink, now: { clock.now() })
    }

    private func assertRejects(_ text: String, _ expected: ConnectorURLError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ConnectorURLRouter.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? ConnectorURLError, expected, text, file: file, line: line)
        }
    }

    // MARK: URL v3

    func testActionLinkParsesOnlyCanonicalUUID() throws {
        let link = "katana-connector://open?v=3&feature=action&draft_id=\(ActionDraftFixtures.draftText)"
        XCTAssertEqual(try ConnectorURLRouter.parse(link), .openDestination(.actionDraft(ActionDraftFixtures.draftID)))
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open/?draft_id=0B9F6C1E-2D3A-4B5C-8D6E-7F8091A2B3C4&v=3&feature=action"),
                       .openDestination(.actionDraft(ActionDraftFixtures.draftID)))
        XCTAssertEqual(ConnectorURLRouter.url(for: .actionDraft(ActionDraftFixtures.draftID)).absoluteString, link)

        assertRejects("katana-connector://open?v=3&feature=action", .missingDraftID)
        assertRejects("katana-connector://open?v=3&feature=action&draft_id=0b9f6c1e2d3a4b5c8d6e7f8091a2b3c4", .invalidDraftID)
        assertRejects("katana-connector://open?v=3&feature=action&draft_id=x", .invalidDraftID)
        assertRejects("\(link)&draft_id=\(ActionDraftFixtures.draftText)", .duplicateParameter)
        assertRejects("katana-connector://open?v=3&v=3&feature=action&draft_id=\(ActionDraftFixtures.draftText)", .duplicateParameter)
        assertRejects("katana-connector://open?v=3&feature=action&draft_id=0b9f6c1e%2D2d3a-4b5c-8d6e-7f8091a2b3c4", .malformed)
        assertRejects("\(link)#run", .unexpectedComponent)
        assertRejects("katana-connector://open:1?v=3&feature=action&draft_id=\(ActionDraftFixtures.draftText)", .unexpectedComponent)
        assertRejects("\(link)&action_id=\(ActionDraftFixtures.draftText)", .unknownParameter)
        assertRejects("katana-connector://open?v=3&feature=launch&draft_id=\(ActionDraftFixtures.draftText)", .unknownFeature)
        assertRejects("\(link)\u{0007}", .notPrintableASCII)
    }

    func testV3RejectsSecretsCommandsAndContent() {
        let link = "katana-connector://open?v=3&feature=action&draft_id=\(ActionDraftFixtures.draftText)"
        for name in ["token", "code", "base_url", "device_id", "title", "body", "command", "run", "latitude", "longitude",
                     "name", "url", "file", "text", "label", "kind", "payload"] {
            assertRejects("\(link)&\(name)=x", .unknownParameter)
        }
    }

    func testVersionsDoNotLeakIntoEachOther() {
        for feature in ["screenshot_cleanup", "pairing", "activity_journal", "location_check_in", "reminder"] {
            assertRejects("katana-connector://open?v=3&feature=\(feature)", .unsupportedVersion)
        }
        assertRejects("katana-connector://open?v=2&feature=action&draft_id=\(ActionDraftFixtures.draftText)", .unknownFeature)
        assertRejects("katana-connector://open?v=1&feature=pairing&action_id=\(ActionDraftFixtures.draftText)", .unknownParameter)
        assertRejects("katana-connector://open?v=2&feature=activity_journal&action_id=\(ActionDraftFixtures.draftText)", .unknownParameter)
        assertRejects("katana-connector://open?v=4&feature=action&draft_id=\(ActionDraftFixtures.draftText)", .unsupportedVersion)
        XCTAssertEqual(ConnectorURLRouter.url(for: .pairing).absoluteString, "katana-connector://open?v=1&feature=pairing")
        XCTAssertEqual(ConnectorURLRouter.url(for: .activityJournal).absoluteString, "katana-connector://open?v=2&feature=activity_journal")
    }

    @MainActor
    func testLinkOnlyNavigatesWithoutHiddenExecution() async {
        let fetcher = MockActionDraftFetcher(result: .success(ActionDraftFixtures.nfcDraft()))
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(fetcher: fetcher, sink: sink)
        let handler = MockActionDraftHandler(result: .completed(resultRef: ActionDraftFixtures.actionID))
        coordinator.register(handler, for: .nfcAction)
        let navigator = AppNavigator(path: [.reminders])
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .actionDraft(ActionDraftFixtures.draftID))))
        XCTAssertEqual(navigator.path, [.actionDraft(ActionDraftFixtures.draftID)])
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .idle)
        XCTAssertEqual(fetcher.requested, [])
        XCTAssertTrue(handler.performed.isEmpty)
        XCTAssertTrue(sink.attempts.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: Fetch (real client over the mocked network)

    func testFetchIsAuthenticatedGETAndParsesEveryKind() async throws {
        reply(200, ActionDraftFixtures.json())
        let nfc = try await client().fetchActionDraft(id: ActionDraftFixtures.draftID)
        XCTAssertEqual(nfc, ActionDraftFixtures.nfcDraft())
        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/connector/action-drafts/\(ActionDraftFixtures.draftText)")
        XCTAssertEqual(request.authorization, "Bearer \(Fixtures.token)")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertNil(MockURLProtocol.lastRequest?.url?.query)
        XCTAssertFalse(String(describing: nfc).contains("Открыть"), "content is never in descriptions")

        reply(200, ActionDraftFixtures.json(kind: "geofence_create"))
        let geofence = try await client().fetchActionDraft(id: ActionDraftFixtures.draftID)
        XCTAssertEqual(geofence.payload, .geofenceCreate(GeofenceDraftPayload(latitude: 55.7558, longitude: 37.6176,
                                                                              radiusMeters: 200, nameSuggestion: "Офис")),
                       "coordinates rounded to 4 decimals on arrival")

        reply(200, ActionDraftFixtures.json(kind: "shared_capture"))
        let capture = try await client().fetchActionDraft(id: ActionDraftFixtures.draftID)
        XCTAssertEqual(capture.payload, .sharedCapture(CaptureDraftPayload(acceptedKinds: [.image, .pdf], prompt: "Пришлите фото чека")))
    }

    func testStrictSchemaRejectsUnknownMissingAndMistypedFields() async {
        let invalid: [String] = [
            ActionDraftFixtures.json(extra: #","command":"x""#),
            ActionDraftFixtures.json(payload: #"{"action_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","label":"x","url":"y"}"#),
            ActionDraftFixtures.json(payload: #"{"action_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"}"#),
            ActionDraftFixtures.json(kind: "run_command"),
            ActionDraftFixtures.json(id: "00000000-0000-4000-8000-000000000001"),
            ActionDraftFixtures.json(payload: #"{"action_id":"nope","label":"x"}"#),
            ActionDraftFixtures.json(payload: #"{"action_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","label":"\#(String(repeating: "я", count: 61))"}"#),
            ActionDraftFixtures.json(payload: #"{"action_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","label":"a\tb"}"#),
            ActionDraftFixtures.json(kind: "geofence_create", payload: #"{"latitude":55.7,"longitude":37.6,"radius_m":150,"name_suggestion":"x"}"#),
            ActionDraftFixtures.json(kind: "geofence_create", payload: #"{"latitude":95,"longitude":37.6,"radius_m":200,"name_suggestion":"x"}"#),
            ActionDraftFixtures.json(kind: "geofence_create", payload: #"{"latitude":"55.7","longitude":37.6,"radius_m":200,"name_suggestion":"x"}"#),
            ActionDraftFixtures.json(kind: "geofence_create", payload: #"{"latitude":55.7,"longitude":37.6,"radius_m":true,"name_suggestion":"x"}"#),
            ActionDraftFixtures.json(kind: "shared_capture", payload: #"{"accepted_kinds":[],"prompt":"x"}"#),
            ActionDraftFixtures.json(kind: "shared_capture", payload: #"{"accepted_kinds":["image","image"],"prompt":"x"}"#),
            ActionDraftFixtures.json(kind: "shared_capture", payload: #"{"accepted_kinds":["video"],"prompt":"x"}"#),
            ActionDraftFixtures.json(expiresAt: "2026-10-20T09:00:00Z"),   // longer than 7 days
            ActionDraftFixtures.json(serverTime: "soon"),
            "[]", "not json",
        ]
        for body in invalid {
            reply(200, body)
            await assertFetch(.invalidResponse)
        }
    }

    func testTTLUsesServerTimeNotThePhoneClock() async throws {
        reply(200, ActionDraftFixtures.json(serverTime: "2026-10-05T10:00:00Z", expiresAt: "2026-10-05T10:00:00Z"))
        await assertFetch(.expired)
        // The phone clock is far ahead of the server: still valid by server time.
        reply(200, ActionDraftFixtures.json())
        _ = try await client(now: Date(timeIntervalSince1970: 2_000_000_000)).fetchActionDraft(id: ActionDraftFixtures.draftID)
        // The phone clock is far behind: an expired draft is still expired.
        reply(200, ActionDraftFixtures.json(serverTime: "2026-10-05T11:00:00Z"))
        await assertFetch(.expired, client(now: Date(timeIntervalSince1970: 0)))

        let draft = ActionDraftFixtures.nfcDraft(expiresIn: 60)
        XCTAssertFalse(draft.isExpired(elapsedSinceLoad: 59))
        XCTAssertTrue(draft.isExpired(elapsedSinceLoad: 60))
        XCTAssertFalse(draft.isExpired(elapsedSinceLoad: -1000), "a clock moved back never extends nor breaks TTL")
    }

    func testStatusMappingRedirectSizeAndAuth() async {
        let cases: [(Int, ActionDraftError)] = [
            (401, .unauthorized), (403, .notFound), (404, .notFound), (409, .consumed), (410, .expired), (408, .offline),
            (429, .rateLimited), (500, .serverError), (302, .invalidResponse), (400, .invalidResponse),
        ]
        for (status, expected) in cases {
            reply(status, "{}")
            await assertFetch(expected)
        }
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        await assertFetch(.offline)
        reply(200, #"{"pad":"\#(String(repeating: "x", count: URLSessionConnectorTransport.maxResponseBytes))"}"#)
        await assertFetch(.invalidResponse)

        MockURLProtocol.reset()
        await assertFetch(.notPaired, client(InMemoryTokenStore()))
        var revoked = Fixtures.credentials
        revoked.requiresRepair = true
        await assertFetch(.unauthorized, client(InMemoryTokenStore(credentials: revoked)))
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no request without valid credentials")
    }

    // MARK: Coordinator: execute once

    @MainActor
    func testPerformOnceRecordsAcceptedEventWithExactPayload() async throws {
        let fetcher = MockActionDraftFetcher(result: .success(ActionDraftFixtures.nfcDraft()))
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(fetcher: fetcher, sink: sink)
        let handler = MockActionDraftHandler(result: .completed(resultRef: ActionDraftFixtures.actionID))
        coordinator.register(handler, for: .nfcAction)

        await coordinator.loadDraft(ActionDraftFixtures.draftID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .loaded)
        XCTAssertTrue(handler.performed.isEmpty, "loading performs nothing")

        clock.date = Fixtures.pairedAt.addingTimeInterval(0.9)
        async let one: Void = coordinator.perform(ActionDraftFixtures.draftID)
        async let two: Void = coordinator.perform(ActionDraftFixtures.draftID)
        _ = await (one, two)
        await coordinator.perform(ActionDraftFixtures.draftID)
        await coordinator.loadDraft(ActionDraftFixtures.draftID)
        XCTAssertEqual(handler.performed.count, 1)
        XCTAssertEqual(fetcher.requested.count, 1, "accepted drafts are not fetched again")
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .accepted)

        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(sink.events.count, 1)
        let json = try ContextFixtures.json(event)
        XCTAssertEqual(json["type"] as? String, "action_draft.accepted")
        XCTAssertEqual(json["session_id"] as? String, ActionDraftFixtures.draftText)
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:20Z")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["draft_id", "kind", "accepted_at", "result_ref"])
        XCTAssertEqual(payload["kind"] as? String, "nfc_action")
        XCTAssertEqual(payload["result_ref"] as? String, ActionDraftFixtures.actionID.uuidString.lowercased())
        XCTAssertFalse(try ContextFixtures.text(event).contains("Открыть"), "no labels in events")

        let relaunched = makeCoordinator(fetcher: fetcher, sink: sink)
        relaunched.register(handler, for: .nfcAction)
        XCTAssertEqual(relaunched.phase(for: ActionDraftFixtures.draftID), .accepted)
        await relaunched.loadDraft(ActionDraftFixtures.draftID)
        await relaunched.perform(ActionDraftFixtures.draftID)
        XCTAssertEqual(handler.performed.count, 1, "never executed twice, also after relaunch")
    }

    @MainActor
    func testExpiryUnsupportedNotPerformedAndDeferred() async {
        let fetcher = MockActionDraftFetcher(result: .success(ActionDraftFixtures.nfcDraft(expiresIn: 60)))
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(fetcher: fetcher, sink: sink)
        await coordinator.loadDraft(ActionDraftFixtures.draftID)
        await coordinator.perform(ActionDraftFixtures.draftID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .failed(.unsupported), "no feature registered")

        let handler = MockActionDraftHandler(result: .notPerformed)
        coordinator.register(handler, for: .nfcAction)
        await coordinator.loadDraft(ActionDraftFixtures.draftID)
        await coordinator.perform(ActionDraftFixtures.draftID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .failed(.notPerformed))
        handler.result = .continuing
        await coordinator.perform(ActionDraftFixtures.draftID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .continuing)
        coordinator.abandonDeferred(draftID: ActionDraftFixtures.draftID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .loaded)
        await coordinator.perform(ActionDraftFixtures.draftID)
        let captureID = UUID()
        await coordinator.completeDeferred(draftID: ActionDraftFixtures.draftID, kind: .sharedCapture, resultRef: captureID)
        XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .accepted)
        XCTAssertEqual(coordinator.acceptedRecord(for: ActionDraftFixtures.draftID)?.resultRef, captureID)
        XCTAssertEqual(sink.events.count, 1)

        // TTL measured on the server clock plus elapsed time.
        let other = UUID()
        fetcher.result = .success(ActionDraft(draftID: other, serverTime: ActionDraftFixtures.serverDate,
                                              expiresAt: ActionDraftFixtures.serverDate.addingTimeInterval(60),
                                              payload: .nfcAction(NFCActionDraftPayload(actionID: UUID(), label: "x"))))
        await coordinator.loadDraft(other)
        clock.advance(61)
        await coordinator.perform(other)
        XCTAssertEqual(coordinator.phase(for: other), .failed(.expired))
        XCTAssertEqual(handler.performed.count, 3)
    }

    @MainActor
    func testFetchFailuresAreTypedAnd401ReportsRepair() async {
        let sink = RecordingEventSink()
        let cases: [(ActionDraftError, ActionDraftCoordinator.Failure)] = [
            (.notFound, .notFound), (.expired, .expired), (.consumed, .consumed), (.offline, .unavailable),
            (.serverError, .unavailable), (.invalidResponse, .invalidResponse), (.notPaired, .notPaired),
            (.unauthorized, .requiresRepair),
        ]
        for (error, failure) in cases {
            let coordinator = makeCoordinator(fetcher: MockActionDraftFetcher(result: .failure(error)), sink: sink)
            await coordinator.loadDraft(ActionDraftFixtures.draftID)
            XCTAssertEqual(coordinator.phase(for: ActionDraftFixtures.draftID), .failed(failure), "\(error)")
        }
        XCTAssertEqual(sink.unauthorizedReports, 1)
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    @MainActor
    func testUnsavedAcceptedEventRetriesWithSameIDAndStoreIsStable() async throws {
        let fetcher = MockActionDraftFetcher(result: .success(ActionDraftFixtures.nfcDraft()))
        let sink = RecordingEventSink()
        sink.outcome = .notPaired
        let coordinator = makeCoordinator(fetcher: fetcher, sink: sink)
        // Handlers are held weakly (the app owns the features): keep this one alive.
        let handler = MockActionDraftHandler(result: .completed(resultRef: ActionDraftFixtures.actionID))
        coordinator.register(handler, for: .nfcAction)
        await coordinator.loadDraft(ActionDraftFixtures.draftID)
        await coordinator.perform(ActionDraftFixtures.draftID)
        let eventID = try XCTUnwrap(coordinator.acceptedRecord(for: ActionDraftFixtures.draftID)?.eventID)

        sink.outcome = .saved
        let relaunched = makeCoordinator(fetcher: fetcher, sink: sink)
        await relaunched.retryPendingEvents()
        await relaunched.retryPendingEvents()
        XCTAssertEqual(sink.events.map(\.eventID), [eventID])

        XCTAssertEqual(ActionDraftStoreFile.fileName, "action-drafts.json")
        XCTAssertEqual(ActionDraftStoreFile.currentVersion, 1)
        let path = ActionDraftStoreFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/ActionDrafts/action-drafts.json"), path)
        try Data("{".utf8).write(to: directory.appendingPathComponent(ActionDraftStoreFile.fileName))
        XCTAssertEqual(makeCoordinator(fetcher: fetcher).storageIssue, .quarantined)
    }
}
