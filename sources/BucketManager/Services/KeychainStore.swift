import Foundation
import Security

/// Stores S3 secret access keys in the macOS login Keychain, one item per account.
enum KeychainStore {
    private static let service = "com.bucketmanager.secret"
    private static let legacyService = LegacyImport.keychainService

    static func saveSecret(_ secret: String, for accountID: UUID) throws {
        let account = accountID.uuidString
        let data = Data(secret.utf8)

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var add = base
        update.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
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
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = out as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return secret
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
        case invalidData

        var description: String {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            case .invalidData:
                return "The Keychain item does not contain a valid UTF-8 secret."
            }
        }
    }
}
