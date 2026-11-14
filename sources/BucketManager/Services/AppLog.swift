import Foundation

/// Compatibility bridge for existing diagnostics call sites. New code should
/// write structured records through `LogStore` directly.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    static var path: String {
        LogStore.defaultDirectoryURL.path
    }

    private init() {}

    /// - Parameter objectKeys: S3 keys that appear in `message`, so they can
    ///   be redacted when "Include object keys" is off.
    func log(_ message: String, objectKeys: [String] = []) {
        LogStore.shared.log(
            .info,
            category: .app,
            event: "app.log",
            message: message,
            metadata: LogRedactor.objectKeysMetadata(objectKeys)
        )
        #if DEBUG
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        #endif
    }

    func error(_ message: String, objectKeys: [String] = []) {
        LogStore.shared.log(
            .error,
            category: .app,
            event: "app.error",
            message: message,
            metadata: LogRedactor.objectKeysMetadata(objectKeys)
        )
        #if DEBUG
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        #endif
    }
}
