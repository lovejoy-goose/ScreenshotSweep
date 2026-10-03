import XCTest

/// In-memory replacement for Keychain. Unit tests never touch the real Keychain.
final class InMemoryTokenStore: SecureTokenStoring, @unchecked Sendable {
    var credentials: PairingCredentials?
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(credentials: PairingCredentials? = nil) {
        self.credentials = credentials
    }

    func load() throws -> PairingCredentials? {
        if let loadError { throw loadError }
        return credentials
    }

    func save(_ credentials: PairingCredentials) throws {
        if let saveError { throw saveError }
        saveCount += 1
        self.credentials = credentials
    }

    func delete() throws {
        if let deleteError { throw deleteError }
        deleteCount += 1
        credentials = nil
    }
}

final class MockPairingClient: PairingClient, @unchecked Sendable {
    var result: Result<PairingCompleteResponse, PairingError>
    private(set) var receivedCodes: [String] = []
    private(set) var receivedDevices: [PairingDeviceInfo] = []
    private(set) var receivedBaseURLs: [URL] = []

    init(result: Result<PairingCompleteResponse, PairingError>) {
        self.result = result
    }

    func completePairing(baseURL: URL, code: PairingCode, device: PairingDeviceInfo) async throws -> PairingCompleteResponse {
        receivedBaseURLs.append(baseURL)
        receivedCodes.append(code.secretValue)
        receivedDevices.append(device)
        return try result.get()
    }
}

/// Serves canned HTTP replies to a URLSession configured with `makeSession()`.
final class MockURLProtocol: URLProtocol {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    static var reply: Reply = .failure(.notConnectedToInternet)
    static var requestCount = 0
    static var lastRequest: URLRequest?

    static func reset() {
        reply = .failure(.notConnectedToInternet)
        requestCount = 0
        lastRequest = nil
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        switch Self.reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

enum Fixtures {
    static let baseURL = URL(string: "https://katana.example")!
    static let code = "ABC-123"
    static let token = "tok_fixture_secret_value"
    static let pairedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static let device = PairingDeviceInfo(displayName: "iPhone", platform: "ios",
                                          appVersion: "0.1.0", systemVersion: "18.0")

    static let response = PairingCompleteResponse(deviceID: "dev_fixture", deviceToken: DeviceToken(token),
                                                  displayName: "Kitchen iPhone", pairedAt: pairedAt)

    static let credentials = PairingCredentials(
        token: DeviceToken(token),
        device: PairedDevice(deviceID: "dev_fixture", displayName: "Kitchen iPhone",
                             pairedAt: pairedAt, baseURL: baseURL)
    )

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    /// Builds a v1 pairing QR string; pass `nil` to omit a parameter.
    static func qr(version: String? = "1", baseURL: String? = "https://katana.example", code: String? = Fixtures.code) -> String {
        var parts: [String] = []
        if let version { parts.append("v=\(percentEncoded(version))") }
        if let baseURL { parts.append("base_url=\(percentEncoded(baseURL))") }
        if let code { parts.append("code=\(percentEncoded(code))") }
        return "katana-connector://pair?" + parts.joined(separator: "&")
    }
}

func assertPairingError(_ expected: PairingError,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("Expected \(expected), got success", file: file, line: line)
    } catch let error as PairingError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

func assertPairingError(_ expected: PairingError,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("Expected \(expected), got success", file: file, line: line)
    } catch let error as PairingError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

// MARK: - KC-005 doubles

final class InMemorySyncStateStore: SyncStateStoring {
    var lastSuccessfulSync: Date?
}

/// Records requested delays instead of sleeping; honours cancellation.
final class RecordingSleeper: DeliverySleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var delays: [Double] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func sleep(seconds: Double) async throws {
        lock.lock()
        recorded.append(seconds)
        lock.unlock()
        try Task.checkCancellation()
    }
}

/// Scriptable ConnectorAPI that also tracks concurrency.
final class MockConnectorAPI: ConnectorAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _batchCalls = 0
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _sentBatches: [[ConnectorEvent]] = []
    private var _reportCalls = 0
    private var _reportedCapabilities: [[CapabilitySnapshot]] = []
    var reportedCapabilities: [[CapabilitySnapshot]] { lock.lock(); defer { lock.unlock() }; return _reportedCapabilities }
    private var _scope: ConnectionScope? = EventFixtures.scope
    private var _sentScopes: [ConnectionScope] = []

    /// Scope of the "saved connection"; `nil` = not paired.
    var scope: ConnectionScope? {
        get { lock.lock(); defer { lock.unlock() }; return _scope }
        set { lock.lock(); _scope = newValue; lock.unlock() }
    }
    var sentScopes: [ConnectionScope] { lock.lock(); defer { lock.unlock() }; return _sentScopes }

    var batchHandler: @Sendable ([ConnectorEvent]) async throws -> [UUID: EventDeliveryResult] = { events in
        MockConnectorAPI.results(events, .accepted)
    }
    var reportHandler: @Sendable () async throws -> Void = {}
    var checkHandler: @Sendable () async throws -> ConnectionCheckResponse = {
        ConnectionCheckResponse(ok: true, serverTime: Fixtures.pairedAt, accountLabel: "Fixture")
    }

    var batchCalls: Int { lock.lock(); defer { lock.unlock() }; return _batchCalls }
    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
    var sentBatches: [[ConnectorEvent]] { lock.lock(); defer { lock.unlock() }; return _sentBatches }
    var reportCalls: Int { lock.lock(); defer { lock.unlock() }; return _reportCalls }

    static func results(_ events: [ConnectorEvent], _ status: EventDeliveryStatus) -> [UUID: EventDeliveryResult] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.eventID, EventDeliveryResult(eventID: $0.eventID, status: status, code: nil)) })
    }

    func checkConnection() async throws -> ConnectionCheckResponse {
        try await checkHandler()
    }

    func reportCapabilities(_ capabilities: [CapabilitySnapshot]) async throws {
        lock.lock(); _reportCalls += 1; _reportedCapabilities.append(capabilities); lock.unlock()
        try await reportHandler()
    }

    func currentScope() -> ConnectionScope? {
        lock.lock(); defer { lock.unlock() }
        return _scope
    }

    func sendEventBatch(_ events: [ConnectorEvent], scope: ConnectionScope) async throws -> [UUID: EventDeliveryResult] {
        lock.lock()
        _sentScopes.append(scope)
        _batchCalls += 1
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
        _sentBatches.append(events)
        lock.unlock()
        defer {
            lock.lock(); _inFlight -= 1; lock.unlock()
        }
        return try await batchHandler(events)
    }
}

enum EventFixtures {
    static let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    /// Scope of `Fixtures.credentials`.
    static let scope = ConnectionScope(baseURL: URL(string: "https://katana.example")!, deviceID: "dev_fixture")
    static let otherDeviceScope = ConnectionScope(baseURL: URL(string: "https://katana.example")!, deviceID: "dev_other")
    static let otherHostScope = ConnectionScope(baseURL: URL(string: "https://other-katana.example")!, deviceID: "dev_fixture")

    /// Neutral test event; not a real Screenshot Cleanup event.
    static func event(_ index: Int, payload: JSONValue = .object(["n": .int(1)])) -> ConnectorEvent {
        ConnectorEvent(eventID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                       type: "test.neutral_event",
                       occurredAt: Fixtures.pairedAt,
                       sessionID: sessionID,
                       payload: payload)
    }

    static func makeTemporaryStore() -> EventQueueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventQueueTests-\(UUID().uuidString)", isDirectory: true)
        return EventQueueStore(directoryURL: directory)
    }
}

/// Polls a main-actor condition (max ~2 s) without real-time sleeps in production code.
@MainActor
func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Condition not met in time", file: file, line: line)
}

