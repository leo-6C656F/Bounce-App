import Foundation
import Security

/// Small typed wrapper over the iOS keychain.
///
/// Two attributes here are load-bearing for the threat model, not defaults:
///
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — the item is encrypted at
///   rest, unreadable while the device is locked, and **excluded from backups**.
///   The `ThisDeviceOnly` part is what keeps it out of an encrypted iTunes /
///   Finder backup, which would otherwise be a second place the secret lives.
/// - `kSecAttrSynchronizable: false` — never goes to iCloud Keychain. Bounce
///   holds account-level Plaud credentials, so replicating them across every
///   device on the Apple ID would widen the blast radius for no benefit.
enum KeychainStore {

    enum Failure: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(detail)"
            }
        }
    }

    private static let service = "ai.plaud.bounce"

    // MARK: - Codable convenience

    static func save<T: Encodable>(_ value: T, for key: String) throws {
        try saveData(try JSONEncoder().encode(value), for: key)
    }

    static func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = loadData(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Raw data

    static func saveData(_ data: Data, for key: String) throws {
        // Delete-then-add rather than update: simpler, and guarantees the
        // accessibility attributes above are applied to the stored item.
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
    }

    static func loadData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func exists(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
