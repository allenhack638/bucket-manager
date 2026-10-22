import Foundation

/// Small append-only diagnostic log. Writes to stderr and to
/// ~/Library/Logs/BucketManager/app.log so failures are inspectable without a
/// debugger or screen recording permission.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.bucketmanager.applog")
    private let fileURL: URL
    private var lastSizeCheck = Date.distantPast
    private let maxLogBytes: UInt64 = 5 * 1024 * 1024

    private init() {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BucketManager", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        fileURL = logs.appendingPathComponent("app.log")
    }

    static var path: String {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BucketManager/app.log").path
    }

    func log(_ message: String) {
        write(message, level: "INFO")
    }

    func error(_ message: String) {
        write(message, level: "ERROR")
    }

    private func write(_ message: String, level: String) {
        let stamp = Date.now.formatted(.iso8601)
        let line = "\(stamp) [\(level)] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        queue.async { [weak self] in
            self?.append(data)
        }
    }

    private func append(_ data: Data) {
        let now = Date()
        if now.timeIntervalSince(lastSizeCheck) > 60 {
            lastSizeCheck = now
            rotateIfNeeded()
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maxLogBytes else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
