import Foundation

actor MultipartUploadStore {
    static let shared = MultipartUploadStore(fileURL: defaultFileURL())

    private let fileURL: URL
    private var records: [MultipartUploadRecord]?
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(accountID: UUID, bucket: String, key: String) -> MultipartUploadRecord? {
        loadIfNeeded()
        return records?.last { $0.accountID == accountID && $0.bucket == bucket && $0.key == key }
    }

    func save(_ record: MultipartUploadRecord) {
        loadIfNeeded()
        guard var records else { return }
        if let index = records.firstIndex(where: {
            $0.accountID == record.accountID && $0.bucket == record.bucket && $0.key == record.key
        }) {
            records[index] = record
        } else {
            records.append(record)
        }
        self.records = records
        persist()
    }

    func remove(accountID: UUID, bucket: String, key: String) {
        loadIfNeeded()
        records?.removeAll {
            $0.accountID == accountID && $0.bucket == bucket && $0.key == key
        }
        persist()
    }

    func recordsSnapshot() -> [MultipartUploadRecord] {
        loadIfNeeded()
        return records ?? []
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var decoded = try JSONDecoder().decode([MultipartUploadRecord].self, from: data)
            let cutoff = Date().addingTimeInterval(-maximumAge)
            decoded.removeAll { $0.updatedAt < cutoff }
            records = decoded
        } catch {
            LogStore.shared.audit(
                event: "multipart.state.recovery",
                message: "Could not load multipart upload state: \(LogRedactor.message(error.localizedDescription))",
                outcome: "failure"
            )
            records = []
        }
    }

    private func persist() {
        guard let records else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            LogStore.shared.audit(
                event: "multipart.state.recovery",
                message: "Could not save multipart upload state: \(LogRedactor.message(error.localizedDescription))",
                outcome: "failure"
            )
        }
    }

    private static func defaultFileURL() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["S3C_MULTIPART_STATE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BucketManager", isDirectory: true)
            .appendingPathComponent("multipart-uploads.json")
    }
}
