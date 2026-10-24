import Foundation

@MainActor
final class AccountStore {
    typealias SecretLoader = (UUID) throws -> String

    private(set) var accounts: [Account] = []

    private let fileURL: URL
    private let secretLoader: SecretLoader
    private var secretCache: [UUID: String] = [:]
    private var loggedCacheHits: Set<UUID> = []

    init(
        inMemoryAccounts: [Account]? = nil,
        secrets: [UUID: String] = [:],
        secretLoader: @escaping SecretLoader = KeychainStore.loadSecret
    ) {
        self.secretLoader = secretLoader
        if let inMemoryAccounts {
            self.fileURL = URL(fileURLWithPath: "/dev/null")
            self.accounts = inMemoryAccounts
            self.secretCache = secrets
            return
        }
        LegacyImport.migrateSupportFilesIfNeeded()
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BucketManager", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.fileURL = dir.appendingPathComponent("accounts.json")
        load()
        // Repair permissions left by older builds: the directory may already
        // exist, in which case createDirectory's attributes are ignored.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    func add(_ account: Account, secret: String) throws {
        do {
            try KeychainStore.saveSecret(secret, for: account.id)
        } catch {
            auditAccount("account.add.failed", account: account, outcome: "failure")
            throw error
        }
        secretCache[account.id] = secret
        accounts.append(account)
        save()
        invalidateClient(for: account.id)
        auditAccount("account.added", account: account)
    }

    func update(_ account: Account, secret: String?) throws {
        if let secret, !secret.isEmpty {
            do {
                try KeychainStore.saveSecret(secret, for: account.id)
            } catch {
                auditAccount("account.update.failed", account: account, outcome: "failure")
                throw error
            }
            secretCache[account.id] = secret
        }
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
        invalidateClient(for: account.id)
        auditAccount("account.updated", account: account)
    }

    func remove(_ account: Account) {
        KeychainStore.deleteSecret(for: account.id)
        secretCache[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        save()
        invalidateClient(for: account.id)
        auditAccount("account.removed", account: account)
    }

    func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    func secret(for account: Account) throws -> String {
        if let cached = secretCache[account.id] {
            if loggedCacheHits.insert(account.id).inserted {
                AppLog.shared.log("Keychain cache hit for \"\(account.displayName)\" (no second prompt)")
            }
            return cached
        }
        AppLog.shared.log("Keychain read requested for \"\(account.displayName)\"")
        do {
            let secret = try secretLoader(account.id)
            secretCache[account.id] = secret
            AppLog.shared.log("Keychain read succeeded for \"\(account.displayName)\"")
            return secret
        } catch {
            AppLog.shared.error("Keychain read failed for \"\(account.displayName)\": \(error.localizedDescription)")
            throw error
        }
    }

    private func invalidateClient(for accountID: UUID) {
        Task { await S3Service.shared.invalidateClient(accountID) }
    }

    private func auditAccount(_ event: String, account: Account, outcome: String = "success") {
        var metadata = [
            "kind": account.kind.rawValue,
            "endpointHost": LogRedactor.endpointHost(account.endpoint) ?? "aws",
            "pathStyle": String(account.usePathStyle)
        ]
        if let bucket = account.bucket, !bucket.isEmpty {
            metadata["bucket"] = bucket
        }
        LogStore.shared.audit(
            event: event,
            message: outcome == "success" ? "Account operation succeeded" : "Account operation failed",
            accountID: account.id,
            accountName: account.displayName,
            outcome: outcome,
            metadata: metadata
        )
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            AppLog.shared.error("Could not read accounts.json: \(error.localizedDescription)")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(accounts)
            try data.write(to: fileURL, options: .atomic)
            if fileURL.path != "/dev/null" {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            }
        } catch {
            AppLog.shared.error("Could not save accounts.json: \(error.localizedDescription)")
        }
    }
}
