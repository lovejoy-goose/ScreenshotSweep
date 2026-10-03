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
        let baseURL = credentials.device.baseURL
        guard policy.permits(baseURL) else { throw ConnectorAPIError.insecureHost }
        let url = route.pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = route.method
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
