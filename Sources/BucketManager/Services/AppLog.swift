import Foundation

/// Small append-only diagnostic log. Writes to stderr and to
/// ~/Library/Logs/BucketManager/app.log so failures are inspectable without a
/// debugger or screen recording permission.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.bucketmanager.applog")
    private let fileURL: URL

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
        let url = fileURL
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
