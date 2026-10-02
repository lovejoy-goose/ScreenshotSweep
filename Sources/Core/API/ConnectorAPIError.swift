import Foundation

/// Errors of authenticated Connector API calls. Carry no tokens, bodies or payloads.
enum ConnectorAPIError: Error, Equatable, Sendable {
    /// No saved credentials; nothing was sent.
    case notPaired
    /// Keychain could not be read; nothing was sent.
    case credentialsUnavailable
    /// Saved base URL is not allowed by `PairingSecurityPolicy`; nothing was sent.
    case insecureHost
    /// 401, or credentials already flagged as rejected. Stop and ask the user to pair again.
    case unauthorized
    /// Other 4xx (except 408 and 429): retrying the same request will not help.
    case rejected(statusCode: Int)
    /// No response, timeout or 408. Retry later.
    case transport
    /// 429. Retry later.
    case rateLimited
    /// 5xx. Retry later.
    case serverError(statusCode: Int)
    /// Redirect, unexpected status, oversized or malformed body.
    case invalidResponse
    /// The saved connection changed; events of the old scope are not sent to it.
    case scopeMismatch

    /// `nil` for 2xx.
    static func classify(statusCode: Int) -> ConnectorAPIError? {
        switch statusCode {
        case 200...299: return nil
        case 401: return .unauthorized
        case 408: return .transport
        case 429: return .rateLimited
        case 400...499: return .rejected(statusCode: statusCode)
        case 500...599: return .serverError(statusCode: statusCode)
        default: return .invalidResponse
        }
    }

    /// Worth retrying later with backoff.
    var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited, .serverError: return true
        case .notPaired, .credentialsUnavailable, .insecureHost, .unauthorized, .rejected, .invalidResponse, .scopeMismatch: return false
        }
    }
}
