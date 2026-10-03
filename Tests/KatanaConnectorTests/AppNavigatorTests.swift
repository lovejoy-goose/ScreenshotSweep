import Combine
import XCTest

final class AppNavigatorTests: XCTestCase {
    private let cleanupURL = URL(string: "katana-connector://open?v=1&feature=screenshot_cleanup")!
    private let pairingURL = URL(string: "katana-connector://open?v=1&feature=pairing")!

    // 21
    @MainActor
    func testColdStartOpensRequestedScreen() {
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.handle(cleanupURL))
        XCTAssertEqual(navigator.path, [.screenshotCleanup])

        let other = AppNavigator()
        XCTAssertTrue(other.handle(pairingURL))
        XCTAssertEqual(other.path, [.pairing])
    }

    // 22
    @MainActor
    func testWarmStartReplacesCurrentScreenDeterministically() {
        let navigator = AppNavigator(path: [.pairing])
        navigator.handle(cleanupURL)
        XCTAssertEqual(navigator.path, [.screenshotCleanup])

        navigator.handle(pairingURL)
        XCTAssertEqual(navigator.path, [.pairing])

        // A deeper stack (e.g. Dashboard → pairing → cleanup) collapses to the one target.
        let deep = AppNavigator(path: [.pairing, .screenshotCleanup])
        deep.handle(cleanupURL)
        XCTAssertEqual(deep.path, [.screenshotCleanup])
    }

    // 23
    @MainActor
    func testRepeatedLinkDoesNotDuplicateScreen() {
        let navigator = AppNavigator()
        var changes = 0
        let subscription = navigator.$path.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<3 { navigator.handle(cleanupURL) }

        XCTAssertEqual(navigator.path, [.screenshotCleanup])
        XCTAssertEqual(changes, 1, "an already shown screen is not pushed again")
    }

    // 24
    @MainActor
    func testInvalidLinkDoesNotChangeNavigation() {
        let navigator = AppNavigator(path: [.pairing])
        var changes = 0
        let subscription = navigator.$path.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }

        let invalid = [
            "katana-connector://open?v=2&feature=screenshot_cleanup",
            "katana-connector://open?v=1&feature=unknown",
            "katana-connector://open?v=1&feature=pairing&token=secret",
            Fixtures.qr(),
            "https://katana.example/open?v=1&feature=pairing",
        ]
        for text in invalid {
            XCTAssertFalse(navigator.handle(URL(string: text)!), text)
        }
        XCTAssertEqual(navigator.path, [.pairing])
        XCTAssertEqual(changes, 0)
    }

    // 25
    @MainActor
    func testURLOnlyNavigates() async throws {
        let store = EventFixtures.makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        let queue = EventQueue(store: store)
        try await queue.enqueue(EventFixtures.event(1), scope: EventFixtures.scope)

        let api = MockConnectorAPI()
        let delivery = EventDeliveryCoordinator(api: api, queue: queue, registry: CapabilityRegistry(),
                                                syncState: InMemorySyncStateStore(), sleeper: RecordingSleeper(),
                                                random: { 0.5 }, now: { Fixtures.pairedAt })
        let pairingClient = MockPairingClient(result: .success(Fixtures.response))
        let tokenStore = InMemoryTokenStore()
        let pairing = PairingCoordinator(client: pairingClient, store: tokenStore)
        let sink = FakeCleanupSink()
        let session = CleanupSessionRecorder(sink: sink, now: { Fixtures.pairedAt })
        let navigator = AppNavigator()

        for url in [cleanupURL, pairingURL, cleanupURL] { navigator.handle(url) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Navigation only: no pairing, no network, no flush, no events, no deletion bookkeeping.
        XCTAssertEqual(navigator.path, [.screenshotCleanup])
        XCTAssertEqual(pairing.status, .unpaired)
        XCTAssertEqual(pairingClient.receivedCodes, [])
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertEqual(api.batchCalls, 0)
        XCTAssertEqual(api.reportCalls, 0)
        XCTAssertFalse(delivery.isFlushing)
        XCTAssertEqual(sink.events, [])
        XCTAssertFalse(session.tracker.hasActivity)
        XCTAssertEqual(session.tracker.deletedCount, 0)
        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 1)

        // The only possible action of a URL is opening a screen.
        for feature in ConnectorURLFeature.allCases {
            XCTAssertEqual(try ConnectorURLRouter.parse(ConnectorURLRouter.url(for: feature)), .open(feature))
        }
    }
}
