import Foundation
import Security

/// Keychain-backed credentials: one generic-password item, this device only,
/// readable after first unlock, never synced to iCloud Keychain.
struct KeychainTokenStore: SecureTokenStoring {
    static let service = "app.katana.connector.pairing"
    static let account = "device-credentials"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() throws -> PairingCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let credentials = try? ConnectorJSON.makeDecoder().decode(PairingCredentials.self, from: data) else {
                throw SecureStoreError.corruptData
            }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    func save(_ credentials: PairingCredentials) throws {
        guard let data = try? ConnectorJSON.makeEncoder().encode(credentials) else {
            throw SecureStoreError.encodingFailed
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addQuery = baseQuery.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecureStoreError.unexpectedStatus(addStatus) }
        default:
            throw SecureStoreError.unexpectedStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }
}
