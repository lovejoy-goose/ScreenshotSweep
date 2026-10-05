import Foundation

/// Authenticated Katana API used after pairing.
protocol ConnectorAPI: Sendable {
    func checkConnection() async throws -> ConnectionCheckResponse
    func reportCapabilities(_ capabilities: [CapabilitySnapshot]) async throws
    /// Sends only if the saved connection still has `scope`; otherwise throws `scopeMismatch`
    /// without network. Returns validated per-event results; events missing from the result stay queued.
    func sendEventBatch(_ events: [ConnectorEvent], scope: ConnectionScope) async throws -> [UUID: EventDeliveryResult]
    /// Scope of the saved connection (also when it requires repair); `nil` when not paired or unreadable.
    func currentScope() -> ConnectionScope?
}

enum ConnectorRoute: Sendable, CaseIterable {
    case checkConnection
    case capabilitiesReport
    case eventsBatch

    var method: String {
        switch self {
        case .checkConnection: return "GET"
        case .capabilitiesReport, .eventsBatch: return "POST"
        }
    }

    var pathComponents: [String] {
        switch self {
        case .checkConnection: return ["api", "connector", "connection", "check"]
        case .capabilitiesReport: return ["api", "connector", "capabilities", "report"]
        case .eventsBatch: return ["api", "connector", "events", "batch"]
        }
    }
}

/// Reads credentials from the secure store right before every request, sends
/// `Authorization: Bearer <device_token>` to the paired `base_url` and never logs
/// requests, responses or the token.
struct URLSessionConnectorAPIClient: ConnectorAPI {
    static let timeout: TimeInterval = 15

    let store: any SecureTokenStoring
    let transport: any ConnectorTransport
    let policy: PairingSecurityPolicy
    let appVersion: String
    let systemVersion: String
    let now: @Sendable () -> Date

    init(store: any SecureTokenStoring,
         transport: any ConnectorTransport = URLSessionConnectorTransport(),
         policy: PairingSecurityPolicy = .release,
         appVersion: String = PairingDeviceInfo.current(displayName: "").appVersion,
         systemVersion: String = PairingDeviceInfo.current(displayName: "").systemVersion,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.policy = policy
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.now = now
    }

    func checkConnection() async throws -> ConnectionCheckResponse {
        let data = try await send(.checkConnection, body: nil, credentials: loadCredentials())
        guard let response = try? ConnectorJSON.makeDecoder().decode(ConnectionCheckResponse.self, from: data),
              response.ok else {
            throw ConnectorAPIError.invalidResponse
        }
        return response
    }

    func reportCapabilities(_ capabilities: [CapabilitySnapshot]) async throws {
        let credentials = try loadCredentials()
        let device = ConnectorDeviceSummary(deviceID: credentials.device.deviceID,
                                            displayName: credentials.device.displayName,
                                            appVersion: appVersion,
                                            systemVersion: systemVersion,
                                            connectionState: .connected,
                                            lastSeenAt: nil)
        let report = CapabilityReport(reportedAt: now(), device: device, capabilities: capabilities)
        _ = try await send(.capabilitiesReport, body: try encode(report), credentials: credentials)
    }

    func sendEventBatch(_ events: [ConnectorEvent], scope: ConnectionScope) async throws -> [UUID: EventDeliveryResult] {
        guard !events.isEmpty else { return [:] }
        let credentials = try loadCredentials()
        // Events are never delivered to a connection other than the one they were recorded for.
        guard ConnectionScope(device: credentials.device) == scope else { throw ConnectorAPIError.scopeMismatch }
        let data = try await send(.eventsBatch, body: try encode(EventBatchRequest(events: events)), credentials: credentials)
        guard let response = try? ConnectorJSON.makeDecoder().decode(EventBatchResponse.self, from: data) else {
            throw ConnectorAPIError.invalidResponse
        }
        return try response.validated(against: events)
    }

    func currentScope() -> ConnectionScope? {
        // `try?` flattens the optional: nil when nothing is stored or Keychain is unreadable.
        guard let credentials = try? store.load() else { return nil }
        return ConnectionScope(device: credentials.device)
    }

    func makeRequest(_ route: ConnectorRoute, body: Data?, credentials: PairingCredentials) throws -> URLRequest {
        try makeRequest(method: route.method, pathComponents: route.pathComponents, body: body, credentials: credentials)
    }

    func makeRequest(method: String, pathComponents: [String], body: Data?, credentials: PairingCredentials) throws -> URLRequest {
        let baseURL = credentials.device.baseURL
        guard policy.permits(baseURL) else { throw ConnectorAPIError.insecureHost }
        let url = pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token.secretValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func loadCredentials() throws -> PairingCredentials {
        let stored: PairingCredentials?
        do {
            stored = try store.load()
        } catch {
            throw ConnectorAPIError.credentialsUnavailable
        }
        guard let credentials = stored else { throw ConnectorAPIError.notPaired }
        // Rejected credentials are never sent again.
        guard !credentials.requiresRepair else { throw ConnectorAPIError.unauthorized }
        return credentials
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try ConnectorJSON.makeEncoder().encode(value)
        } catch {
            throw ConnectorAPIError.invalidResponse
        }
    }

    private func send(_ route: ConnectorRoute, body: Data?, credentials: PairingCredentials) async throws -> Data {
        let request = try makeRequest(route, body: body, credentials: credentials)
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.perform(request)
        } catch ConnectorTransportError.network {
            throw ConnectorAPIError.transport
        } catch {
            throw ConnectorAPIError.invalidResponse
        }
        if let error = ConnectorAPIError.classify(statusCode: result.1.statusCode) { throw error }
        return result.0
    }
}

// MARK: - Reminder drafts (v0.2, D-041)

extension URLSessionConnectorAPIClient: ReminderDraftFetching {
    static func reminderDraftPathComponents(_ draftID: UUID) -> [String] {
        ["api", "connector", "reminder-drafts", draftID.uuidString.lowercased()]
    }

    /// `GET /api/connector/reminder-drafts/{draft_id}` with the Bearer token read right before the
    /// request. No redirects, ≤ 64 KiB, strict validation; never retried automatically.
    func fetchReminderDraft(id: UUID) async throws -> ReminderDraft {
        let credentials: PairingCredentials
        do {
            credentials = try loadCredentials()
        } catch ConnectorAPIError.unauthorized {
            throw ReminderDraftError.unauthorized
        } catch {
            throw ReminderDraftError.notPaired
        }
        let request: URLRequest
        do {
            request = try makeRequest(method: "GET", pathComponents: Self.reminderDraftPathComponents(id), body: nil,
                                      credentials: credentials)
        } catch {
            throw ReminderDraftError.invalidResponse
        }
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.perform(request)
        } catch ConnectorTransportError.network {
            throw ReminderDraftError.offline
        } catch {
            throw ReminderDraftError.invalidResponse
        }
        if let error = ReminderDraftError.classify(statusCode: result.1.statusCode) { throw error }
        guard let response = try? ConnectorJSON.makeDecoder().decode(ReminderDraftResponse.self, from: result.0) else {
            throw ReminderDraftError.invalidResponse
        }
        return try response.validated(requestedID: id, now: now())
    }
}

// MARK: - Action drafts (v0.3, D-047)

extension URLSessionConnectorAPIClient: ActionDraftFetching {
    static func actionDraftPathComponents(_ draftID: UUID) -> [String] {
        ["api", "connector", "action-drafts", draftID.uuidString.lowercased()]
    }

    /// `GET /api/connector/action-drafts/{draft_id}`: Bearer read right before the request, no
    /// redirects, ≤ 64 KiB, strict schema, TTL on the server clock; never retried automatically.
    func fetchActionDraft(id: UUID) async throws -> ActionDraft {
        let credentials: PairingCredentials
        do {
            credentials = try loadCredentials()
        } catch ConnectorAPIError.unauthorized {
            throw ActionDraftError.unauthorized
        } catch {
            throw ActionDraftError.notPaired
        }
        let request: URLRequest
        do {
            request = try makeRequest(method: "GET", pathComponents: Self.actionDraftPathComponents(id), body: nil,
                                      credentials: credentials)
        } catch {
            throw ActionDraftError.invalidResponse
        }
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.perform(request)
        } catch ConnectorTransportError.network {
            throw ActionDraftError.offline
        } catch {
            throw ActionDraftError.invalidResponse
        }
        if let error = ActionDraftError.classify(statusCode: result.1.statusCode) { throw error }
        return try ActionDraftParser.parse(result.0, requestedID: id)
    }
}

// MARK: - Capture upload (v0.3, D-050)

extension URLSessionConnectorAPIClient: CaptureUploading {
    static let captureUploadTimeout: TimeInterval = 60

    static func capturePathComponents(_ captureID: UUID) -> [String] {
        ["api", "connector", "captures", captureID.uuidString.lowercased()]
    }

    /// `PUT /api/connector/captures/{capture_id}` with the confirmed bytes only. No file name,
    /// path or metadata; Bearer read right before the request; no redirects; idempotent per ID.
    func uploadCapture(id: UUID, kind: CaptureKind, contentType: CaptureContentType, sha256: String,
                       body: Data) async throws -> CaptureUploadReceipt {
        let credentials: PairingCredentials
        do {
            credentials = try loadCredentials()
        } catch ConnectorAPIError.unauthorized {
            throw CaptureUploadError.unauthorized
        } catch {
            throw CaptureUploadError.notPaired
        }
        var request: URLRequest
        do {
            request = try makeRequest(method: "PUT", pathComponents: Self.capturePathComponents(id), body: body,
                                      credentials: credentials)
        } catch {
            throw CaptureUploadError.invalidResponse
        }
        request.timeoutInterval = Self.captureUploadTimeout
        request.setValue(contentType.rawValue, forHTTPHeaderField: "Content-Type")
        request.setValue(kind.rawValue, forHTTPHeaderField: "X-Katana-Capture-Kind")
        request.setValue(sha256, forHTTPHeaderField: "X-Katana-Capture-SHA256")
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.perform(request)
        } catch ConnectorTransportError.network {
            throw CaptureUploadError.offline
        } catch {
            throw CaptureUploadError.invalidResponse
        }
        if let error = CaptureUploadError.classify(statusCode: result.1.statusCode) { throw error }
        guard let response = try? ConnectorJSON.makeDecoder().decode(CaptureUploadResponse.self, from: result.0) else {
            throw CaptureUploadError.invalidResponse
        }
        return try response.validated(id: id, sha256: sha256, size: body.count)
    }
}

extension URLSessionConnectorTransport {
    /// Like the default session, but long enough for a 10 MiB upload.
    static func makeUploadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
