import CryptoKit
import XCTest

/// V3-008 (D-054): the HTTPS bridge for permanent NFC tags only hands over the existing v3 link;
/// Connector keeps preview, explicit confirmation, exact-once delivery and the privacy allowlist.
final class NFCBridgeTests: XCTestCase {
    private var root: URL!
    private let label = "Коту воду заменили"
    private let actionID = ActionDraftFixtures.actionID

    override func setUp() {
        super.setUp()
        root = ContextFixtures.temporaryDirectory("NFCBridge")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func bridgePage() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("docs/nfc-bridge-reference.html"))
    }

    /// What the bridge page links to for `actionID` (as the browser sees the `href`).
    private func bridgeTarget(_ page: String, actionID: UUID) throws -> URL {
        let start = try XCTUnwrap(page.range(of: "href=\""))
        let rest = page[start.upperBound...]
        let end = try XCTUnwrap(rest.firstIndex(of: "\""))
        let href = String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "{{ACTION_ID}}", with: actionID.uuidString.lowercased())
        return try XCTUnwrap(URL(string: href))
    }

    // MARK: Reference page

    func testBridgePageOnlyOpensTheExistingV3Link() throws {
        let page = try bridgePage()
        let target = try bridgeTarget(page, actionID: actionID)
        XCTAssertEqual(target, ConnectorURLRouter.url(for: .nfcAction(actionID)), "exactly the existing link")
        XCTAssertEqual(try ConnectorURLRouter.parse(target), .openDestination(.nfcAction(actionID)))
        XCTAssertEqual(page.components(separatedBy: "{{ACTION_ID}}").count - 1, 2, "the id appears only in the link (and its doc)")

        for forbidden in ["http://", "https://", "<img", "<iframe", "<link", "src=", "fetch(", "xmlhttprequest", "document.cookie",
                          "localstorage", "uid=", "tag_uid", "ndef", "gtag", "sendbeacon", "token"] {
            XCTAssertFalse(page.lowercased().replacingOccurrences(of: "katana-connector://", with: "").contains(forbidden),
                           "no \(forbidden) on the bridge page")
        }
        XCTAssertTrue(page.contains(#"<meta name="referrer" content="no-referrer">"#))
        XCTAssertTrue(page.contains(#"<meta name="robots" content="noindex, nofollow">"#))
    }

    func testCSPHashMatchesTheInlineScript() throws {
        let page = try bridgePage()
        let scriptStart = try XCTUnwrap(page.range(of: "<script>"))
        let scriptEnd = try XCTUnwrap(page.range(of: "</script>"))
        let script = String(page[scriptStart.upperBound..<scriptEnd.lowerBound])
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        XCTAssertTrue(page.contains("script-src 'sha256-\(hash)'"), "the CSP in the reference allows exactly this script")
        XCTAssertTrue(script.contains("window.location.replace"))
        XCTAssertTrue(script.contains("^katana-connector:\\/\\/open\\?v=3&feature=nfc_action&action_id=[0-9a-f-]{36}$"),
                      "the script follows only a well-formed v3 NFC link")
    }

    func testOnlyTheCustomSchemeIsHandledAndExtrasAreRejected() {
        let id = actionID.uuidString.lowercased()
        // The HTTPS address on the tag is for Safari; Connector itself never acts on it.
        XCTAssertThrowsError(try ConnectorURLRouter.parse("https://katana.example/c/nfc/\(id)"))
        for smuggled in ["&uid=04A2245A1B6E80", "&ndef=AQID", "&label=Коту", "&text=x", "&execute=1"] {
            XCTAssertThrowsError(try ConnectorURLRouter.parse("katana-connector://open?v=3&feature=nfc_action&action_id=\(id)\(smuggled)"),
                                 smuggled)
        }
        XCTAssertThrowsError(try ConnectorURLRouter.parse("katana-connector://open?v=3&feature=nfc_action&action_id=\(id.uppercased())x"))
    }

    // MARK: First E2E: «Коту воду заменили»

    @MainActor
    private func makeNFC(sink: (any ConnectorEventSink)?) -> NFCActionCoordinator {
        NFCActionCoordinator(store: VersionedJSONFileStore(directoryURL: root.appendingPathComponent("NFC"), fileName: NFCActionsFile.fileName),
                             tags: MockNFCTagSystem(), sink: sink, now: { Fixtures.pairedAt })
    }

    @MainActor
    func testTagTapShowsPreviewAndOnlyConfirmationSendsOneLabelFreeEvent() async throws {
        let queueDirectory = root.appendingPathComponent("Queue")
        let api = MockConnectorAPI()
        api.batchHandler = { _ in throw ConnectorAPIError.transport }   // offline at confirmation
        let (queue, delivery) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        let nfc = makeNFC(sink: delivery)
        let draft = ActionDraft(draftID: ActionDraftFixtures.draftID, serverTime: ActionDraftFixtures.serverDate,
                                expiresAt: ActionDraftFixtures.serverDate.addingTimeInterval(3600),
                                payload: .nfcAction(NFCActionDraftPayload(actionID: actionID, label: label)))
        _ = await nfc.performActionDraft(draft)
        XCTAssertEqual(nfc.registration(for: actionID)?.label, label)

        // Tag → Safari → bridge page → custom scheme → Connector.
        let target = try bridgeTarget(try bridgePage(), actionID: actionID)
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.handle(target))
        XCTAssertEqual(navigator.path, [.nfcActions, .nfcActionPreview(actionID)])
        nfc.open(actionID: actionID, source: .shortcut)
        nfc.open(actionID: actionID, source: .shortcut)   // a second tap: same run
        XCTAssertEqual(nfc.pending.count, 1)
        let before = try await queue.pendingCount()
        XCTAssertEqual(before, 0, "a tap alone sends nothing")

        await nfc.decide(actionID: actionID, result: .confirmed)
        await delivery.waitForFlush()
        let queued = try await queue.pendingEvents(scope: EventFixtures.scope)
        XCTAssertEqual(queued.map(\.type), ["nfc.action.completed"], "saved on disk while offline")
        let text = try ContextFixtures.text(XCTUnwrap(queued.first))
        for forbidden in [label, "Коту", "uid", "ndef", "https://", "/c/nfc/"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()), forbidden)
        }
        let payload = try ContextFixtures.payload(XCTUnwrap(queued.first))
        XCTAssertEqual(Set(payload.keys), ContextEventType.nfcActionCompleted.payloadKeys)
        XCTAssertEqual(payload["source"] as? String, "shortcut")
        XCTAssertEqual(payload["result"] as? String, "confirmed")

        // Relaunch online: the same event once.
        api.batchHandler = { events in MockConnectorAPI.results(events, .accepted) }
        let (relaunchedQueue, relaunched) = ContextFixtures.delivery(queueDirectory: queueDirectory, api: api)
        await relaunched.prepare()
        relaunched.requestFlush()
        await relaunched.waitForFlush()
        let sent = api.sentBatches.flatMap { $0 }.map(\.eventID)
        XCTAssertEqual(Set(sent), [try XCTUnwrap(queued.first?.eventID)])
        let remaining = try await relaunchedQueue.pendingCount()
        XCTAssertEqual(remaining, 0)
        let reopened = makeNFC(sink: relaunched)
        XCTAssertTrue(reopened.pending.isEmpty, "a decided run is not shown again")
    }

    func testBridgeNeedsNoNewEntitlementOrBuild() throws {
        let project = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"))
        for forbidden in ["associated-domains", "applinks:", "com.apple.developer.associated-domains", "CODE_SIGN_ENTITLEMENTS"] {
            XCTAssertFalse(project.contains(forbidden), "\(forbidden): no Universal Links (D-054)")
        }
        let plist = try Data(contentsOf: repositoryRoot.appendingPathComponent("Config/KatanaConnector-Info.plist"))
        let types = try XCTUnwrap((try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])?["CFBundleURLTypes"]
                                  as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleURLSchemes"] as? [String], ["katana-connector"], "the existing scheme is the target")
    }
}
