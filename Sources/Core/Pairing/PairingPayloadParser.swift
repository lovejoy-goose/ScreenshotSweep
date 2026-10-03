import Foundation

/// Parses and validates a scanned pairing QR:
/// `katana-connector://pair?v=1&base_url=<percent-encoded-url>&code=<one-time-code>`.
/// The scheme is a QR format only; the app does not register it as a URL handler.
enum PairingPayloadParser {
    static let scheme = "katana-connector"
    static let host = "pair"
    static let supportedVersion = "1"
    static let maxPayloadLength = 2048

    static func parse(_ raw: String, policy: PairingSecurityPolicy = .release) throws -> PairingPayload {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maxPayloadLength else { throw PairingError.invalidQR(.tooLong) }
        // Checked explicitly: since iOS 17 URLComponents silently percent-encodes invalid characters.
        guard isPrintableASCII(text) else { throw PairingError.invalidQR(.malformed) }
        guard let components = URLComponents(string: text) else { throw PairingError.invalidQR(.malformed) }
        guard components.scheme == scheme else { throw PairingError.invalidQR(.wrongScheme) }
        guard components.host == host else { throw PairingError.invalidQR(.wrongHost) }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.fragment == nil else {
            throw PairingError.invalidQR(.malformed)
        }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // Duplicate keys make the payload ambiguous.
            guard parameters[item.name] == nil else { throw PairingError.invalidQR(.malformed) }
            parameters[item.name] = item.value ?? ""
        }

        guard parameters["v"] == supportedVersion else { throw PairingError.invalidQR(.unsupportedVersion) }
        let code = try parseCode(parameters["code"])
        let baseURL = try parseBaseURL(parameters["base_url"], policy: policy)
        return PairingPayload(baseURL: baseURL, code: code)
    }

    private static func parseCode(_ raw: String?) throws -> PairingCode {
        let code = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw PairingError.invalidQR(.missingCode) }
        guard code.count <= PairingCode.maxLength,
              code.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }) else {
            throw PairingError.invalidQR(.invalidCode)
        }
        return PairingCode(code)
    }

    private static func parseBaseURL(_ raw: String?, policy: PairingSecurityPolicy) throws -> URL {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingError.invalidQR(.missingBaseURL) }
        guard isPrintableASCII(text) else { throw PairingError.invalidQR(.malformedBaseURL) }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw PairingError.invalidQR(.malformedBaseURL)
        }
        guard components.user == nil, components.password == nil else {
            throw PairingError.invalidQR(.baseURLHasCredentials)
        }
        guard components.query == nil else { throw PairingError.invalidQR(.baseURLHasQuery) }
        guard components.fragment == nil else { throw PairingError.invalidQR(.baseURLHasFragment) }
        guard scheme == "https" || scheme == "http" else { throw PairingError.invalidQR(.malformedBaseURL) }
        guard policy.permits(url) else { throw PairingError.insecureHost }
        return url
    }

    /// Visible ASCII only (no spaces, control or non-ASCII characters); hosts must be punycode.
    private static func isPrintableASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
