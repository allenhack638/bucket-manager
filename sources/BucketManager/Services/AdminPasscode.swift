import AppKit
import CryptoKit
import Foundation
import Security

struct PasscodeCredential: Codable, Sendable {
    var salt: Data
    var hash: Data
    var iterations: Int
}

enum PasscodeHasher {
    static let defaultIterations = 100_000

    static func make(password: String, iterations: Int = defaultIterations) -> PasscodeCredential {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return PasscodeCredential(
            salt: salt,
            hash: derive(password: password, salt: salt, iterations: iterations),
            iterations: iterations
        )
    }

    static func verify(_ password: String, against credential: PasscodeCredential) -> Bool {
        let candidate = derive(
            password: password,
            salt: credential.salt,
            iterations: max(defaultIterations, credential.iterations)
        )
        return constantTimeEqual(candidate, credential.hash)
    }

    static func derive(password: String, salt: Data, iterations: Int) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(password.utf8)))
        let passwordData = Data(password.utf8)
        for _ in 1..<max(1, iterations) {
            digest = Data(SHA256.hash(data: digest + salt + passwordData))
        }
        return digest
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

final class AdminPasscodeStore: @unchecked Sendable {
    static let shared = AdminPasscodeStore()

    private let service = "com.bucketmanager.admin"
    private let account = "passcode"
    private let lock = NSLock()

    var hasPasscode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? readCredential()) != nil
    }

    func setPasscode(_ password: String) throws {
        let credential = PasscodeHasher.make(password: password)
        lock.lock()
        defer { lock.unlock() }
        try writeCredential(credential)
    }

    func verify(_ password: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = try? readCredential() else { return false }
        return PasscodeHasher.verify(password, against: credential)
    }

    func removePasscode() throws {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func readCredential() throws -> PasscodeCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        return try JSONDecoder().decode(PasscodeCredential.self, from: data)
    }

    private func writeCredential(_ credential: PasscodeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(domain: "BucketManager.AdminPasscode", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

@MainActor
final class AdminAuthSession {
    static let shared = AdminAuthSession()
    private var unlockedUntil: Date?
    private let duration: TimeInterval = 5 * 60

    var isUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return unlockedUntil > Date()
    }

    func unlock() {
        unlockedUntil = Date().addingTimeInterval(duration)
    }

    func lock() {
        unlockedUntil = nil
    }
}

@MainActor
enum AdminAuthPrompt {
    static func authorize(reason: String, forcePrompt: Bool = false) -> Bool {
        if !forcePrompt, AdminAuthSession.shared.isUnlocked {
            return true
        }
        if !AdminPasscodeStore.shared.hasPasscode {
            return createPasscode(reason: reason)
        }
        return unlock(reason: reason)
    }

    private static func createPasscode(reason: String) -> Bool {
        let first = NSSecureTextField()
        let second = NSSecureTextField()
        first.placeholderString = "New admin passcode"
        second.placeholderString = "Confirm admin passcode"
        configure(field: first)
        configure(field: second)
        first.setAccessibilityLabel("New admin passcode")
        second.setAccessibilityLabel("Confirm admin passcode")

        let explanation = NSTextField(wrappingLabelWithString:
            "Create an admin passcode before accessing logs and statistics. It is stored in the macOS Keychain and cannot be recovered. If lost, remove the “Bucket Manager Admin Passcode” item in Keychain Access."
        )
        explanation.font = Theme.Font.small
        explanation.textColor = Theme.Colors.secondaryText
        explanation.maximumNumberOfLines = 0
        explanation.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let stack = NSStackView(views: [explanation, first, second])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 112)

        let alert = NSAlert()
        alert.messageText = "Protect logs and statistics"
        alert.informativeText = reason
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create Passcode")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = first

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let password = first.stringValue
        guard password.count >= 6 else {
            showError("Passcode must be at least 6 characters.")
            return false
        }
        guard password == second.stringValue else {
            showError("The passcodes do not match.")
            return false
        }
        do {
            try AdminPasscodeStore.shared.setPasscode(password)
            AdminAuthSession.shared.unlock()
            LogStore.shared.audit(
                event: "security.passcode.created",
                message: "Admin passcode created",
                outcome: "success"
            )
            return true
        } catch {
            LogStore.shared.audit(
                event: "security.passcode.create.failed",
                message: "Admin passcode could not be created",
                outcome: "failure"
            )
            showError("Could not store the passcode: \(error.localizedDescription)")
            return false
        }
    }

    static func changePasscode() -> Bool {
        guard AdminPasscodeStore.shared.hasPasscode else { return false }
        let current = NSSecureTextField()
        let replacement = NSSecureTextField()
        let confirmation = NSSecureTextField()
        current.placeholderString = "Current passcode"
        replacement.placeholderString = "New passcode"
        confirmation.placeholderString = "Confirm new passcode"
        for field in [current, replacement, confirmation] { configure(field: field) }
        current.setAccessibilityLabel("Current admin passcode")
        replacement.setAccessibilityLabel("New admin passcode")
        confirmation.setAccessibilityLabel("Confirm new admin passcode")

        let stack = NSStackView(views: [current, replacement, confirmation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 104)

        let alert = NSAlert()
        alert.messageText = "Change admin passcode"
        alert.informativeText = "The current passcode is required. There is no recovery if it is lost."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = current

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard AdminPasscodeStore.shared.verify(current.stringValue) else {
            LogStore.shared.audit(
                event: "security.passcode.change.failed",
                message: "Admin passcode change failed",
                outcome: "failure"
            )
            showError("The current passcode is incorrect.")
            return false
        }
        let password = replacement.stringValue
        guard password.count >= 6, password == confirmation.stringValue else {
            showError("The new passcodes must match and be at least 6 characters.")
            return false
        }
        do {
            try AdminPasscodeStore.shared.setPasscode(password)
            AdminAuthSession.shared.unlock()
            LogStore.shared.audit(
                event: "security.passcode.changed",
                message: "Admin passcode changed",
                outcome: "success"
            )
            return true
        } catch {
            showError("Could not store the new passcode: \(error.localizedDescription)")
            return false
        }
    }

    private static var failedUnlockAttempts = 0

    private static func unlock(reason: String) -> Bool {
        if failedUnlockAttempts >= 3 {
            let delay = min(2.0, Double(failedUnlockAttempts - 2) * 0.5)
            Thread.sleep(forTimeInterval: delay)
        }
        let field = NSSecureTextField()
        field.placeholderString = "Admin passcode"
        configure(field: field)

        let stack = NSStackView(views: [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 28)

        let alert = NSAlert()
        alert.messageText = "Unlock logs and statistics"
        alert.informativeText = reason
        alert.accessoryView = stack
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if AdminPasscodeStore.shared.verify(field.stringValue) {
            failedUnlockAttempts = 0
            AdminAuthSession.shared.unlock()
            LogStore.shared.audit(
                event: "security.unlock.succeeded",
                message: "Admin authorization succeeded",
                outcome: "success"
            )
            return true
        }
        failedUnlockAttempts += 1
        LogStore.shared.audit(
            event: "security.unlock.failed",
            message: "Admin authorization failed",
            outcome: "failure"
        )
        showError("Incorrect admin passcode.")
        return false
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Logs are locked"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func configure(field: NSSecureTextField) {
        field.font = Theme.Font.field
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.setAccessibilityLabel("Admin passcode")
    }
}
