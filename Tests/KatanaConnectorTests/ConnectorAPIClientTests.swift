import XCTest

final class ConnectorAPIClientTests: XCTestCase {
    private var tokenStore: InMemoryTokenStore!
    private var client: URLSessionConnectorAPIClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tokenStore = InMemoryTokenStore(credentials: Fixtures.credentials)
        client = URLSessionConnectorAPIClient(store: tokenStore,
                                              transport: URLSessionConnectorTransport(session: MockURLProtocol.makeSession()),
                                              appVersion: "0.1.0", systemVersion: "18.0",
                                              now: { Fixtures.pairedAt })
    }

    private func reply(_ status: Int, _ json: String) {
        MockURLProtocol.reply = .response(status: status, body: Data(json.utf8))
    }

    private func batchResponse(_ items: [(ConnectorEvent, String)]) -> String {
        let results = items.map { #"{"event_id":"\#($0.0.eventID.uuidString.lowercased())","status":"\#($0.1)"}"# }
        return #"{"results":[\#(results.joined(separator: ","))]}"#
    }

    func testExactRoutesMethodsAndHeaders() throws {
        let expected: [(ConnectorRoute, String, String)] = [
            (.checkConnection, "GET", "https://katana.example/api/connector/connection/check"),
            (.capabilitiesReport, "POST", "https://katana.example/api/connector/capabilities/report"),
            (.eventsBatch, "POST", "https://katana.example/api/connector/events/batch"),
        ]
        for (route, method, url) in expected {
            let body: Data? = method == "POST" ? Data("{}".utf8) : nil
            let request = try client.makeRequest(route, body: body, credentials: Fixtures.credentials)
            XCTAssertEqual(request.httpMethod, method)
            XCTAssertEqual(request.url?.absoluteString, url)
            XCTAssertNil(request.url?.query, "token is never a query parameter")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Fixtures.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), method == "POST" ? "application/json" : nil)
            XCTAssertEqual(request.timeoutInterval, 15)
        }
    }

    func testBearerSentButRedactedInDescriptions() async throws {
        reply(200, #"{"ok":true,"server_time":"2026-10-02T12:00:00Z"}"#)
        _ = try await client.checkConnection()
        let sent = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(Fixtures.token)")

        // URLRequest's own mirror lists headers by design, so only its descriptions are checked.
        XCTAssertFalse(String(describing: sent).contains(Fixtures.token))
        XCTAssertFalse(String(reflecting: sent).contains(Fixtures.token))

        for value in [client as Any, tokenStore.credentials as Any, ConnectorAPIError.unauthorized as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), dumped] {
                XCTAssertFalse(text.contains(Fixtures.token), "token leaked in: \(text)")
            }
        }
    }

    func testRedirectsAreNotFollowed() async throws {
        let delegate = RejectRedirectsDelegate()
        let task = URLSession.shared.dataTask(with: URL(string: "https://katana.example")!)
        let redirect = HTTPURLResponse(url: URL(string: "https://katana.example")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://other.example"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://placeholder.example")!)
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: URL(string: "https://other.example")!)) { followed = $0 }
        XCTAssertNil(followed)

        reply(302, "")
        do {
            _ = try await client.checkConnection()
            XCTFail("Expected invalidResponse")
        } catch ConnectorAPIError.invalidResponse {}
    }

    func testConnectionCheckResponse() async throws {
        reply(200, #"{"ok":true,"server_time":"2026-10-02T12:00:00.500Z","account_label":"Acme"}"#)
        let response = try await client.checkConnection()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.serverTime.timeIntervalSince1970, 1_790_942_400.5, accuracy: 0.001)
        XCTAssertEqual(response.accountLabel, "Acme")

        reply(200, #"{"ok":true,"server_time":"2026-10-02T12:00:00Z"}"#)
        let withoutLabel = try await client.checkConnection()
        XCTAssertNil(withoutLabel.accountLabel)

        reply(200, #"{"ok":false,"server_time":"2026-10-02T12:00:00Z"}"#)
        do {
            _ = try await client.checkConnection()
            XCTFail("Expected invalidResponse")
        } catch ConnectorAPIError.invalidResponse {}
    }

    func testCapabilityReportBody() async throws {
        reply(200, #"{"ok":true}"#)
        let registry = CapabilityRegistry()
        try await client.reportCapabilities([registry.snapshot(for: .photos), registry.snapshot(for: .healthKit)])

        let body = try XCTUnwrap(bodyData(MockURLProtocol.lastRequest))
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"capabilities":[{"authorization":"unknown","availability":"available","id":"photos","probe_state":"not_run"},"#
                       + #"{"authorization":"unknown","availability":"missing_entitlement","id":"health_kit","probe_state":"not_run"}],"#
                       + #""device":{"app_version":"0.1.0","connection_state":"connected","device_id":"dev_fixture","display_name":"Kitchen iPhone","system_version":"18.0"},"#
                       + #""reported_at":"2026-09-21T14:13:20Z"}"#)
    }

    func testEventBatchResponse() async throws {
        let events = (1...3).map { EventFixtures.event($0) }
        reply(200, batchResponse([(events[0], "accepted"), (events[1], "duplicate")]))
        let results = try await client.sendEventBatch(events)

        XCTAssertEqual(results[events[0].eventID]?.status, .accepted)
        XCTAssertEqual(results[events[1].eventID]?.status, .duplicate)
        XCTAssertNil(results[events[2].eventID], "missing result keeps the event queued")

        let body = try XCTUnwrap(bodyData(MockURLProtocol.lastRequest))
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let sentEvents = try XCTUnwrap(sent?["events"] as? [[String: Any]])
        XCTAssertEqual(sentEvents.count, 3)
        XCTAssertEqual(sentEvents.first?["event_id"] as? String, "00000000-0000-4000-8000-000000000001")
    }

    func testUnknownOrRepeatedEventIDRejected() async {
        let events = [EventFixtures.event(1)]
        reply(200, batchResponse([(EventFixtures.event(99), "accepted")]))
        await assertAPIError(.invalidResponse) { _ = try await self.client.sendEventBatch(events) }

        reply(200, batchResponse([(events[0], "accepted"), (events[0], "duplicate")]))
        await assertAPIError(.invalidResponse) { _ = try await self.client.sendEventBatch(events) }

        reply(200, #"{"results":[{"event_id":"00000000-0000-4000-8000-000000000001","status":"lost"}]}"#)
        await assertAPIError(.invalidResponse) { _ = try await self.client.sendEventBatch(events) }
    }

    func testOversizedResponseRejected() async {
        MockURLProtocol.reply = .response(status: 200, body: Data(repeating: 0x20, count: URLSessionConnectorTransport.maxResponseBytes + 1))
        await assertAPIError(.invalidResponse) { _ = try await self.client.checkConnection() }
    }

    func testStatusClassification() async {
        let cases: [(Int, ConnectorAPIError)] = [
            (401, .unauthorized), (408, .transport), (429, .rateLimited),
            (400, .rejected(statusCode: 400)), (403, .rejected(statusCode: 403)), (422, .rejected(statusCode: 422)),
            (500, .serverError(statusCode: 500)), (503, .serverError(statusCode: 503)),
        ]
        for (status, expected) in cases {
            reply(status, "{}")
            await assertAPIError(expected) { _ = try await self.client.sendEventBatch([EventFixtures.event(1)]) }
        }

        MockURLProtocol.reply = .failure(.timedOut)
        await assertAPIError(.transport) { _ = try await self.client.checkConnection() }
    }

    func testCredentialsGuardSendsNothing() async {
        tokenStore.credentials = nil
        await assertAPIError(.notPaired) { _ = try await self.client.checkConnection() }

        var flagged = Fixtures.credentials
        flagged.requiresRepair = true
        tokenStore.credentials = flagged
        await assertAPIError(.unauthorized) { _ = try await self.client.checkConnection() }

        tokenStore.credentials = PairingCredentials(
            token: DeviceToken(Fixtures.token),
            device: PairedDevice(deviceID: "d", displayName: "x", pairedAt: Fixtures.pairedAt,
                                 baseURL: URL(string: "http://katana.example")!))
        await assertAPIError(.insecureHost) { _ = try await self.client.checkConnection() }

        tokenStore.credentials = Fixtures.credentials
        tokenStore.loadError = SecureStoreError.unexpectedStatus(-34018)
        await assertAPIError(.credentialsUnavailable) { _ = try await self.client.checkConnection() }

        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testCapabilityWireValuesAreSnakeCase() throws {
        let snapshot = CapabilitySnapshot(id: .localNotifications, availability: .unsupportedDevice,
                                          authorization: .notRequired, probeState: .passed, checkedAt: nil, detail: nil)
        let json = String(decoding: try ConnectorJSON.makeEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertEqual(json, #"{"authorization":"not_required","availability":"unsupported_device","id":"local_notifications","probe_state":"passed"}"#)
    }

    // MARK: Helpers

    /// URLProtocol receives the body as a stream.
    private func bodyData(_ request: URLRequest?) -> Data? {
        guard let request else { return nil }
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func assertAPIError(_ expected: ConnectorAPIError, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected \(expected), got success", file: file, line: line)
        } catch let error as ConnectorAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
