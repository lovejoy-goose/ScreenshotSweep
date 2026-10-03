import XCTest

final class PairingPayloadParserTests: XCTestCase {
    private func assertRejects(_ text: String, _ expected: PairingError,
                               policy: PairingSecurityPolicy = .release,
                               file: StaticString = #filePath, line: UInt = #line) {
        assertPairingError(expected, file: file, line: line) {
            _ = try PairingPayloadParser.parse(text, policy: policy)
        }
    }

    func testValidQR() throws {
        let payload = try PairingPayloadParser.parse(Fixtures.qr())
        XCTAssertEqual(payload.baseURL, URL(string: "https://katana.example")!)
        XCTAssertEqual(payload.code.secretValue, "ABC-123")
        XCTAssertEqual(payload.displayHost, "katana.example")
    }

    func testValidQRWithPortPathAndSurroundingWhitespace() throws {
        let payload = try PairingPayloadParser.parse("  " + Fixtures.qr(baseURL: "https://Katana.Example:8443/app", code: " XYZ ") + "\n")
        XCTAssertEqual(payload.baseURL.absoluteString, "https://Katana.Example:8443/app")
        XCTAssertEqual(payload.displayHost, "katana.example:8443")
        XCTAssertEqual(payload.code.secretValue, "XYZ")
    }

    func testWrongSchemeHostOrVersion() {
        let query = "v=1&base_url=\(Fixtures.percentEncoded("https://katana.example"))&code=ABC"
        assertRejects("https://pair?\(query)", .invalidQR(.wrongScheme))
        assertRejects("katana://pair?\(query)", .invalidQR(.wrongScheme))
        assertRejects("katana-connector://pairing?\(query)", .invalidQR(.wrongHost))
        assertRejects("katana-connector://pair/extra?\(query)", .invalidQR(.malformed))
        assertRejects(Fixtures.qr(version: "2"), .invalidQR(.unsupportedVersion))
        assertRejects(Fixtures.qr(version: "01"), .invalidQR(.unsupportedVersion))
        assertRejects(Fixtures.qr(version: nil), .invalidQR(.unsupportedVersion))
        assertRejects("not a qr", .invalidQR(.malformed))
        assertRejects(Fixtures.qr() + "&code=OTHER", .invalidQR(.malformed))
        assertRejects(Fixtures.qr() + "#fragment", .invalidQR(.malformed))
        assertRejects(Fixtures.qr(code: String(repeating: "A", count: 2100)), .invalidQR(.tooLong))
    }

    func testMissingOrEmptyCode() {
        assertRejects(Fixtures.qr(code: nil), .invalidQR(.missingCode))
        assertRejects(Fixtures.qr(code: ""), .invalidQR(.missingCode))
        assertRejects(Fixtures.qr(code: "   "), .invalidQR(.missingCode))
        assertRejects(Fixtures.qr(code: "AB CD"), .invalidQR(.invalidCode))
        assertRejects(Fixtures.qr(code: String(repeating: "A", count: PairingCode.maxLength + 1)), .invalidQR(.invalidCode))
        XCTAssertNoThrow(try PairingPayloadParser.parse(Fixtures.qr(code: String(repeating: "A", count: PairingCode.maxLength))))
    }

    func testMissingOrMalformedBaseURL() {
        assertRejects(Fixtures.qr(baseURL: nil), .invalidQR(.missingBaseURL))
        assertRejects(Fixtures.qr(baseURL: ""), .invalidQR(.missingBaseURL))
        assertRejects(Fixtures.qr(baseURL: "not a url"), .invalidQR(.malformedBaseURL))
        assertRejects(Fixtures.qr(baseURL: "katana.example"), .invalidQR(.malformedBaseURL))
        assertRejects(Fixtures.qr(baseURL: "https://"), .invalidQR(.malformedBaseURL))
        assertRejects(Fixtures.qr(baseURL: "ftp://katana.example"), .invalidQR(.malformedBaseURL))
    }

    func testHTTPRejected() throws {
        assertRejects(Fixtures.qr(baseURL: "http://katana.example"), .insecureHost)
        assertRejects(Fixtures.qr(baseURL: "http://localhost:3000"), .insecureHost)
        assertRejects(Fixtures.qr(baseURL: "http://katana.example"), .insecureHost, policy: .localDevelopment)

        // Only the reserved local-development policy accepts plain HTTP, and only to local hosts.
        let local = try PairingPayloadParser.parse(Fixtures.qr(baseURL: "http://localhost:3000"), policy: .localDevelopment)
        XCTAssertEqual(local.displayHost, "localhost:3000")
        XCTAssertFalse(PairingSecurityPolicy.release.permits(URL(string: "http://127.0.0.1")!))
        XCTAssertTrue(PairingSecurityPolicy.localDevelopment.permits(URL(string: "http://mac.local")!))
    }

    func testCredentialsQueryOrFragmentRejected() {
        assertRejects(Fixtures.qr(baseURL: "https://user:pass@katana.example"), .invalidQR(.baseURLHasCredentials))
        assertRejects(Fixtures.qr(baseURL: "https://user@katana.example"), .invalidQR(.baseURLHasCredentials))
        assertRejects(Fixtures.qr(baseURL: "https://katana.example?next=1"), .invalidQR(.baseURLHasQuery))
        assertRejects(Fixtures.qr(baseURL: "https://katana.example#frag"), .invalidQR(.baseURLHasFragment))
    }

    func testDeviceDisplayNameNormalization() {
        XCTAssertEqual(DeviceDisplayName.normalize("  Kitchen  "), "Kitchen")
        XCTAssertEqual(DeviceDisplayName.normalize(""), "iPhone")
        XCTAssertEqual(DeviceDisplayName.normalize(" \n\t "), "iPhone")
        XCTAssertEqual(DeviceDisplayName.normalize("A\u{0007}B"), "AB")
        XCTAssertEqual(DeviceDisplayName.normalize(String(repeating: "x", count: 100)).count, DeviceDisplayName.maxLength)
    }
}
