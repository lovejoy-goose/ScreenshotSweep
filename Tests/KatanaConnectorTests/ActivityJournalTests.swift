import XCTest

/// V2-003: Activity Journal on mocks — no Core Motion, no real prompts, no network.
final class ActivityJournalTests: XCTestCase {
    private var directory: URL!
    private var system: MockActivitySystem!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("ActivityJournal")
        system = MockActivitySystem()
        clock = TestClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var store: VersionedJSONFileStore<ActivityJournalFile> {
        VersionedJSONFileStore(directoryURL: directory, fileName: ActivityJournalFile.fileName)
    }

    @MainActor
    private func makeJournal(sink: RecordingEventSink? = nil, sleeper: any DeliverySleeper = NeverSleeper()) -> ActivityJournalCoordinator {
        let clock = self.clock!
        return ActivityJournalCoordinator(store: store, system: system, sink: sink, sleeper: sleeper, now: { clock.now() })
    }

    /// Emits a reading and waits until the coordinator has applied it.
    @MainActor
    private func emit(_ reading: MotionActivityReading, to journal: ActivityJournalCoordinator) async {
        let expected = ActivityClassifier.category(for: reading)
        system.emit(reading)
        await waitUntil { journal.session?.currentActivity == expected }
    }

    private func fileText() throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent(ActivityJournalFile.fileName)), as: UTF8.self)
    }

    // MARK: Classification

    func testExactCategoryMapping() {
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(stationary: true)), .stationary)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(walking: true)), .walking)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(running: true)), .running)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(cycling: true)), .cycling)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(automotive: true)), .automotive)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(unknown: true)), .unknown)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading()), .unknown, "no flags")
    }

    func testAmbiguousFlagsFollowDocumentedPriority() {
        XCTAssertEqual(ActivityCategory.priority, [.automotive, .cycling, .running, .walking, .stationary, .unknown])
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(stationary: true, automotive: true)), .automotive,
                       "a stopped car reports both")
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(walking: true, running: true)), .running)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(walking: true, cycling: true)), .cycling)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(stationary: true, walking: true)), .walking)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(walking: true, unknown: true)), .walking)
        XCTAssertEqual(ActivityClassifier.category(for: MotionActivityReading(stationary: true, walking: true, running: true,
                                                                              cycling: true, automotive: true, unknown: true)),
                       .automotive)
    }

    func testWireValues() {
        XCTAssertEqual(ActivityCategory.allCases.map(\.rawValue),
                       ["stationary", "walking", "running", "cycling", "automotive", "unknown"])
        XCTAssertEqual(ActivityConfidence.allCases.map(\.rawValue), ["low", "medium", "high"])
        XCTAssertEqual(ContextEventType.activitySnapshot.rawValue, "activity.snapshot.completed")
        XCTAssertEqual(ContextEventType.activitySession.rawValue, "activity.session.completed")
        XCTAssertEqual(ActivitySnapshot.source, "motion_activity")
    }

    // MARK: Permissions

    @MainActor
    func testNothingIsRequestedUntilTheButton() async {
        system.status = .notDetermined
        let journal = makeJournal()
        _ = journal
        XCTAssertEqual(system.log.count("request") + system.log.count("reading") + system.log.count("start"), 0)
        await journal.appDidBecomeActive()
        XCTAssertEqual(system.log.count("request") + system.log.count("start"), 0, "foreground without a session does nothing")
    }

    @MainActor
    func testFirstTapRequestsPermissionOnceThenReads() async {
        system.status = .notDetermined
        let journal = makeJournal()
        await journal.checkCurrentActivity()
        XCTAssertEqual(system.log.count("request"), 1)
        XCTAssertEqual(system.log.count("reading"), 1)
        XCTAssertEqual(journal.snapshotPhase, .preview)
        await journal.checkCurrentActivity()
        XCTAssertEqual(system.log.count("request"), 1, "already authorized: no second prompt")
    }

    @MainActor
    func testDeniedRestrictedAndUnsupported() async {
        for (status, failure) in [(MotionPermission.denied, ActivityJournalCoordinator.Failure.permissionDenied),
                                  (.restricted, .permissionRestricted)] {
            system.status = status
            let journal = makeJournal()
            await journal.checkCurrentActivity()
            XCTAssertEqual(journal.snapshotPhase, .failed(failure))
            await journal.startSession()
            XCTAssertEqual(journal.sessionFailure, failure)
            XCTAssertNil(journal.session)
        }
        system.status = .notDetermined
        system.statusAfterRequest = .denied
        let declined = makeJournal()
        await declined.checkCurrentActivity()
        XCTAssertEqual(declined.snapshotPhase, .failed(.permissionDenied))

        system.available = false
        let unsupported = makeJournal()
        await unsupported.checkCurrentActivity()
        XCTAssertEqual(unsupported.snapshotPhase, .failed(.unsupported))
        XCTAssertEqual(system.log.count("reading"), 0, "no reading without permission or support")
        XCTAssertEqual(system.log.count("start"), 0)
    }

    @MainActor
    func testSnapshotTimeoutAndSystemError() async {
        system.hangsOnReading = true
        let journal = makeJournal(sleeper: ImmediateSleeper())
        await journal.checkCurrentActivity()
        XCTAssertEqual(journal.snapshotPhase, .failed(.timedOut))
        XCTAssertNil(journal.snapshot)

        system.hangsOnReading = false
        system.readingError = .systemError
        let failing = makeJournal()
        await failing.checkCurrentActivity()
        XCTAssertEqual(failing.snapshotPhase, .failed(.systemError))
    }

    // MARK: Snapshot event

    @MainActor
    func testSnapshotEventWireFormat() async throws {
        system.reading = MotionActivityReading(stationary: true, automotive: true, confidence: .medium)
        let sink = RecordingEventSink()
        let journal = makeJournal(sink: sink)
        await journal.checkCurrentActivity()
        XCTAssertTrue(sink.attempts.isEmpty, "checking creates nothing for Katana")
        let snapshot = try XCTUnwrap(journal.snapshot)
        XCTAssertEqual(snapshot.checkedAt, Fixtures.pairedAt)

        await journal.sendSnapshot()
        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(sink.events.count, 1)
        let json = try ContextFixtures.json(event)
        XCTAssertEqual(json["type"] as? String, "activity.snapshot.completed")
        XCTAssertEqual(json["event_id"] as? String, snapshot.eventID.uuidString.lowercased())
        XCTAssertEqual(json["session_id"] as? String, snapshot.snapshotID.uuidString.lowercased())
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:20Z")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["activity", "confidence", "checked_at", "source", "interrupted"])
        XCTAssertEqual(payload["activity"] as? String, "automotive")
        XCTAssertEqual(payload["confidence"] as? String, "medium")
        XCTAssertEqual(payload["checked_at"] as? String, "2026-09-21T14:13:20Z")
        XCTAssertEqual(payload["source"] as? String, "motion_activity")
        XCTAssertEqual(payload["interrupted"] as? Bool, false)
        XCTAssertEqual(journal.snapshotPhase, .saved)
        XCTAssertEqual(journal.history.first?.kind, .snapshot)
    }

    @MainActor
    func testSnapshotRetryReusesEventIDAndDiscardSendsNothing() async throws {
        let sink = RecordingEventSink()
        sink.outcome = .notPaired
        let journal = makeJournal(sink: sink)
        await journal.checkCurrentActivity()
        await journal.sendSnapshot()
        XCTAssertEqual(journal.snapshotPhase, .failed(.notPaired))
        XCTAssertTrue(sink.events.isEmpty)

        sink.outcome = .saved
        await journal.sendSnapshot()
        await journal.sendSnapshot()   // second tap after success: nothing
        XCTAssertEqual(Set(sink.attempts.map(\.eventID)).count, 1, "same event_id on retry")
        XCTAssertEqual(sink.events.count, 1)

        await journal.checkCurrentActivity()
        journal.discardSnapshot()
        XCTAssertNil(journal.snapshot)
        XCTAssertEqual(sink.events.count, 1, "discarded result is never sent")
    }

    // MARK: Session

    @MainActor
    func testSessionAggregatesAndInvariants() async throws {
        let sink = RecordingEventSink()
        let journal = makeJournal(sink: sink)
        clock.date = Fixtures.pairedAt.addingTimeInterval(0.7)   // fractions are dropped
        await journal.startSession()
        XCTAssertTrue(journal.isObserving)
        XCTAssertEqual(system.log.count("start"), 1)

        clock.date = Fixtures.pairedAt.addingTimeInterval(10)
        await emit(MotionActivityReading(walking: true), to: journal)
        clock.date = Fixtures.pairedAt.addingTimeInterval(70.9)
        await emit(MotionActivityReading(stationary: true), to: journal)
        clock.date = Fixtures.pairedAt.addingTimeInterval(100)
        await journal.finishSession()

        XCTAssertFalse(system.isUpdating, "finishing stops Motion updates")
        let session = try XCTUnwrap(journal.session)
        XCTAssertEqual(session.phase, .awaitingConfirmation)
        let summary = try XCTUnwrap(session.summary)
        XCTAssertEqual(summary.durationSeconds, 100)
        XCTAssertEqual(summary.seconds, ActivitySeconds(stationary: 30, walking: 60, unknown: 10))
        XCTAssertEqual(summary.dominantActivity, .walking)
        XCTAssertEqual(summary.seconds.total, summary.durationSeconds)
        XCTAssertTrue(summary.isValid)
        XCTAssertTrue(sink.attempts.isEmpty, "preview creates nothing")

        await journal.confirmSession()
        let event = try XCTUnwrap(sink.events.first)
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ContextEventType.activitySession.payloadKeys)
        XCTAssertEqual(payload.count, 12)
        XCTAssertEqual(payload["session_id"] as? String, summary.sessionID.uuidString.lowercased())
        XCTAssertEqual(try ContextFixtures.json(event)["session_id"] as? String, summary.sessionID.uuidString.lowercased())
        XCTAssertEqual(payload["started_at"] as? String, "2026-09-21T14:13:20Z")
        XCTAssertEqual(payload["completed_at"] as? String, "2026-09-21T14:15:00Z")
        XCTAssertEqual(payload["duration_seconds"] as? Int, 100)
        XCTAssertEqual(payload["dominant_activity"] as? String, "walking")
        XCTAssertEqual(payload["walking_seconds"] as? Int, 60)
        XCTAssertEqual(payload["stationary_seconds"] as? Int, 30)
        XCTAssertEqual(payload["unknown_seconds"] as? Int, 10)
        XCTAssertEqual(payload["running_seconds"] as? Int, 0)
        XCTAssertEqual(payload["interrupted"] as? Bool, false)
        XCTAssertNil(journal.session)
        XCTAssertEqual(journal.history.first?.kind, .session)
    }

    func testSummaryInvariantsRejectInconsistentValues() throws {
        let start = Fixtures.pairedAt
        let valid = ActivitySessionSummary(sessionID: UUID(), startedAt: start, completedAt: start.addingTimeInterval(10),
                                           seconds: ActivitySeconds(walking: 10), interrupted: false)
        XCTAssertTrue(valid.isValid)
        let tooMuch = ActivitySessionSummary(sessionID: UUID(), startedAt: start, completedAt: start.addingTimeInterval(10),
                                             seconds: ActivitySeconds(walking: 12), interrupted: false)
        XCTAssertFalse(tooMuch.isValid, "sum above duration + 1 s tolerance")
        XCTAssertThrowsError(try tooMuch.makeEvent(eventID: UUID()))
        let withinTolerance = ActivitySessionSummary(sessionID: UUID(), startedAt: start, completedAt: start.addingTimeInterval(10),
                                                     seconds: ActivitySeconds(walking: 11), interrupted: false)
        XCTAssertTrue(withinTolerance.isValid)
        let negative = ActivitySessionSummary(sessionID: UUID(), startedAt: start, completedAt: start.addingTimeInterval(10),
                                              seconds: ActivitySeconds(walking: 12, unknown: -2), interrupted: false)
        XCTAssertFalse(negative.isValid)
        let backwards = ActivitySessionSummary(sessionID: UUID(), startedAt: start, completedAt: start.addingTimeInterval(-5),
                                               seconds: ActivitySeconds(), interrupted: false)
        XCTAssertEqual(backwards.durationSeconds, 0)
        XCTAssertFalse(backwards.isValid)
        XCTAssertEqual(ActivitySeconds().dominant, .unknown, "zero duration")
        XCTAssertEqual(ActivitySeconds(stationary: 5, walking: 5).dominant, .walking, "tie → priority")
        XCTAssertEqual(ActivitySeconds(walking: 5, unknown: 9).dominant, .unknown, "unobserved time can dominate honestly")
    }

    func testClockGoingBackwardsNeverBreaksTheSum() {
        var session = ActivitySession(startedAt: Fixtures.pairedAt)
        session.observe(.walking, at: Fixtures.pairedAt.addingTimeInterval(20))
        session.observe(.running, at: Fixtures.pairedAt.addingTimeInterval(5))   // clock moved back
        let summary = session.finish(at: Fixtures.pairedAt.addingTimeInterval(30), eventID: UUID())
        XCTAssertEqual(summary?.durationSeconds, 30)
        XCTAssertEqual(summary?.seconds.total, 30)
        XCTAssertEqual(summary?.seconds.running, 10)
    }

    @MainActor
    func testBackgroundTimeIsUnknownAndUpdatesStop() async throws {
        let journal = makeJournal(sink: RecordingEventSink())
        await journal.startSession()
        clock.advance(10)
        await emit(MotionActivityReading(walking: true), to: journal)
        clock.advance(40)
        await journal.appDidEnterBackground()
        XCTAssertFalse(journal.isObserving)
        XCTAssertFalse(system.isUpdating, "no updates in the background")
        system.emit(MotionActivityReading(running: true))   // a late reading is ignored
        clock.advance(30)
        await journal.appDidBecomeActive()
        XCTAssertTrue(journal.isObserving)
        clock.advance(10)
        await emit(MotionActivityReading(cycling: true), to: journal)
        clock.advance(10)
        await journal.finishSession()

        let summary = try XCTUnwrap(journal.session?.summary)
        XCTAssertEqual(summary.durationSeconds, 100)
        XCTAssertEqual(summary.seconds, ActivitySeconds(walking: 40, cycling: 10, unknown: 50))
        XCTAssertEqual(summary.seconds.running, 0)
        XCTAssertFalse(summary.interrupted, "background is not an interruption")
    }

    @MainActor
    func testDoubleFinishAndDoubleConfirmCreateOneEvent() async throws {
        let sink = RecordingEventSink()
        let journal = makeJournal(sink: sink)
        await journal.startSession()
        clock.advance(30)
        await journal.finishSession()
        let first = try XCTUnwrap(journal.session?.summary)
        let firstEventID = journal.session?.eventID
        clock.advance(30)
        await journal.finishSession()
        XCTAssertEqual(journal.session?.summary, first, "second «Завершить» changes nothing")
        XCTAssertEqual(journal.session?.eventID, firstEventID)

        async let one: Void = journal.confirmSession()
        async let two: Void = journal.confirmSession()
        _ = await (one, two)
        await journal.confirmSession()
        XCTAssertEqual(sink.attempts.count, 1)
        XCTAssertEqual(sink.events.first?.eventID, firstEventID)
    }

    @MainActor
    func testInterruptedAfterRelaunchCanBeCompleted() async throws {
        let sink = RecordingEventSink()
        let first = makeJournal(sink: sink)
        await first.startSession()
        clock.advance(20)
        await emit(MotionActivityReading(running: true), to: first)
        clock.advance(25)
        await emit(MotionActivityReading(walking: true), to: first)
        // The process ends here (no background callback); 100 s later the app starts again.
        clock.advance(100)
        let relaunched = makeJournal(sink: sink)
        let restored = try XCTUnwrap(relaunched.session)
        XCTAssertEqual(restored.phase, .interrupted)
        XCTAssertFalse(relaunched.isObserving, "an interrupted session is never observed again")
        await relaunched.appDidBecomeActive()
        XCTAssertEqual(system.log.count("start"), 1, "only the first launch observed")

        await relaunched.finishSession()
        let summary = try XCTUnwrap(relaunched.session?.summary)
        XCTAssertTrue(summary.interrupted)
        XCTAssertEqual(summary.completedAt, Fixtures.pairedAt.addingTimeInterval(45), "last checkpoint, not the relaunch time")
        XCTAssertEqual(summary.seconds, ActivitySeconds(running: 25, unknown: 20))
        await relaunched.confirmSession()
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.first))["interrupted"] as? Bool, true)
    }

    @MainActor
    func testInterruptedOrPendingSessionCanBeDeletedWithoutEvent() async {
        let sink = RecordingEventSink()
        let first = makeJournal(sink: sink)
        await first.startSession()
        clock.advance(10)
        let relaunched = makeJournal(sink: sink)
        XCTAssertEqual(relaunched.session?.phase, .interrupted)
        await relaunched.deleteSession()
        XCTAssertNil(relaunched.session)
        XCTAssertNil(makeJournal(sink: sink).session, "deletion is persisted")

        let pending = makeJournal(sink: sink)
        await pending.startSession()
        clock.advance(10)
        await pending.finishSession()
        await pending.deleteSession()
        XCTAssertNil(pending.session)
        XCTAssertTrue(sink.attempts.isEmpty, "deleting never sends anything")
    }

    @MainActor
    func testPendingConfirmationSurvivesRelaunchWithSameEventID() async throws {
        let sink = RecordingEventSink()
        sink.outcome = .failed
        let first = makeJournal(sink: sink)
        await first.startSession()
        clock.advance(15)
        await first.finishSession()
        await first.confirmSession()
        XCTAssertEqual(first.sessionFailure, .saveFailed)
        let eventID = try XCTUnwrap(first.session?.eventID)

        sink.outcome = .saved
        let relaunched = makeJournal(sink: sink)
        XCTAssertEqual(relaunched.session?.phase, .awaitingConfirmation, "a frozen summary is not 'interrupted'")
        await relaunched.confirmSession()
        XCTAssertEqual(sink.events.map(\.eventID), [eventID])
    }

    // MARK: Offline / relaunch / exact-once with the real queue

    @MainActor
    func testOfflineRetryAndRelaunchDeliverSameEventOnce() async throws {
        let queueDirectory = ContextFixtures.temporaryDirectory("ActivityQueue")
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let journal = makeJournal()
        journal.sink = delivery

        await journal.startSession()
        clock.advance(60)
        await journal.finishSession()
        await journal.confirmSession()
        await delivery.waitForFlush()
        let pending = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(pending.count, 1, "offline: saved on disk, not lost")
        let eventID = try XCTUnwrap(pending.first?.eventID)

        // Relaunch: a new queue and coordinator over the same file deliver the same event_id.
        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        let sentIDs = api.sentBatches.flatMap { $0 }.map(\.eventID)
        XCTAssertTrue(sentIDs.allSatisfy { $0 == eventID })
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
        let state = await relaunched.localDeliveryState(of: eventID)
        XCTAssertEqual(state, .delivered)

        let batchesBefore = api.batchCalls
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        XCTAssertEqual(api.batchCalls, batchesBefore, "nothing is sent again after acknowledgement")
    }

    // MARK: Privacy and storage

    @MainActor
    func testNoRawSamplesOrTimeSeriesAreStoredOrSent() async throws {
        let sink = RecordingEventSink()
        let journal = makeJournal(sink: sink)
        await journal.startSession()
        for (index, reading) in [MotionActivityReading(walking: true), MotionActivityReading(running: true),
                                 MotionActivityReading(walking: true), MotionActivityReading(cycling: true)].enumerated() {
            clock.advance(Double(10 + index))
            await emit(reading, to: journal)
        }
        let file = try fileText()
        for forbidden in ["confidence\":\"high", "samples", "timestamp", "startDate", "latitude", "longitude", "token"] {
            XCTAssertFalse(file.contains(forbidden), forbidden)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "session", "history"])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys), ["session_id", "started_at", "phase", "interrupted", "current_activity",
                                           "segment_started_at", "seconds"],
                       "only aggregates and the last checkpoint — no series of readings")

        clock.advance(5)
        await journal.finishSession()
        await journal.confirmSession()
        let text = try ContextFixtures.text(XCTUnwrap(sink.events.first))
        for forbidden in ["samples", "timestamp", "latitude", "longitude", "segment", "current_activity", "confidence"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    @MainActor
    func testCorruptOrFutureJournalIsQuarantinedWithoutCrash() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ActivityJournalFile.fileName)
        try Data("{not json".utf8).write(to: url)
        let journal = makeJournal()
        XCTAssertEqual(journal.storageIssue, .quarantined)
        XCTAssertNil(journal.session)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("activity-journal.corrupt-") })

        try Data(#"{"version":99,"history":[]}"#.utf8).write(to: url)
        XCTAssertEqual(makeJournal().storageIssue, .quarantined, "unknown version is not guessed")
    }
}
