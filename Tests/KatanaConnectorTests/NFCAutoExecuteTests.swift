import XCTest

/// V3-009 (D-055): local opt-in «Выполнять сразу после открытия» for NFC actions.
final class NFCAutoExecuteTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!
    private let actionID = ActionDraftFixtures.actionID

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("NFCAuto")
        clock = TestClock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent(NFCActionsFile.fileName) }

    @MainActor
    private func makeNFC(sink: (any ConnectorEventSink)? = nil) -> NFCActionCoordinator {
        let clock = self.clock!
        return NFCActionCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: NFCActionsFile.fileName),
                                    tags: MockNFCTagSystem(), sink: sink, now: { clock.now() })
    }

    @MainActor
    private func registered(sink: (any ConnectorEventSink)? = nil, autoExecute: Bool) async -> NFCActionCoordinator {
        let nfc = makeNFC(sink: sink)
        _ = await nfc.performActionDraft(ActionDraftFixtures.nfcDraft())
        if autoExecute { nfc.setAutoExecute(true, actionID: actionID) }
        return nfc
    }

    // MARK: Default off and backward-compatible decoding

    @MainActor
    func testDefaultIsOffAndALinkOnlyOpensThePreview() async throws {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink, autoExecute: false)
        XCTAssertEqual(nfc.registration(for: actionID)?.autoExecute, false, "new registrations start off")
        await nfc.openFromLink(actionID: actionID, source: .shortcut)
        guard case .ready? = nfc.previews[actionID] else { return XCTFail("expected the preview") }
        XCTAssertTrue(sink.attempts.isEmpty, "without the opt-in nothing runs")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let registration = try XCTUnwrap((json["registrations"] as? [[String: Any]])?.first)
        XCTAssertEqual(registration["auto_execute"] as? Bool, false)
    }

    @MainActor
    func testFilesWithoutTheNewKeysLoadAsOff() async throws {
        // Exactly what v0.3 builds before D-055 wrote: no auto_execute, opened_at, auto_executed.
        let id = actionID.uuidString.lowercased()
        let legacy = """
        {"version":1,"registrations":[{"action_id":"\(id)","label":"Коту воду заменили","created_at":"2026-09-21T14:13:20Z",\
        "expires_at":"2027-09-21T14:13:20Z","enabled":true,"source_draft_id":"\(ActionDraftFixtures.draftText)"}],\
        "pending":[],"executions":[{"execution_id":"00000000-0000-4000-8000-000000000301","action_id":"\(id)",\
        "event_id":"00000000-0000-4000-8000-000000000302","source":"shortcut","confirmed_at":"2026-09-21T14:13:20Z",\
        "result":"confirmed","interrupted":false,"event_saved":true}]}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: fileURL)

        let nfc = makeNFC()
        XCTAssertNil(nfc.storageIssue, "no quarantine for an older file")
        XCTAssertEqual(nfc.registrations.count, 1)
        XCTAssertEqual(nfc.registration(for: actionID)?.autoExecute, false)
        XCTAssertEqual(nfc.registration(for: actionID)?.label, "Коту воду заменили")
        XCTAssertEqual(nfc.executions.first?.autoExecuted, false)
        XCTAssertNil(nfc.executions.first?.openedAt)
        XCTAssertEqual(NFCActionsFile.currentVersion, 1, "additive change, no version bump")

        nfc.setAutoExecute(true, actionID: actionID)
        XCTAssertEqual(makeNFC().registration(for: actionID)?.autoExecute, true, "the opt-in is persisted")
        nfc.setAutoExecute(false, actionID: actionID)
        XCTAssertEqual(makeNFC().registration(for: actionID)?.autoExecute, false)
    }

    // MARK: Auto-confirm

    @MainActor
    func testOptInRunsExactlyOneEventWithTheUnchangedWireFormat() async throws {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink, autoExecute: true)
        clock.advance(1.2)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)

        XCTAssertEqual(sink.events.count, 1, "no «Выполнить» needed")
        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.type, "nfc.action.completed")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ContextEventType.nfcActionCompleted.payloadKeys, "wire contract unchanged")
        XCTAssertEqual(payload["result"] as? String, "confirmed")
        XCTAssertEqual(payload["source"] as? String, "shortcut")
        XCTAssertEqual(payload["interrupted"] as? Bool, false)
        let text = try ContextFixtures.text(event)
        for forbidden in ["auto", "opened_at", "Открыть дверь"] {
            XCTAssertFalse(text.contains(forbidden), "\(forbidden) never reaches Katana")
        }
        guard case .done(let execution)? = nfc.previews[actionID] else { return XCTFail("expected done") }
        XCTAssertTrue(execution.autoExecuted)
        XCTAssertEqual(execution.eventID, event.eventID)
        XCTAssertTrue(nfc.pending.isEmpty)
    }

    @MainActor
    func testUnknownDisabledAndExpiredAreNeverRun() async {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink, autoExecute: true)
        let unknown = UUID()
        await nfc.openFromLink(actionID: unknown, source: .shortcut)
        XCTAssertEqual(nfc.previews[unknown], .unknown)

        nfc.setEnabled(false, actionID: actionID)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)
        XCTAssertEqual(nfc.previews[actionID], .disabled)

        nfc.setEnabled(true, actionID: actionID)
        clock.advance(NFCActionRegistration.lifetime + 1)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)
        XCTAssertEqual(nfc.previews[actionID], .expired)
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    @MainActor
    func testTurningItOffRestoresTheManualPreview() async {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink, autoExecute: true)
        nfc.setAutoExecute(false, actionID: actionID)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)
        guard case .ready? = nfc.previews[actionID] else { return XCTFail("expected the preview") }
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    // MARK: Exact-once

    @MainActor
    func testRepeatedAndConcurrentOpensRunOncePerWindow() async throws {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink, autoExecute: true)
        async let one: Void = nfc.openFromLink(actionID: actionID, source: .shortcut)
        async let two: Void = nfc.openFromLink(actionID: actionID, source: .shortcut)
        _ = await (one, two)
        clock.advance(60)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)   // the same tag again within the window
        await nfc.decide(actionID: actionID, result: .confirmed)        // a stray tap on a stale button
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(Set(sink.attempts.map(\.eventID)).count, 1)

        clock.advance(NFCPendingExecution.reuseWindow + 1)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)   // a new touch later: a new run
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertNotEqual(sink.events[0].sessionID, sink.events[1].sessionID, "a new execution_id per run")
    }

    @MainActor
    func testRestoredPendingRunIsExecutedOnceAsInterrupted() async throws {
        let sink = RecordingEventSink()
        let first = await registered(sink: sink, autoExecute: false)
        first.open(actionID: actionID, source: .shortcut)      // preview left open, app killed
        first.setAutoExecute(true, actionID: actionID)
        clock.advance(30)
        let relaunched = makeNFC(sink: sink)
        await relaunched.openFromLink(actionID: actionID, source: .shortcut)
        await relaunched.openFromLink(actionID: actionID, source: .shortcut)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.first))["interrupted"] as? Bool, true)
    }

    @MainActor
    func testOfflineQueueRelaunchDeliversTheAutomaticEventOnce() async throws {
        let queueDirectory = ContextFixtures.temporaryDirectory("NFCAutoQueue")
        defer { try? FileManager.default.removeItem(at: queueDirectory) }
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let nfc = await registered(sink: delivery, autoExecute: true)
        await nfc.openFromLink(actionID: actionID, source: .shortcut)
        await delivery.waitForFlush()
        let queued = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(queued.map(\.type), ["nfc.action.completed"], "enqueued before any send, kept offline")

        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        let reopened = makeNFC(sink: relaunched)
        await reopened.openFromLink(actionID: actionID, source: .shortcut)   // reopened within the window
        await reopened.retryPendingEvents()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        XCTAssertEqual(Set(api.sentBatches.flatMap { $0 }.map(\.eventID)), [try XCTUnwrap(queued.first?.eventID)])
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Nothing outside Connector can switch it on

    func testNoLinkOrDraftCanEnableIt() {
        let id = actionID.uuidString.lowercased()
        for extra in ["&auto=1", "&auto_execute=true", "&execute=1", "&confirm=1"] {
            XCTAssertThrowsError(try ConnectorURLRouter.parse("katana-connector://open?v=3&feature=nfc_action&action_id=\(id)\(extra)"),
                                 extra)
        }
        XCTAssertEqual(ActionDraftParser.payloadKeys(.nfcAction), ["action_id", "label"], "drafts cannot carry the opt-in")
        XCTAssertFalse(ContextEventType.allCases.contains { $0.payloadKeys.contains("auto_execute") })
    }
}
