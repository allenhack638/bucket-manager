import Darwin
import Foundation

final class DownloadTempRegistry: @unchecked Sendable {
    static let shared = DownloadTempRegistry(fileURL: defaultFileURL())

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func register(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard url.path.hasPrefix("/") else { return }
        loadIfNeeded()
        var values = Set(entries ?? [])
        guard values.insert(url.path).inserted else { return }
        entries = Array(values)
        persist()
    }

    func unregister(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard var values = entries else { return }
        values.removeAll { $0 == url.path }
        entries = values
        persist()
    }

    func registered() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return (entries ?? []).sorted().map { URL(fileURLWithPath: $0) }
    }

    func cleanup(active: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        var retained = Set<String>()
        for path in entries ?? [] {
            if active.contains(path), FileManager.default.fileExists(atPath: path) {
                retained.insert(path)
                continue
            }
            removeIfSafeDownloadTemp(URL(fileURLWithPath: path))
        }
        entries = Array(retained)
        persist()
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func persist() {
        guard let entries else { return }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(entries.sorted()) else { return }
        let temporary = directory.appendingPathComponent(".download-temps-\(UUID().uuidString).tmp")
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
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private func removeIfSafeDownloadTemp(_ url: URL) {
        let name = url.lastPathComponent
        let isCopyTemp = name.hasPrefix("BucketManager-Copy-") && name.hasSuffix(".tmp")
        guard (url.path.hasSuffix(".bmdownload") || isCopyTemp),
              !url.path.split(separator: "/").contains("..") else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func defaultFileURL() -> URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["S3C_DOWNLOAD_TEMP_REGISTRY"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BucketManager", isDirectory: true)
            .appendingPathComponent("download-temps.json")
    }
}
