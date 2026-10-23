import Foundation

struct PersistedTransferTask: Codable, Sendable {
    var id: UUID
    var accountID: UUID
    var direction: TransferTask.Direction
    var bucket: String
    var key: String
    var localPath: String
    var size: Int64
    var bytesDone: Int64
    var status: TransferTask.Status
    var error: String?
    var fileModified: TimeInterval? = nil
    var downloadETag: String? = nil
    var destinationAccountID: UUID? = nil
    var destinationBucket: String? = nil
    var destinationKey: String? = nil
    var moveSource: Bool? = nil
    var sourceETag: String? = nil
}

final class TransferQueueStore: @unchecked Sendable {
    static let shared = TransferQueueStore(fileURL: defaultFileURL())

    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        cleanupStaleTemporaryFiles()
    }

    func load() -> [PersistedTransferTask] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            backupCorruptFile()
            auditRecovery("Persisted transfer queue was unreadable; a corrupt backup was retained.")
            return []
        }
        var records: [PersistedTransferTask] = []
        var skipped = 0
        for element in array {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let record = try? decoder.decode(PersistedTransferTask.self, from: elementData),
                  record.localPath.hasPrefix("/"),
                  !record.localPath.split(separator: "/").contains("..") else {
                skipped += 1
                continue
            }
            records.append(record)
        }
        if skipped > 0 {
            backupCorruptFile()
            auditRecovery("Skipped \(skipped) invalid persisted transfer record(s).")
        }
        return records
    }

    func save(_ tasks: [PersistedTransferTask]) {
        lock.lock()
        defer { lock.unlock() }
        guard !tasks.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        guard let data = try? encoder.encode(tasks) else { return }
        let temporary = directory.appendingPathComponent(".transfer-queue-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            auditRecovery("Could not save the transfer queue: \(LogRedactor.message(error.localizedDescription))")
        }
    }

    private func cleanupStaleTemporaryFiles() {
        let directory = fileURL.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(".transfer-queue-") && name.hasSuffix(".tmp") {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func auditRecovery(_ message: String) {
        LogStore.shared.audit(
            event: "queue.state.recovery",
            message: message,
            outcome: "failure"
        )
    }

    private func backupCorruptFile() {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    static func defaultFileURL() -> URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["S3C_TRANSFER_QUEUE_STATE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("BucketManager", isDirectory: true)
            .appendingPathComponent("transfer-queue.json", isDirectory: false)
    }
}
