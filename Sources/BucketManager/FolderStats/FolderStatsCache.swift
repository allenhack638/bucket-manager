import Foundation

/// Synchronous, lock-protected cache so cached values can be rendered on the
/// first table pass after launch. Disk writes are serialized and atomic.
final class FolderStatsCache: @unchecked Sendable {
    private struct Stored: Codable {
        var version: Int
        var records: [FolderStatsRecord]
    }

    private let fileURL: URL?
    private let maxEntries: Int
    private let lock = NSLock()
    private let saveQueue = DispatchQueue(label: "com.bucketmanager.folder-stats", qos: .utility)
    private var records: [FolderStatsKey: FolderStatsRecord] = [:]
    private var saveScheduled = false

    init(fileURL: URL? = FolderStatsCache.defaultFileURL(), maxEntries: Int = 20_000) {
        self.fileURL = fileURL
        self.maxEntries = max(100, maxEntries)
        load()
    }

    static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("BucketManager", isDirectory: true)
            .appendingPathComponent("folder-stats.json")
    }

    func record(for key: FolderStatsKey) -> FolderStatsRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[key]
    }

    func records(for keys: [FolderStatsKey]) -> [FolderStatsKey: FolderStatsRecord] {
        lock.lock(); defer { lock.unlock() }
        var result: [FolderStatsKey: FolderStatsRecord] = [:]
        for key in keys { result[key] = records[key] }
        return result
    }

    func allRecords() -> [FolderStatsRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    func upsert(_ newRecords: [FolderStatsRecord], persist: Bool = true) {
        guard !newRecords.isEmpty else { return }
        lock.lock()
        for record in newRecords {
            records[record.key] = record
        }
        pruneLocked()
        lock.unlock()
        if persist { scheduleSave() }
    }

    func invalidate(accountID: UUID, bucket: String, prefix: String) {
        guard !prefix.isEmpty else { return }
        lock.lock()
        let removed = records.keys.filter { key in
            key.accountID == accountID && key.bucket == bucket
                && prefix.hasPrefix(key.prefix)
        }
        for key in removed { records[key] = nil }
        lock.unlock()
        if !removed.isEmpty { scheduleSave() }
    }

    func invalidateAccount(accountID: UUID) {
        lock.lock()
        let removed = records.keys.filter { $0.accountID == accountID }
        for key in removed { records[key] = nil }
        lock.unlock()
        if !removed.isEmpty { scheduleSave() }
    }

    func invalidateBucket(accountID: UUID, bucket: String) {
        lock.lock()
        let removed = records.keys.filter { $0.accountID == accountID && $0.bucket == bucket }
        for key in removed { records[key] = nil }
        lock.unlock()
        if !removed.isEmpty { scheduleSave() }
    }

    func clear() {
        lock.lock()
        records.removeAll()
        lock.unlock()
        scheduleSave()
    }

    func flush() {
        saveQueue.sync { self.persistNow() }
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1 else { return }
        var loaded: [FolderStatsKey: FolderStatsRecord] = [:]
        for record in stored.records { loaded[record.key] = record }
        records = loaded
        pruneLocked()
        AppLog.shared.log("folderStats cache loaded records=\(records.count)")
    }

    private func pruneLocked() {
        guard records.count > maxEntries else { return }
        let keep = records.values
            .sorted { $0.computedAt > $1.computedAt }
            .prefix(maxEntries)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
    }

    private func scheduleSave() {
        lock.lock()
        if saveScheduled {
            lock.unlock()
            return
        }
        saveScheduled = true
        lock.unlock()

        saveQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.persistNow()
        }
    }

    private func persistNow() {
        lock.lock()
        saveScheduled = false
        let snapshot = Array(records.values)
        lock.unlock()

        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let stored = Stored(version: 1, records: snapshot)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AppLog.shared.error("folderStats cache save failed: \(String(describing: error))")
        }
    }
}
