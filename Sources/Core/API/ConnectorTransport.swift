import Foundation

/// Sends one HTTP request. Implementations never log requests or responses.
protocol ConnectorTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum ConnectorTransportError: Error, Equatable, Sendable {
    /// No response: offline, DNS, TLS, timeout or cancellation.
    case network
    case notHTTP
    case responseTooLarge
}

/// Ephemeral URLSession (no cookies, no cache); redirects are never followed and
/// responses above 64 KiB are rejected.
struct URLSessionConnectorTransport: ConnectorTransport {
    static let maxResponseBytes = 64 * 1024

    let session: URLSession

    init(session: URLSession = URLSessionConnectorTransport.makeDefaultSession()) {
        self.session = session
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

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: RejectRedirectsDelegate())
        } catch {
            throw ConnectorTransportError.network
        }
        guard let http = result.1 as? HTTPURLResponse else { throw ConnectorTransportError.notHTTP }
        guard result.0.count <= Self.maxResponseBytes else { throw ConnectorTransportError.responseTooLarge }
        return (result.0, http)
    }
}

/// Requests (and their Authorization header or pairing code) must reach only the
/// confirmed host, so redirects are never followed; the 3xx response is returned as is.
final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
