import XCTest

final class PairingCoordinatorTests: XCTestCase {
    @MainActor
    private func makeCoordinator(client: MockPairingClient = MockPairingClient(result: .success(Fixtures.response)),
                                 store: InMemoryTokenStore = InMemoryTokenStore()) -> PairingCoordinator {
        PairingCoordinator(client: client, store: store, policy: .release) { name in
            PairingDeviceInfo(displayName: name, platform: "ios", appVersion: "0.1.0", systemVersion: "18.0")
        }
    }

    @MainActor
    func testSuccessfulPairingSavesTokenExactlyOnce() async {
        let client = MockPairingClient(result: .success(Fixtures.response))
        let store = InMemoryTokenStore()
        let coordinator = makeCoordinator(client: client, store: store)
        XCTAssertEqual(coordinator.status, .unpaired)

        coordinator.handleScannedCode(Fixtures.qr())
        XCTAssertEqual(coordinator.status, .reviewing(host: "katana.example"))
        XCTAssertEqual(client.receivedCodes, [], "nothing is sent before confirmation")

        await coordinator.confirm(displayName: "  Kitchen  ")

        XCTAssertEqual(client.receivedCodes, [Fixtures.code])
        XCTAssertEqual(client.receivedDevices.map(\.displayName), ["Kitchen"])
        XCTAssertEqual(client.receivedBaseURLs, [Fixtures.baseURL])
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.credentials?.token, DeviceToken(Fixtures.token))
        XCTAssertEqual(store.credentials?.device.baseURL, Fixtures.baseURL)
        guard case .connected(let device) = coordinator.status else {
            return XCTFail("Expected connected, got \(coordinator.status)")
        }
        XCTAssertEqual(device.deviceID, "dev_fixture")
        XCTAssertEqual(device.displayName, "Kitchen iPhone")
        XCTAssertEqual(device.pairedAt, Fixtures.pairedAt)
        XCTAssertEqual(coordinator.connectionState, .connected)

        // The one-time code is never sent twice.
        await coordinator.confirm(displayName: "Again")
        XCTAssertEqual(client.receivedCodes.count, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    @MainActor
    func testEmptyDeviceNameFallsBackToIPhone() async {
        let client = MockPairingClient(result: .success(Fixtures.response))
        let coordinator = makeCoordinator(client: client)
        coordinator.handleScannedCode(Fixtures.qr())
        await coordinator.confirm(displayName: "   ")
        XCTAssertEqual(client.receivedDevices.map(\.displayName), ["iPhone"])
    }

    @MainActor
    func testFailedPairingNeverSavesToken() async {
        for error in [PairingError.expiredCode, .rejected, .transport, .invalidResponse] {
            let store = InMemoryTokenStore()
            let coordinator = makeCoordinator(client: MockPairingClient(result: .failure(error)), store: store)
            coordinator.handleScannedCode(Fixtures.qr())
            await coordinator.confirm(displayName: "iPhone")

            XCTAssertEqual(coordinator.status, .failed(error))
            XCTAssertEqual(coordinator.connectionState, .error)
            XCTAssertEqual(store.saveCount, 0)
            XCTAssertNil(store.credentials)
        }
    }

    @MainActor
    func testKeychainFailureIsNotConnected() async {
        let store = InMemoryTokenStore()
        store.saveError = SecureStoreError.unexpectedStatus(-25308)
        let coordinator = makeCoordinator(store: store)
        coordinator.handleScannedCode(Fixtures.qr())
        await coordinator.confirm(displayName: "iPhone")

        XCTAssertEqual(coordinator.status, .failed(.keychainFailure))
        XCTAssertNil(store.credentials)
    }

    @MainActor
    func testInvalidQRNeverContactsServer() async {
        let client = MockPairingClient(result: .success(Fixtures.response))
        let coordinator = makeCoordinator(client: client)

        coordinator.handleScannedCode(Fixtures.qr(baseURL: "http://katana.example"))
        XCTAssertEqual(coordinator.status, .failed(.insecureHost))
        await coordinator.confirm(displayName: "iPhone")

        coordinator.cancel()
        coordinator.handleScannedCode("https://example.invalid/not-a-pairing-qr")
        XCTAssertEqual(coordinator.status, .failed(.invalidQR(.wrongScheme)))
        await coordinator.confirm(displayName: "iPhone")

        XCTAssertEqual(client.receivedCodes, [])
    }

    @MainActor
    func testCancelDiscardsScannedCode() async {
        let client = MockPairingClient(result: .success(Fixtures.response))
        let coordinator = makeCoordinator(client: client)
        coordinator.handleScannedCode(Fixtures.qr())
        coordinator.cancel()
        XCTAssertEqual(coordinator.status, .unpaired)

        await coordinator.confirm(displayName: "iPhone")
        XCTAssertEqual(client.receivedCodes, [])
    }

    @MainActor
    func testLocalDisconnectDeletesToken() {
        let store = InMemoryTokenStore(credentials: Fixtures.credentials)
        let coordinator = makeCoordinator(store: store)
        XCTAssertEqual(coordinator.status, .connected(Fixtures.credentials.device))

        coordinator.disconnectLocally()

        XCTAssertEqual(coordinator.status, .unpaired)
        XCTAssertNil(store.credentials)
        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertNil(coordinator.notice)
    }

    @MainActor
    func testFailedLocalDisconnectStaysConnected() {
        let store = InMemoryTokenStore(credentials: Fixtures.credentials)
        store.deleteError = SecureStoreError.unexpectedStatus(-25308)
        let coordinator = makeCoordinator(store: store)

        coordinator.disconnectLocally()

        XCTAssertEqual(coordinator.status, .connected(Fixtures.credentials.device))
        XCTAssertEqual(coordinator.notice, .disconnectFailed)
    }

    @MainActor
    func testMissingKeychainTokenResolvesToUnpaired() {
        let empty = makeCoordinator(store: InMemoryTokenStore())
        XCTAssertEqual(empty.status, .unpaired)
        XCTAssertEqual(empty.connectionState, .unpaired)
        XCTAssertNil(empty.notice)

        // e.g. Keychain item no longer readable after the app was re-signed.
        let unreadable = InMemoryTokenStore(credentials: Fixtures.credentials)
        unreadable.loadError = SecureStoreError.unexpectedStatus(-34018)
        let coordinator = makeCoordinator(store: unreadable)
        XCTAssertEqual(coordinator.status, .unpaired)
        XCTAssertEqual(coordinator.notice, .credentialsUnavailable)
    }

    @MainActor
    func testFlaggedCredentialsRestoreAsRequiresRepair() {
        var flagged = Fixtures.credentials
        flagged.requiresRepair = true
        let coordinator = makeCoordinator(store: InMemoryTokenStore(credentials: flagged))
        XCTAssertEqual(coordinator.status, .requiresRepair(Fixtures.credentials.device))
        XCTAssertEqual(coordinator.connectionState, .revoked)
    }

    @MainActor
    func testMarkRequiresRepairKeepsMetadataAndFlagsToken() {
        let store = InMemoryTokenStore(credentials: Fixtures.credentials)
        let coordinator = makeCoordinator(store: store)
        coordinator.markRequiresRepair()

        XCTAssertEqual(coordinator.status, .requiresRepair(Fixtures.credentials.device))
        XCTAssertEqual(store.credentials?.requiresRepair, true)
        XCTAssertEqual(store.deleteCount, 0)
    }

    @MainActor
    func testRepairReplacesConnectionOnlyAfterConfirmation() async {
        var flagged = Fixtures.credentials
        flagged.requiresRepair = true
        let store = InMemoryTokenStore(credentials: flagged)
        let client = MockPairingClient(result: .success(PairingCompleteResponse(
            deviceID: "dev_new", deviceToken: DeviceToken("tok_new_fixture"), displayName: "iPhone", pairedAt: Fixtures.pairedAt)))
        let coordinator = makeCoordinator(client: client, store: store)

        // Scanning and cancelling keeps the previous connection untouched.
        coordinator.handleScannedCode(Fixtures.qr())
        XCTAssertEqual(coordinator.deviceToReplace, Fixtures.credentials.device)
        coordinator.cancel()
        XCTAssertEqual(coordinator.status, .requiresRepair(Fixtures.credentials.device))
        XCTAssertEqual(store.credentials, flagged)
        XCTAssertNil(coordinator.deviceToReplace)

        // Confirming replaces it.
        coordinator.handleScannedCode(Fixtures.qr())
        await coordinator.confirm(displayName: "iPhone")
        XCTAssertEqual(store.credentials?.token, DeviceToken("tok_new_fixture"))
        XCTAssertEqual(store.credentials?.requiresRepair, false)
        XCTAssertEqual(store.credentials?.device.deviceID, "dev_new")
        XCTAssertNil(coordinator.deviceToReplace)
        guard case .connected = coordinator.status else { return XCTFail("Expected connected") }
    }

    @MainActor
    func testConnectedCannotBeReplacedByScanning() {
        let store = InMemoryTokenStore(credentials: Fixtures.credentials)
        let coordinator = makeCoordinator(store: store)
        coordinator.handleScannedCode(Fixtures.qr())
        XCTAssertEqual(coordinator.status, .connected(Fixtures.credentials.device))
    }
}
