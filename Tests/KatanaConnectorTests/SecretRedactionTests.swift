import XCTest

final class SecretRedactionTests: XCTestCase {
    private func renderings(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    private func assertNoSecret(_ value: Any, _ secret: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in renderings(of: value) {
            XCTAssertFalse(text.contains(secret), "Secret leaked in: \(text)", file: file, line: line)
        }
    }

    func testTokenNeverAppearsInDescriptions() throws {
        assertNoSecret(DeviceToken(Fixtures.token), Fixtures.token)
        assertNoSecret(Fixtures.response, Fixtures.token)
        assertNoSecret(Fixtures.credentials, Fixtures.token)
        assertNoSecret(Optional(Fixtures.credentials), Fixtures.token)
        assertNoSecret([Fixtures.credentials], Fixtures.token)

        let json = #"{"device_id":"d","device_token":"\#(Fixtures.token)","display_name":"X","paired_at":"2026-10-02T12:00:00Z"}"#
        let decoded = try URLSessionPairingClient.decode(Data(json.utf8))
        assertNoSecret(decoded, Fixtures.token)
        XCTAssertEqual(decoded.deviceToken.secretValue, Fixtures.token)
    }

    func testPairingCodeNeverAppearsInDescriptions() throws {
        let code = "SECRET-CODE-42"
        let payload = try PairingPayloadParser.parse(Fixtures.qr(code: code))
        assertNoSecret(PairingCode(code), code)
        assertNoSecret(payload, code)
        assertNoSecret(PairingCompleteRequest(pairingCode: PairingCode(code), device: Fixtures.device), code)
    }

    func testCredentialsKeychainEncodingRoundTrip() throws {
        let data = try ConnectorJSON.makeEncoder().encode(Fixtures.credentials)
        XCTAssertEqual(try ConnectorJSON.makeDecoder().decode(PairingCredentials.self, from: data), Fixtures.credentials)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json, #"{"device":{"base_url":"https:\/\/katana.example","device_id":"dev_fixture","display_name":"Kitchen iPhone","paired_at":"2026-09-21T14:13:20Z"},"device_token":"tok_fixture_secret_value"}"#)
    }
}
