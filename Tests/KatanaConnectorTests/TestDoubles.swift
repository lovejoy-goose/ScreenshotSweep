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

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
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
