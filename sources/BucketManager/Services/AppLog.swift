import Foundation

/// Compatibility bridge for existing diagnostics call sites. New code should
/// write structured records through `LogStore` directly.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    static var path: String {
        LogStore.defaultDirectoryURL.path
    }

    private init() {}

    func log(_ message: String) {
        LogStore.shared.log(
            .info,
            category: .app,
            event: "app.log",
            message: message
        )
        #if DEBUG
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        #endif
    }

    func error(_ message: String) {
        LogStore.shared.log(
            .error,
            category: .app,
            event: "app.error",
            message: message
        )
        #if DEBUG
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        #endif
    }
}
