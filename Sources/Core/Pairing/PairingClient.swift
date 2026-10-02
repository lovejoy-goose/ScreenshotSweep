import Foundation

/// Exchanges a one-time pairing code for a device token.
protocol PairingClient: Sendable {
    func completePairing(baseURL: URL, code: PairingCode, device: PairingDeviceInfo) async throws -> PairingCompleteResponse
}

/// `POST {base_url}/api/connector/pairing/complete` (preliminary v1 contract, docs/API.md).
/// Never logs the request body, the code or the token.
struct URLSessionPairingClient: PairingClient {
    static let pathComponents = ["api", "connector", "pairing", "complete"]
    static let maxResponseBytes = 64 * 1024

    let session: URLSession
    let policy: PairingSecurityPolicy
    let timeout: TimeInterval

    init(session: URLSession = URLSessionPairingClient.makeDefaultSession(),
         policy: PairingSecurityPolicy = .release,
         timeout: TimeInterval = 15) {
        self.session = session
        self.policy = policy
        self.timeout = timeout
    }

    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func makeRequest(baseURL: URL, code: PairingCode, device: PairingDeviceInfo) throws -> URLRequest {
        guard policy.permits(baseURL) else { throw PairingError.insecureHost }
        let url = Self.pathComponents.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try ConnectorJSON.makeEncoder().encode(PairingCompleteRequest(pairingCode: code, device: device))
        } catch {
            throw PairingError.invalidResponse
        }
        return request
    }

    func completePairing(baseURL: URL, code: PairingCode, device: PairingDeviceInfo) async throws -> PairingCompleteResponse {
        let request = try makeRequest(baseURL: baseURL, code: code, device: device)

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: RejectRedirectsDelegate())
        } catch {
            throw PairingError.transport
        }
        let (data, response) = result

        guard let http = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        guard data.count <= Self.maxResponseBytes else { throw PairingError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            return try Self.decode(data)
        case 410:
            throw PairingError.expiredCode
        case 400, 401, 403, 409, 422:
            throw PairingError.rejected
        case 408, 429, 500...599:
            throw PairingError.transport
        default:
            // Includes 3xx (redirects are not followed) and 404 (no pairing endpoint at this address).
            throw PairingError.invalidResponse
        }
    }

    static func decode(_ data: Data) throws -> PairingCompleteResponse {
        guard let response = try? ConnectorJSON.makeDecoder().decode(PairingCompleteResponse.self, from: data),
              !response.deviceID.isEmpty, response.deviceID.count <= 256,
              !response.deviceToken.secretValue.isEmpty,
              response.deviceToken.secretValue.count <= DeviceToken.maxLength else {
            throw PairingError.invalidResponse
        }
        return response
    }
}

/// The code must reach only the host the user confirmed, so redirects are never followed.
private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
