import Foundation
import RemoteCore
import Security

/// Generic-password storage in Keychain. Items are only readable after first unlock
/// and never leave this device (no iCloud Keychain sync, no backups to other devices).
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    public let service: String

    public init(service: String = "com.example.remote") {
        self.service = service
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Per-device pairing credentials, JSON-encoded in Keychain under `device.<id>`.
public struct CredentialStore: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public func credentials(for deviceID: String) -> PairingCredentials? {
        guard let data = try? keychain.data(for: account(deviceID)) else { return nil }
        return try? JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    public func save(_ credentials: PairingCredentials, for deviceID: String) throws {
        try keychain.set(try JSONEncoder().encode(credentials), for: account(deviceID))
    }

    public func remove(for deviceID: String) {
        try? keychain.remove(account(deviceID))
    }

    private func account(_ deviceID: String) -> String { "device.\(deviceID)" }
}
