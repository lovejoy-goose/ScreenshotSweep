import XCTest

final class ConnectorURLRouterTests: XCTestCase {
    private func assertRejects(_ text: String, _ expected: ConnectorURLError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ConnectorURLRouter.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? ConnectorURLError, expected, text, file: file, line: line)
        }
    }

    // 1
    func testValidScreenshotCleanupURL() throws {
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=1&feature=screenshot_cleanup"),
                       .open(.screenshotCleanup))
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open/?feature=screenshot_cleanup&v=1"),
                       .open(.screenshotCleanup), "parameter order and an empty path do not matter")
        XCTAssertEqual(try ConnectorURLRouter.parse(URL(string: "katana-connector://open?v=1&feature=screenshot_cleanup")!),
                       .open(.screenshotCleanup))
    }

    // 2
    func testValidPairingURL() throws {
        XCTAssertEqual(try ConnectorURLRouter.parse("katana-connector://open?v=1&feature=pairing"), .open(.pairing))
    }

    // 3
    func testExactWireValues() throws {
        XCTAssertEqual(ConnectorURLRouter.scheme, "katana-connector")
        XCTAssertEqual(ConnectorURLRouter.host, "open")
        XCTAssertEqual(ConnectorURLRouter.supportedVersion, "1")
        XCTAssertEqual(ConnectorURLFeature.allCases.map(\.rawValue), ["screenshot_cleanup", "pairing"])
        XCTAssertEqual(ConnectorURLRouter.url(for: .screenshotCleanup).absoluteString,
                       "katana-connector://open?v=1&feature=screenshot_cleanup")
        XCTAssertEqual(ConnectorURLRouter.url(for: .pairing).absoluteString, "katana-connector://open?v=1&feature=pairing")
        for feature in ConnectorURLFeature.allCases {
            XCTAssertEqual(try ConnectorURLRouter.parse(ConnectorURLRouter.url(for: feature)), .open(feature))
        }
    }

    // 4–9
    func testWrongSchemeHostVersionOrFeature() {
        assertRejects("https://open?v=1&feature=pairing", .wrongScheme)
        assertRejects("katana://open?v=1&feature=pairing", .wrongScheme)
        assertRejects("katana-connector://launch?v=1&feature=pairing", .wrongHost)
        assertRejects("katana-connector://open?v=2&feature=pairing", .unsupportedVersion)
        assertRejects("katana-connector://open?v=01&feature=pairing", .unsupportedVersion)
        assertRejects("katana-connector://open?feature=pairing", .missingVersion)
        assertRejects("katana-connector://open?v=1", .missingFeature)
        assertRejects("katana-connector://open", .missingVersion)
        assertRejects("katana-connector://open?v=1&feature=capability_lab", .unknownFeature)
        assertRejects("katana-connector://open?v=1&feature=Pairing", .unknownFeature)
    }

    // 10–12
    func testRepeatedOrUnknownParameters() {
        assertRejects("katana-connector://open?v=1&v=1&feature=pairing", .duplicateParameter)
        assertRejects("katana-connector://open?v=1&feature=pairing&feature=screenshot_cleanup", .duplicateParameter)
        assertRejects("katana-connector://open?v=1&feature=pairing&ref=web", .unknownParameter)
        assertRejects("katana-connector://open?v=&feature=pairing", .emptyValue)
        assertRejects("katana-connector://open?v=1&feature", .emptyValue)
    }

    // 13–16
    func testUnexpectedURLComponents() {
        assertRejects("katana-connector://user:pass@open?v=1&feature=pairing", .unexpectedComponent)
        assertRejects("katana-connector://user@open?v=1&feature=pairing", .unexpectedComponent)
        assertRejects("katana-connector://open:8080?v=1&feature=pairing", .unexpectedComponent)
        assertRejects("katana-connector://open?v=1&feature=pairing#top", .unexpectedComponent)
        assertRejects("katana-connector://open/screenshot_cleanup?v=1&feature=pairing", .unexpectedComponent)
        assertRejects("katana-connector://open//?v=1&feature=pairing", .unexpectedComponent)
    }

    // 17, 18
    func testLengthAndCharacters() {
        let padding = String(repeating: "a", count: 2048)
        assertRejects("katana-connector://open?v=1&feature=pairing&x=\(padding)", .tooLong)
        assertRejects("katana-connector://open?v=1&feature=pairing ", .notPrintableASCII)
        assertRejects("katana-connector://open?v=1&feature=pairing\u{0007}", .notPrintableASCII)
        assertRejects("katana-connector://open?v=1&feature=pairíng", .notPrintableASCII)
        assertRejects("katana-connector://open?v=1&feature=pairing\n", .notPrintableASCII)
    }

    // 19
    func testCredentialsAreRejected() {
        for name in ["token", "device_token", "code", "pairing_code", "base_url", "device_id", "Authorization"] {
            assertRejects("katana-connector://open?v=1&feature=pairing&\(name)=secret-value", .unknownParameter)
        }
        assertRejects("katana-connector://open?token=secret-value", .unknownParameter)
    }

    // 20
    func testPairingQRFormatIsNotAccepted() {
        let qr = Fixtures.qr()
        XCTAssertTrue(qr.hasPrefix("katana-connector://pair?"))
        assertRejects(qr, .wrongHost)
        XCTAssertNoThrow(try PairingPayloadParser.parse(qr), "the QR scanner still accepts it")
    }

    func testInfoPlistRegistersScheme() throws {
        // Tests/KatanaConnectorTests/<file> → repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Config/KatanaConnector-Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types.count, 1)
        XCTAssertEqual(types.first?["CFBundleURLSchemes"] as? [String], [ConnectorURLRouter.scheme])
    }
}
