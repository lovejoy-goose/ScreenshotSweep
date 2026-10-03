import XCTest

final class PairingClientTests: XCTestCase {
    private let client = URLSessionPairingClient(session: MockURLProtocol.makeSession())

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func reply(_ status: Int, _ json: String) {
        MockURLProtocol.reply = .response(status: status, body: Data(json.utf8))
    }

    private func pair(baseURL: URL = Fixtures.baseURL) async throws -> PairingCompleteResponse {
        try await client.completePairing(baseURL: baseURL, code: PairingCode(Fixtures.code), device: Fixtures.device)
    }

    private let successJSON = #"{"device_id":"dev_1","device_token":"tok_secret","display_name":"Kitchen iPhone","paired_at":"2026-10-02T12:00:00Z"}"#

    func testExactRequest() throws {
        let request = try client.makeRequest(baseURL: Fixtures.baseURL, code: PairingCode("ABC-123"), device: Fixtures.device)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://katana.example/api/connector/pairing/complete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                       #"{"device":{"app_version":"0.1.0","display_name":"iPhone","platform":"ios","system_version":"18.0"},"pairing_code":"ABC-123"}"#)

        let nested = try client.makeRequest(baseURL: URL(string: "https://katana.example/app/")!,
                                            code: PairingCode("ABC-123"), device: Fixtures.device)
        XCTAssertEqual(nested.url?.absoluteString, "https://katana.example/app/api/connector/pairing/complete")
    }

    func testSuccessfulResponseDecoding() async throws {
        reply(200, successJSON)
        let response = try await pair()
        XCTAssertEqual(response.deviceID, "dev_1")
        XCTAssertEqual(response.deviceToken, DeviceToken("tok_secret"))
        XCTAssertEqual(response.displayName, "Kitchen iPhone")
        XCTAssertEqual(response.pairedAt, Date(timeIntervalSince1970: 1_790_942_400))
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        reply(201, #"{"device_id":"dev_1","device_token":"tok_secret","display_name":"X","paired_at":"2026-10-02T12:00:00.250Z"}"#)
        let fractional = try await pair()
        XCTAssertEqual(fractional.pairedAt.timeIntervalSince1970, 1_790_942_400.25, accuracy: 0.001)
    }

    func testErrorMapping() async {
        reply(410, "{}")
        await assertPairingError(.expiredCode) { _ = try await self.pair() }

        for status in [400, 401, 403, 409, 422] {
            reply(status, #"{"error":"x"}"#)
            await assertPairingError(.rejected) { _ = try await self.pair() }
        }

        for status in [408, 429, 500, 503] {
            reply(status, "")
            await assertPairingError(.transport) { _ = try await self.pair() }
        }

        for status in [302, 404] {
            reply(status, "")
            await assertPairingError(.invalidResponse) { _ = try await self.pair() }
        }

        reply(200, "not json")
        await assertPairingError(.invalidResponse) { _ = try await self.pair() }

        reply(200, #"{"device_id":"dev_1","device_token":"","display_name":"X","paired_at":"2026-10-02T12:00:00Z"}"#)
        await assertPairingError(.invalidResponse) { _ = try await self.pair() }

        reply(200, #"{"device_id":"","device_token":"tok","display_name":"X","paired_at":"2026-10-02T12:00:00Z"}"#)
        await assertPairingError(.invalidResponse) { _ = try await self.pair() }

        reply(200, #"{"device_id":"dev_1","device_token":"tok","display_name":"X","paired_at":"yesterday"}"#)
        await assertPairingError(.invalidResponse) { _ = try await self.pair() }

        MockURLProtocol.reply = .response(status: 200, body: Data(repeating: 0x20, count: URLSessionPairingClient.maxResponseBytes + 1))
        await assertPairingError(.invalidResponse) { _ = try await self.pair() }

        MockURLProtocol.reply = .failure(.timedOut)
        await assertPairingError(.transport) { _ = try await self.pair() }
    }

    func testInsecureHostIsNeverContacted() async {
        reply(200, successJSON)
        await assertPairingError(.insecureHost) {
            _ = try await self.pair(baseURL: URL(string: "http://katana.example")!)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }
}
