import Foundation
import Security

/// Stores S3 secret access keys in the macOS login Keychain, one item per account.
enum KeychainStore {
    private static let service = "com.bucketmanager.secret"
    private static let legacyService = LegacyImport.keychainService

    static func saveSecret(_ secret: String, for accountID: UUID) throws {
        let account = accountID.uuidString
        let data = Data(secret.utf8)

        // Upsert: delete any existing item, then add.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func loadSecret(for accountID: UUID) throws -> String {
        do {
            return try readSecret(service: service, for: accountID)
        } catch {
            guard let legacy = try? readSecret(service: legacyService, for: accountID) else {
                throw error
            }
            // Promote the legacy item so subsequent launches use the new service.
            try? saveSecret(legacy, for: accountID)
            return legacy
        }
    }

    private static func readSecret(service: String, for accountID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status)
        }
        return s
    }

    static func deleteSecret(for accountID: UUID) {
        for service in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: accountID.uuidString
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        var description: String {
            switch self {
            case .status(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(msg)"
            }
        }
    }
}
