import Foundation

/// Storage for pairing credentials. The only production implementation is
/// `KeychainTokenStore`; tests use an in-memory fake.
protocol SecureTokenStoring: Sendable {
    /// Returns `nil` when nothing is stored.
    func load() throws -> PairingCredentials?
    /// Creates or replaces the stored credentials.
    func save(_ credentials: PairingCredentials) throws
    /// Succeeds when nothing is stored.
    func delete() throws
}

enum SecureStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case corruptData
    case encodingFailed
}
