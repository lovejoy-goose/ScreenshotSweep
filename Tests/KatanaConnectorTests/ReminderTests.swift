import XCTest

/// V2-005: local reminders from Katana drafts — strict link, authenticated draft fetch,
/// confirmed scheduling, events without text. Mocks only: no real notifications or network.
final class ReminderTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!
    private var notifications: MockReminderNotifications!
    private var fetcher: MockReminderDraftFetcher!

    private let draftID = ReminderFixtures.draftID
    private let draftPath = "/api/connector/reminder-drafts/6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        directory = ContextFixtures.temporaryDirectory("Reminders")
        clock = TestClock()
        notifications = MockReminderNotifications()
        fetcher = MockReminderDraftFetcher(result: .success(ReminderFixtures.draft()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func makeCoordinator(sink: RecordingEventSink? = nil) -> ReminderCoordinator {
        let clock = self.clock!
        return ReminderCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: ReminderStoreFile.fileName),
                                   fetcher: fetcher, notifications: notifications, sink: sink, now: { clock.now() })
    }

    private func makeClient(_ tokenStore: InMemoryTokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)) -> URLSessionConnectorAPIClient {
        URLSessionConnectorAPIClient(store: tokenStore, transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                     appVersion: "0.2.0", systemVersion: "18.0", now: { Fixtures.pairedAt })
    }

    private func reply(_ status: Int, _ body: String) {
        MockURLProtocol.reply = .response(status: status, body: Data(body.utf8))
    }

    private func assertFetch(_ expected: ReminderDraftError, client: URLSessionConnectorAPIClient? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await (client ?? makeClient()).fetchReminderDraft(id: draftID)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ReminderDraftError, expected, file: file, line: line)
        }
    }

    // MARK: Strict URL v2

    private func assertRejects(_ text: String, _ expected: ConnectorURLError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ConnectorURLRouter.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? ConnectorURLError, expected, text, file: file, line: line)
        }
    }

    func testReminderLinkParsesOnlyCanonicalUUID() throws {
        let lower = "katana-connector://open?v=2&feature=reminder&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5"
        XCTAssertEqual(try ConnectorURLRouter.parse(lower), .openDestination(.reminderDraft(draftID)))
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?draft_id=6F1C2D3E-4B5A-4C6D-8E7F-90A1B2C3D4E5&feature=reminder&v=2"),
                       .openDestination(.reminderDraft(draftID)), "case and parameter order do not matter")
        XCTAssertEqual(ConnectorURLRouter.url(for: .reminderDraft(draftID)).absoluteString, lower)

        assertRejects("katana-connector://open?v=2&feature=reminder", .missingDraftID)
        for bad in ["6f1c2d3e4b5a4c6d8e7f90a1b2c3d4e5", "{6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5}", "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e",
                    "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5f", "gf1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", "6f1c2d3e-4b5a4-c6d-8e7f-90a1b2c3d4e5",
                    "not-a-uuid", "1"] {
            assertRejects("katana-connector://open?v=2&feature=reminder&draft_id=\(bad)", .invalidDraftID)
        }
        assertRejects("katana-connector://open?v=2&feature=reminder&draft_id=6f1c2d3e%2D4b5a-4c6d-8e7f-90a1b2c3d4e5", .malformed)
        assertRejects("\(lower)&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", .duplicateParameter)
        assertRejects("katana-connector://open?v=2&feature=reminder&feature=reminder&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
                      .duplicateParameter)
        assertRejects("katana-connector://open?v=1&feature=reminder&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5", .unknownParameter)
        assertRejects("katana-connector://open?v=2&feature=reminder&draft_id=", .emptyValue)
        assertRejects("\(lower) ", .notPrintableASCII)
        assertRejects("\(lower)#x", .unexpectedComponent)
    }

    func testSecretAndTextParametersAreRejected() {
        let base = "katana-connector://open?v=2&feature=reminder&draft_id=6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5"
        for name in ["token", "code", "base_url", "device_id", "title", "body", "fire_at", "expires_at", "device_token",
                     "Authorization", "text"] {
            assertRejects("\(base)&\(name)=x", .unknownParameter)
        }
    }

    @MainActor
    func testLinkOnlyNavigatesWithoutNetworkOrPermission() async {
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        let navigator = AppNavigator(path: [.capabilityLab])
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .reminderDraft(draftID))))
        XCTAssertEqual(navigator.path, [.reminders, .reminderDraft(draftID)])
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .reminderDraft(draftID))))
        XCTAssertEqual(navigator.path, [.reminders, .reminderDraft(draftID)], "reopening does not stack screens")

        // Opening the screen shows only the «Загрузить напоминание» state.
        XCTAssertEqual(coordinator.phase(for: draftID), .idle)
        XCTAssertEqual(fetcher.requested, [], "no network before the user's button")
        XCTAssertEqual(notifications.log.count("request") + notifications.log.count("schedule"), 0, "no permission, nothing scheduled")
        XCTAssertTrue(sink.attempts.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: Draft fetch (real API client over the mocked network)

    func testDraftFetchIsAuthenticatedGET() async throws {
        reply(200, ReminderFixtures.responseJSON())
        let draft = try await makeClient().fetchReminderDraft(id: draftID)
        XCTAssertEqual(draft, ReminderFixtures.draft())
        let request = try XCTUnwrap(MockURLProtocol.recorded.first)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, draftPath)
        XCTAssertEqual(request.authorization, "Bearer \(Fixtures.token)")
        XCTAssertTrue(request.body.isEmpty)
        let sent = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(sent.url?.absoluteString, "https://katana.example\(draftPath)")
        XCTAssertNil(sent.url?.query, "nothing in the query — no token, no text")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 15)
        XCTAssertFalse(String(describing: draft).contains(ReminderFixtures.title), "text never in descriptions")
    }

    func testDraftFetchStatusMapping() async {
        let cases: [(Int, ReminderDraftError)] = [
            (401, .unauthorized), (403, .notFound), (404, .notFound), (409, .consumed), (410, .expired), (408, .offline),
            (429, .rateLimited), (500, .serverError), (503, .serverError), (302, .invalidResponse), (400, .invalidResponse),
            (204, .invalidResponse),
        ]
        for (status, expected) in cases {
            reply(status, status == 204 ? "" : #"{"error":"x"}"#)
            await assertFetch(expected)
        }
        MockURLProtocol.reply = .failure(.notConnectedToInternet)
        await assertFetch(.offline)
        MockURLProtocol.reply = .failure(.timedOut)
        await assertFetch(.offline)
        XCTAssertTrue(ReminderDraftError.offline.isRetryable)
        XCTAssertFalse(ReminderDraftError.unauthorized.isRetryable, "401 is never retried")
    }

    func testDraftFetchRejectsOversizedAndInvalidBodies() async {
        let padding = String(repeating: "x", count: URLSessionConnectorTransport.maxResponseBytes)
        reply(200, #"{"pad":"\#(padding)"}"#)
        await assertFetch(.invalidResponse)

        reply(200, "not json")
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(id: "00000000-0000-4000-8000-000000000001"))
        await assertFetch(.invalidResponse)   // another draft
        reply(200, ReminderFixtures.responseJSON(title: ""))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(title: "   "))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(title: String(repeating: "я", count: 121)))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(title: "Bell\u{0007}"))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(body: String(repeating: "b", count: 501)))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(body: "tab\tinside"))
        await assertFetch(.invalidResponse)
        reply(200, ReminderFixtures.responseJSON(fireAt: "2028-01-01T00:00:00Z"))
        await assertFetch(.invalidResponse)   // more than 366 days ahead
        reply(200, ReminderFixtures.responseJSON(fireAt: "yesterday"))
        await assertFetch(.invalidResponse)
    }

    func testDraftRulesAcceptBoundaries() async throws {
        reply(200, ReminderFixtures.responseJSON(title: String(repeating: "я", count: 120), body: "строка 1\nстрока 2"))
        let draft = try await makeClient().fetchReminderDraft(id: draftID)
        XCTAssertEqual(draft.title.unicodeScalars.count, 120)
        XCTAssertEqual(draft.body, "строка 1\nстрока 2")
        reply(200, ReminderFixtures.responseJSON(body: ""))
        let empty = try await makeClient().fetchReminderDraft(id: draftID)
        XCTAssertNil(empty.body, "empty body = null")
        reply(200, ReminderFixtures.responseJSON(body: nil))
        let none = try await makeClient().fetchReminderDraft(id: draftID)
        XCTAssertNil(none.body)
        reply(200, #"{"draft_id":"6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5","title":"T","body":null,"fire_at":"2026-09-21T15:13:20.250Z","expires_at":"2026-09-21T14:23:20Z","extra":1}"#)
        _ = try await makeClient().fetchReminderDraft(id: draftID)
    }

    func testExpiredConsumedNotFoundAndAlreadyDueAreDistinct() async {
        reply(200, ReminderFixtures.responseJSON(expiresAt: "2026-09-21T14:13:20Z"))
        await assertFetch(.expired)
        reply(200, ReminderFixtures.responseJSON(fireAt: "2026-09-21T14:00:00Z"))
        await assertFetch(.alreadyDue)
        reply(410, "")
        await assertFetch(.expired)
        reply(409, "")
        await assertFetch(.consumed)
        reply(404, "")
        await assertFetch(.notFound)
    }

    func testNoRequestWithoutPairingOrAfterRevoke() async {
        await assertFetch(.notPaired, client: makeClient(InMemoryTokenStore()))
        var revoked = Fixtures.credentials
        revoked.requiresRepair = true
        await assertFetch(.unauthorized, client: makeClient(InMemoryTokenStore(credentials: revoked)))
        let unreadable = InMemoryTokenStore()
        unreadable.loadError = SecureStoreError.corruptData
        await assertFetch(.notPaired, client: makeClient(unreadable))
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "the old token is never used again")
    }

    // MARK: Scheduling

    @MainActor
    func testPermissionOnlyAfterCreateAndExactlyOneNotification() async throws {
        notifications.status = .notDetermined
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .loaded)
        XCTAssertEqual(coordinator.drafts[draftID]?.title, ReminderFixtures.title)
        XCTAssertEqual(notifications.log.count("request"), 0, "loading asks for nothing")
        XCTAssertTrue(sink.attempts.isEmpty)

        await coordinator.createReminder(draftID)
        XCTAssertEqual(notifications.log.count("request"), 1)
        XCTAssertEqual(notifications.log.count("schedule"), 1)
        let identifier = "app.katana.connector.reminder.6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5"
        XCTAssertEqual(ReminderNotificationID.make(draftID: draftID), identifier)
        let request = try XCTUnwrap(notifications.pending[identifier])
        XCTAssertEqual(request.title, ReminderFixtures.title)
        XCTAssertEqual(request.body, ReminderFixtures.body)
        XCTAssertEqual(request.fireAt, ReminderFixtures.draft().fireAt)
        XCTAssertEqual(coordinator.phase(for: draftID), .scheduled)
        XCTAssertNil(coordinator.drafts[draftID], "the in-memory draft is dropped")
        XCTAssertEqual(coordinator.reminders.count, 1)
    }

    @MainActor
    func testDuplicateTapsAndReopenCreateNoDuplicate() async throws {
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        async let one: Void = coordinator.createReminder(draftID)
        async let two: Void = coordinator.createReminder(draftID)
        _ = await (one, two)
        await coordinator.createReminder(draftID)
        await coordinator.loadDraft(draftID)   // reopening the link and tapping «Загрузить» again
        XCTAssertEqual(notifications.log.count("schedule"), 1)
        XCTAssertEqual(fetcher.requested.count, 1, "an existing reminder is shown without network")
        XCTAssertEqual(coordinator.reminders.count, 1)
        XCTAssertEqual(sink.events.count, 1)

        let relaunched = makeCoordinator(sink: sink)
        XCTAssertEqual(relaunched.phase(for: draftID), .scheduled, "after relaunch too")
        await relaunched.loadDraft(draftID)
        await relaunched.createReminder(draftID)
        XCTAssertEqual(notifications.log.count("schedule"), 1)
        XCTAssertEqual(fetcher.requested.count, 1)
    }

    @MainActor
    func testDeniedPermissionSchedulesNothing() async {
        notifications.status = .notDetermined
        notifications.statusAfterRequest = .denied
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .failed(.permissionDenied))
        XCTAssertEqual(notifications.log.count("schedule"), 0)
        XCTAssertTrue(coordinator.reminders.isEmpty)
        XCTAssertTrue(sink.attempts.isEmpty)
        XCTAssertNotNil(coordinator.drafts[draftID], "kept in memory so the user can retry after Settings")

        notifications.status = .provisional
        await coordinator.createReminder(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .scheduled)
        XCTAssertEqual(coordinator.reminders.first?.authorization, .provisional)
        XCTAssertEqual(notifications.log.count("request"), 1, "the prompt is shown once")
    }

    @MainActor
    func testFetchFailuresAreTypedAndNeverSchedule() async {
        let sink = RecordingEventSink()
        let cases: [(ReminderDraftError, ReminderCoordinator.Failure)] = [
            (.notFound, .notFound), (.expired, .expired), (.consumed, .consumed), (.alreadyDue, .alreadyDue),
            (.offline, .unavailable), (.serverError, .unavailable), (.rateLimited, .unavailable),
            (.invalidResponse, .invalidResponse), (.notPaired, .notPaired),
        ]
        for (error, failure) in cases {
            fetcher.result = .failure(error)
            let coordinator = makeCoordinator(sink: sink)
            await coordinator.loadDraft(draftID)
            XCTAssertEqual(coordinator.phase(for: draftID), .failed(failure), "\(error)")
            await coordinator.createReminder(draftID)
            XCTAssertNil(coordinator.drafts[draftID])
        }
        XCTAssertEqual(notifications.log.count("schedule") + notifications.log.count("request"), 0)
        XCTAssertTrue(sink.attempts.isEmpty)
        XCTAssertEqual(sink.unauthorizedReports, 0)
    }

    @MainActor
    func testOfflineIsRetryableByButtonOnly() async {
        fetcher.result = .failure(.offline)
        let coordinator = makeCoordinator()
        await coordinator.loadDraft(draftID)
        XCTAssertEqual(fetcher.requested.count, 1, "no automatic retry")
        fetcher.result = .success(ReminderFixtures.draft())
        await coordinator.loadDraft(draftID)   // «Повторить»
        XCTAssertEqual(coordinator.phase(for: draftID), .loaded)
        XCTAssertEqual(fetcher.requested.count, 2)
    }

    @MainActor
    func test401MarksRepairAndIsNotRetried() async throws {
        let api = MockConnectorAPI()
        let (_, delivery) = ContextFixtures.delivery(queueDirectory: directory.appendingPathComponent("Queue"), api: api)
        var unauthorized = 0
        delivery.onUnauthorized = { unauthorized += 1 }
        fetcher.result = .failure(.unauthorized)
        let coordinator = makeCoordinator()
        coordinator.sink = delivery
        await coordinator.loadDraft(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .failed(.requiresRepair))
        XCTAssertEqual(delivery.status, .requiresRepair)
        XCTAssertEqual(unauthorized, 1, "pairing is flagged once")
        XCTAssertEqual(fetcher.requested.count, 1)
        XCTAssertEqual(notifications.log.count("schedule"), 0)
    }

    @MainActor
    func testDraftExpiringOrComingDueBeforeTheTapSchedulesNothing() async {
        let coordinator = makeCoordinator()
        await coordinator.loadDraft(draftID)
        clock.advance(601)
        await coordinator.createReminder(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .failed(.expired))

        fetcher.result = .success(ReminderFixtures.draft(fireIn: 60, expiresIn: 3600))
        clock.date = Fixtures.pairedAt
        let late = makeCoordinator()
        await late.loadDraft(draftID)
        clock.advance(61)
        await late.createReminder(draftID)
        XCTAssertEqual(late.phase(for: draftID), .failed(.alreadyDue))
        XCTAssertEqual(notifications.log.count("schedule"), 0)
    }

    @MainActor
    func testScheduleFailureLeavesNoRecord() async {
        notifications.scheduleError = CapabilityProbeError.systemError
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        XCTAssertEqual(coordinator.phase(for: draftID), .failed(.scheduleFailed))
        XCTAssertTrue(coordinator.reminders.isEmpty)
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    // MARK: Events

    @MainActor
    func testScheduledAndCancelledEventsHaveNoText() async throws {
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        clock.date = Fixtures.pairedAt.addingTimeInterval(5.8)
        await coordinator.createReminder(draftID)

        let scheduled = try XCTUnwrap(sink.events.first)
        let json = try ContextFixtures.json(scheduled)
        XCTAssertEqual(json["type"] as? String, "reminder.local.scheduled")
        XCTAssertEqual(json["session_id"] as? String, "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5")
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:25Z")
        let payload = try ContextFixtures.payload(scheduled)
        XCTAssertEqual(Set(payload.keys), ["draft_id", "scheduled_for", "notification_id", "authorization", "created_at"])
        XCTAssertEqual(payload["draft_id"] as? String, "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5")
        XCTAssertEqual(payload["scheduled_for"] as? String, "2026-09-21T15:13:20Z")
        XCTAssertEqual(payload["notification_id"] as? String, "app.katana.connector.reminder.6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5")
        XCTAssertEqual(payload["authorization"] as? String, "authorized")
        XCTAssertEqual(payload["created_at"] as? String, "2026-09-21T14:13:25Z")

        clock.advance(60)
        await coordinator.cancelReminder(draftID)
        XCTAssertEqual(sink.events.count, 2)
        let cancelled = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(cancelled.type, "reminder.local.cancelled")
        let cancelledPayload = try ContextFixtures.payload(cancelled)
        XCTAssertEqual(Set(cancelledPayload.keys), ["draft_id", "notification_id", "cancelled_at"])
        XCTAssertEqual(cancelledPayload["cancelled_at"] as? String, "2026-09-21T14:14:25Z")
        XCTAssertNotEqual(cancelled.eventID, scheduled.eventID)

        for event in sink.events {
            let text = try ContextFixtures.text(event)
            for forbidden in [ReminderFixtures.title, ReminderFixtures.body, "\"title\"", "\"body\"", "Позвонить", "token"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        }
        XCTAssertEqual(ReminderAuthorization.allCases.map(\.rawValue), ["authorized", "provisional", "ephemeral"])
    }

    @MainActor
    func testCancelRemovesOnlyOwnNotificationAndOnlyOnce() async throws {
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        let foreignBefore = notifications.foreign
        await coordinator.cancelReminder(draftID)
        await coordinator.cancelReminder(draftID)
        XCTAssertEqual(notifications.log.count("remove"), 1)
        XCTAssertTrue(notifications.pending.isEmpty)
        XCTAssertEqual(notifications.foreign, foreignBefore, "other notifications are never touched")
        XCTAssertEqual(coordinator.record(for: draftID)?.status, .cancelled)
        XCTAssertEqual(sink.events.map(\.type), ["reminder.local.scheduled", "reminder.local.cancelled"])
        XCTAssertEqual(makeCoordinator().record(for: draftID)?.status, .cancelled, "persisted")
    }

    @MainActor
    func testDueReminderCannotBeCancelled() async {
        let sink = RecordingEventSink()
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        clock.advance(3601)
        await coordinator.cancelReminder(draftID)
        XCTAssertEqual(notifications.log.count("remove"), 0)
        XCTAssertEqual(coordinator.record(for: draftID)?.status, .scheduled)
        XCTAssertEqual(sink.events.count, 1)
    }

    @MainActor
    func testUnsavedEventsAreRetriedWithTheSameIDsAfterRelaunch() async throws {
        let sink = RecordingEventSink()
        sink.outcome = .notPaired
        let coordinator = makeCoordinator(sink: sink)
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        await coordinator.cancelReminder(draftID)
        XCTAssertTrue(sink.events.isEmpty)
        let record = try XCTUnwrap(coordinator.record(for: draftID))
        XCTAssertFalse(record.scheduledEventSaved)
        XCTAssertFalse(record.cancelledEventSaved)

        sink.outcome = .saved
        let relaunched = makeCoordinator(sink: sink)
        await relaunched.retryPendingEvents()
        await relaunched.retryPendingEvents()
        XCTAssertEqual(sink.events.map(\.type), ["reminder.local.scheduled", "reminder.local.cancelled"], "in order, once")
        XCTAssertEqual(sink.events.map(\.eventID), [record.scheduledEventID, try XCTUnwrap(record.cancelledEventID)])
        XCTAssertEqual(relaunched.record(for: draftID)?.cancelledEventSaved, true)
    }

    @MainActor
    func testOfflineQueueRelaunchAndScope() async throws {
        let queueDirectory = ContextFixtures.temporaryDirectory("ReminderQueue")
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let coordinator = makeCoordinator()
        coordinator.sink = delivery
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        await delivery.waitForFlush()
        let pending = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(pending.map(\.type), ["reminder.local.scheduled"])
        XCTAssertEqual(coordinator.record(for: draftID)?.scheduledEventSaved, true, "saved on disk counts as saved")

        api.batchHandler = { events in MockConnectorAPI.results(events, .duplicate) }
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0, "duplicate = delivered")
        XCTAssertEqual(Set(api.sentBatches.flatMap { $0 }.map(\.eventID)), [try XCTUnwrap(pending.first?.eventID)])
        XCTAssertEqual(Set(api.sentScopes), [EventFixtures.scope])
    }

    // MARK: Storage

    @MainActor
    func testStoreFormatAndQuarantine() async throws {
        let coordinator = makeCoordinator(sink: RecordingEventSink())
        await coordinator.loadDraft(draftID)
        await coordinator.createReminder(draftID)
        let url = directory.appendingPathComponent(ReminderStoreFile.fileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let first = try XCTUnwrap((json["reminders"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["draft_id", "notification_id", "title", "body", "fire_at", "created_at", "authorization",
                                         "status", "scheduled_event_id", "scheduled_event_saved", "cancelled_event_saved"])
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains(Fixtures.token))
        XCTAssertEqual(ReminderStoreFile.fileName, "reminders.json")
        XCTAssertEqual(ReminderStoreFile.directoryName, "Reminders")
        XCTAssertEqual(ReminderStoreFile.currentVersion, 1)
        let path = ReminderStoreFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/Reminders/reminders.json"), path)

        try Data(#"{"version":2,"reminders":[]}"#.utf8).write(to: url)
        let quarantined = makeCoordinator()
        XCTAssertEqual(quarantined.storageIssue, .quarantined)
        XCTAssertTrue(quarantined.reminders.isEmpty)
    }
}
