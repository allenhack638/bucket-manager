import Foundation

/// One-time import from the pre-open-source internal name.
/// The old keys are intentionally kept only here so existing accounts,
/// folder caches, bookmarks, and Keychain items survive the rebrand.
enum LegacyImport {
    static let supportDirectoryName = "S3Companion"
    static let keychainService = "com.local.s3companion.secret"
    static let defaultsPrefix = "S3Companion"

    static func migrateSupportFilesIfNeeded() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let destination = support.appendingPathComponent("BucketManager", isDirectory: true)
        let source = support.appendingPathComponent(supportDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        try? fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for name in ["accounts.json", "folder-stats.json"] {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: from.path),
                  !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.copyItem(at: from, to: to)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
        }
    }
}
