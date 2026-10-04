import XCTest

final class MockNFCTagSystem: NFCTagSystem, @unchecked Sendable {
    let log = CallLog()
    var currentStatus: CoreNFCStatus = .requiresEntitlement
    var readResult: Result<NFCReadResult, NFCTagError> = .success(.empty)
    var writeError: NFCTagError?
    private let lock = NSLock()
    private var _written: [URL] = []

    var written: [URL] { lock.lock(); defer { lock.unlock() }; return _written }

    func status() async -> CoreNFCStatus { currentStatus }

    func readActionLink() async throws -> NFCReadResult {
        log.hit("read")
        return try readResult.get()
    }

    func writeActionLink(_ url: URL) async throws {
        log.hit("write")
        if let writeError { throw writeError }
        lock.lock(); _written.append(url); lock.unlock()
    }
}

/// V3-003: NFC actions — Shortcuts link preview, confirm/decline once, gated Core NFC, no tag data.
final class NFCActionTests: XCTestCase {
    private var directory: URL!
    private var clock: TestClock!
    private var tags: MockNFCTagSystem!

    private let actionID = ActionDraftFixtures.actionID
    private var actionText: String { actionID.uuidString.lowercased() }

    override func setUp() {
        super.setUp()
        directory = ContextFixtures.temporaryDirectory("NFC")
        clock = TestClock()
        tags = MockNFCTagSystem()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor
    private func makeNFC(sink: RecordingEventSink? = nil) -> NFCActionCoordinator {
        let clock = self.clock!
        return NFCActionCoordinator(store: VersionedJSONFileStore(directoryURL: directory, fileName: NFCActionsFile.fileName),
                                    tags: tags, sink: sink, now: { clock.now() })
    }

    @MainActor
    private func registered(sink: RecordingEventSink? = nil) async -> NFCActionCoordinator {
        let nfc = makeNFC(sink: sink)
        let result = await nfc.performActionDraft(ActionDraftFixtures.nfcDraft())
        XCTAssertEqual(result, .completed(resultRef: actionID))
        return nfc
    }

    // MARK: URL v3 nfc_action

    func testNFCActionLinkCarriesOnlyTheOpaqueID() throws {
        let link = "katana-connector://open?v=3&feature=nfc_action&action_id=\(actionText)"
        XCTAssertEqual(try ConnectorURLRouter.parse(link), .openDestination(.nfcAction(actionID)))
        XCTAssertEqual(ConnectorURLRouter.url(for: .nfcAction(actionID)).absoluteString, link)
        for (text, error) in [("katana-connector://open?v=3&feature=nfc_action", ConnectorURLError.missingActionID),
                              ("katana-connector://open?v=3&feature=nfc_action&action_id=42", .invalidActionID),
                              ("\(link)&action_id=\(actionText)", .duplicateParameter),
                              ("\(link)&draft_id=\(actionText)", .unknownParameter),
                              ("\(link)&command=unlock", .unknownParameter),
                              ("\(link)&uid=04A224", .unknownParameter),
                              ("\(link)&label=door", .unknownParameter)] {
            XCTAssertThrowsError(try ConnectorURLRouter.parse(text), text) { XCTAssertEqual($0 as? ConnectorURLError, error, text) }
        }
    }

    @MainActor
    func testLinkOnlyOpensPreviewAndCreatesNoEvent() async {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink)
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.handle(ConnectorURLRouter.url(for: .nfcAction(actionID))))
        XCTAssertEqual(navigator.path, [.nfcActions, .nfcActionPreview(actionID)])
        nfc.open(actionID: actionID, source: .shortcut)   // what the preview screen does on appear
        guard case .ready(let run)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        XCTAssertEqual(run.source, .shortcut)
        XCTAssertTrue(sink.attempts.isEmpty, "opening never executes")
        XCTAssertEqual(tags.log.count("read") + tags.log.count("write"), 0)
    }

    // MARK: Preview / confirm

    @MainActor
    func testConfirmCreatesExactlyOneEventWithExactPayload() async throws {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink)
        nfc.open(actionID: actionID, source: .shortcut)
        guard case .ready(let run)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        clock.advance(3.4)
        async let one: Void = nfc.decide(actionID: actionID, result: .confirmed)
        async let two: Void = nfc.decide(actionID: actionID, result: .confirmed)
        _ = await (one, two)
        await nfc.decide(actionID: actionID, result: .declined)
        XCTAssertEqual(sink.events.count, 1)

        let event = try XCTUnwrap(sink.events.first)
        let json = try ContextFixtures.json(event)
        XCTAssertEqual(json["type"] as? String, "nfc.action.completed")
        XCTAssertEqual(json["session_id"] as? String, run.executionID.uuidString.lowercased())
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:23Z")
        let payload = try ContextFixtures.payload(event)
        XCTAssertEqual(Set(payload.keys), ["action_id", "execution_id", "source", "confirmed_at", "result", "interrupted"])
        XCTAssertEqual(payload["action_id"] as? String, actionText)
        XCTAssertEqual(payload["source"] as? String, "shortcut")
        XCTAssertEqual(payload["result"] as? String, "confirmed")
        XCTAssertEqual(payload["interrupted"] as? Bool, false)
        guard case .done(let execution)? = nfc.previews[actionID] else { return XCTFail("expected done") }
        XCTAssertEqual(execution.eventID, event.eventID)
    }

    @MainActor
    func testDeclineIsAnExplicitResultAndLeavingCreatesNothing() async throws {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink)
        nfc.open(actionID: actionID, source: .shortcut)
        // Leaving the screen does nothing; reopening shows the same run.
        nfc.open(actionID: actionID, source: .shortcut)
        XCTAssertTrue(sink.attempts.isEmpty)
        await nfc.decide(actionID: actionID, result: .declined)
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.first))["result"] as? String, "declined")
        XCTAssertEqual(NFCActionResult.allCases.map(\.rawValue), ["confirmed", "declined"])
        XCTAssertEqual(NFCActionSource.allCases.map(\.rawValue), ["shortcut", "core_nfc"])
    }

    @MainActor
    func testDuplicateTriggerReusesRunWithinWindow() async {
        let nfc = await registered()
        nfc.open(actionID: actionID, source: .shortcut)
        guard case .ready(let first)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        clock.advance(100)
        nfc.open(actionID: actionID, source: .shortcut)
        guard case .ready(let second)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        XCTAssertEqual(first.executionID, second.executionID, "a second tap within 120 s is the same run")
        clock.advance(121)
        nfc.open(actionID: actionID, source: .shortcut)
        guard case .ready(let third)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        XCTAssertNotEqual(first.executionID, third.executionID)
        XCTAssertEqual(nfc.pending.count, 1, "the stale run is dropped, not sent")
    }

    @MainActor
    func testDisabledExpiredAndUnknownAreExplicit() async {
        let sink = RecordingEventSink()
        let nfc = await registered(sink: sink)
        let unknown = UUID()
        nfc.open(actionID: unknown, source: .shortcut)
        XCTAssertEqual(nfc.previews[unknown], .unknown)

        nfc.setEnabled(false, actionID: actionID)
        nfc.open(actionID: actionID, source: .shortcut)
        XCTAssertEqual(nfc.previews[actionID], .disabled)
        await nfc.decide(actionID: actionID, result: .confirmed)

        nfc.setEnabled(true, actionID: actionID)
        clock.advance(NFCActionRegistration.lifetime + 1)
        nfc.open(actionID: actionID, source: .shortcut)
        XCTAssertEqual(nfc.previews[actionID], .expired)
        await nfc.decide(actionID: actionID, result: .confirmed)
        XCTAssertTrue(sink.attempts.isEmpty)
    }

    @MainActor
    func testRelaunchRestoresPendingRunAsInterrupted() async throws {
        let sink = RecordingEventSink()
        let first = await registered(sink: sink)
        first.open(actionID: actionID, source: .shortcut)
        guard case .ready(let run)? = first.previews[actionID] else { return XCTFail("expected ready") }

        clock.advance(300)
        let relaunched = makeNFC(sink: sink)
        XCTAssertEqual(relaunched.pending.first?.executionID, run.executionID)
        relaunched.open(actionID: actionID, source: .shortcut)
        await relaunched.decide(actionID: actionID, result: .confirmed)
        let payload = try ContextFixtures.payload(XCTUnwrap(sink.events.first))
        XCTAssertEqual(payload["interrupted"] as? Bool, true)
        XCTAssertEqual(payload["execution_id"] as? String, run.executionID.uuidString.lowercased())

        relaunched.open(actionID: actionID, source: .shortcut)
        clock.advance(NFCPendingExecution.maxAge + 1)
        XCTAssertTrue(makeNFC().pending.isEmpty, "stale runs are dropped on launch without an event")
        XCTAssertEqual(sink.events.count, 1)
    }

    @MainActor
    func testUnsavedEventRetriesWithSameID() async throws {
        let sink = RecordingEventSink()
        sink.outcome = .failed
        let nfc = await registered(sink: sink)
        nfc.open(actionID: actionID, source: .shortcut)
        await nfc.decide(actionID: actionID, result: .confirmed)
        let eventID = try XCTUnwrap(nfc.executions.first?.eventID)
        sink.outcome = .saved
        let relaunched = makeNFC(sink: sink)
        await relaunched.retryPendingEvents()
        await relaunched.retryPendingEvents()
        XCTAssertEqual(sink.events.map(\.eventID), [eventID])
    }

    // MARK: Registration through an action draft

    @MainActor
    func testDraftRegistersOnceAndAcceptedEventReferencesAction() async throws {
        let sink = RecordingEventSink()
        let nfc = makeNFC(sink: sink)
        let drafts = ActionDraftCoordinator(store: VersionedJSONFileStore(directoryURL: directory.appendingPathComponent("Drafts"),
                                                                          fileName: ActionDraftStoreFile.fileName),
                                            fetcher: MockActionDraftFetcher(result: .success(ActionDraftFixtures.nfcDraft())),
                                            sink: sink, now: { Fixtures.pairedAt })
        drafts.register(nfc, for: .nfcAction)
        await drafts.loadDraft(ActionDraftFixtures.draftID)
        await drafts.perform(ActionDraftFixtures.draftID)
        XCTAssertEqual(nfc.registrations.map(\.actionID), [actionID])
        XCTAssertEqual(nfc.registrations.first?.label, "Открыть дверь")
        XCTAssertEqual(sink.events.map(\.type), ["action_draft.accepted"])
        XCTAssertEqual(try ContextFixtures.payload(XCTUnwrap(sink.events.first))["result_ref"] as? String, actionText)
        let again = await nfc.performActionDraft(ActionDraftFixtures.nfcDraft())
        XCTAssertEqual(again, .completed(resultRef: actionID))
        XCTAssertEqual(nfc.registrations.count, 1)
    }

    // MARK: Native Core NFC (gated)

    @MainActor
    func testCoreNFCIsGatedWithoutEntitlement() async throws {
        XCTAssertFalse(CoreNFCAvailability.entitlementConfigured, "this build is not provisioned for Core NFC (D-046)")
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        XCTAssertFalse(project.contains("NFCReaderUsageDescription"))
        XCTAssertFalse(project.contains("nfc.readersession"))
        let adapter = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/Features/NFCActions/SystemNFCTagAccess.swift"))
        XCTAssertTrue(adapter.contains("CoreNFCAvailability.entitlementConfigured"))
        XCTAssertFalse(adapter.contains("writeLock"), "Connector never locks a tag")
        XCTAssertFalse(adapter.contains("identifier"), "the tag UID is never read")

        let nfc = await registered()
        await nfc.scanTag()
        await nfc.writeTag(actionID: actionID)
        XCTAssertEqual(nfc.coreNFCStatus, .requiresEntitlement)
        XCTAssertEqual(tags.log.count("read") + tags.log.count("write"), 0, "no Core NFC session without the entitlement")
        XCTAssertEqual(nfc.scanState, .idle)
    }

    @MainActor
    func testCoreNFCWhenAvailableReadsOnlyKatanaLinksAndWritesTheOpaqueLink() async {
        tags.currentStatus = .available
        let nfc = await registered()
        tags.readResult = .success(.actionLink(ConnectorURLRouter.url(for: .nfcAction(actionID))))
        await nfc.scanTag()
        XCTAssertEqual(nfc.scanState, .found(actionID))
        guard case .ready(let run)? = nfc.previews[actionID] else { return XCTFail("expected ready") }
        XCTAssertEqual(run.source, .coreNFC)

        tags.readResult = .success(.actionLink(URL(string: "katana-connector://open?v=1&feature=pairing")!))
        await nfc.scanTag()
        XCTAssertEqual(nfc.scanState, .notKatana)
        tags.readResult = .success(.notKatana)
        await nfc.scanTag()
        XCTAssertEqual(nfc.scanState, .notKatana)
        tags.readResult = .failure(.cancelled)
        await nfc.scanTag()
        XCTAssertEqual(nfc.scanState, .cancelled, "closing the system sheet is a normal state")

        await nfc.writeTag(actionID: actionID)
        XCTAssertEqual(nfc.scanState, .written)
        XCTAssertEqual(tags.written, [ConnectorURLRouter.url(for: .nfcAction(actionID))])
        for error in [NFCTagError.readOnly, .unsupportedTag, .tooSmall] {
            tags.writeError = error
            await nfc.writeTag(actionID: actionID)
            XCTAssertEqual(nfc.scanState, .failed(error))
        }
        nfc.setEnabled(false, actionID: actionID)
        let writesBefore = tags.log.count("write")
        await nfc.writeTag(actionID: actionID)
        XCTAssertEqual(tags.log.count("write"), writesBefore, "disabled actions are not written")
    }

    // MARK: Storage and privacy

    @MainActor
    func testStoredFileAndEventsHoldNoTagData() async throws {
        let sink = RecordingEventSink()
        tags.currentStatus = .available
        let nfc = await registered(sink: sink)
        tags.readResult = .success(.actionLink(ConnectorURLRouter.url(for: .nfcAction(actionID))))
        await nfc.scanTag()
        await nfc.decide(actionID: actionID, result: .confirmed)

        let url = directory.appendingPathComponent(NFCActionsFile.fileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "registrations", "pending", "executions"])
        let registration = try XCTUnwrap((json["registrations"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(registration.keys), ["action_id", "label", "created_at", "expires_at", "enabled", "source_draft_id"])
        let texts = [String(decoding: try Data(contentsOf: url), as: UTF8.self)] + (try sink.events.map(ContextFixtures.text))
        for text in texts {
            for forbidden in ["uid", "ndef", "katana-connector://", "serial", "identifier\"", "token"] {
                XCTAssertFalse(text.lowercased().contains(forbidden), forbidden)
            }
        }
        XCTAssertFalse(try ContextFixtures.text(XCTUnwrap(sink.events.first)).contains("Открыть"), "no label in the event")

        XCTAssertEqual(NFCActionsFile.fileName, "nfc-actions.json")
        XCTAssertEqual(NFCActionsFile.currentVersion, 1)
        let path = NFCActionsFile.applicationSupportStore().fileURL.standardizedFileURL.path
        XCTAssertTrue(path.hasSuffix("/Application Support/KatanaConnector/NFCActions/nfc-actions.json"), path)
        try Data(#"{"version":7}"#.utf8).write(to: url)
        XCTAssertEqual(makeNFC().storageIssue, .quarantined)
    }
}
