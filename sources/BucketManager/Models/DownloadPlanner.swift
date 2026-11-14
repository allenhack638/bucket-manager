import Foundation

/// Gives every download in a batch its own local path. Distinct S3 keys can map
/// to one file ("a:b" and "a_b" sanitise alike; "Readme" and "readme" collide
/// on case-insensitive APFS), a key can name a file where another key needs a
/// folder ("p/x" and "p/x/y"), and the target folder can already hold a
/// directory with the file's name. Colliding names get a " (2)" style suffix
/// instead of overwriting each other or replacing a directory.
enum DownloadPlanner {
    /// - Parameters:
    ///   - destinations: requested local paths, in download order.
    ///   - reserved: file paths already claimed by queued or running downloads.
    ///   - isDirectory: whether a path is an existing local directory.
    static func resolve(
        _ destinations: [URL],
        reserved: Set<String> = [],
        isDirectory: (URL) -> Bool = DownloadPlanner.existingDirectory
    ) -> [URL] {
        let reservedURLs = reserved.map { URL(fileURLWithPath: $0) }
        var claimed = Set(reservedURLs.map { normalized($0.path) })
        var folders = Set<String>()
        // Every folder the batch or a queued download needs.
        for destination in destinations + reservedURLs {
            var parent = destination.deletingLastPathComponent()
            while parent.pathComponents.count > 1 {
                guard folders.insert(normalized(parent.path)).inserted else { break }
                parent = parent.deletingLastPathComponent()
            }
        }

        // A folder this batch needs whose name a queued download already
        // takes as a file is renamed once, and every path below it follows.
        var folderRenames: [String: URL] = [:]
        var nextCounter: [String: Int] = [:]
        func free(_ url: URL) -> Bool {
            let key = normalized(url.path)
            return !claimed.contains(key) && !folders.contains(key) && !isDirectory(url)
        }
        func numberedFree(_ url: URL) -> URL {
            let key = normalized(url.path)
            var counter = nextCounter[key] ?? 2
            var candidate = numbered(url, counter)
            while !free(candidate) {
                counter += 1
                candidate = numbered(url, counter)
            }
            nextCounter[key] = counter + 1
            return candidate
        }
        func redirectingAncestors(_ url: URL) -> URL {
            var components: [String] = []
            var parent = url.deletingLastPathComponent()
            var ancestors: [URL] = []
            while parent.pathComponents.count > 1 {
                ancestors.append(parent)
                parent = parent.deletingLastPathComponent()
            }
            // Walk from the outermost folder inwards.
            var rebuilt: URL?
            for ancestor in ancestors.reversed() {
                let base = rebuilt.map { $0.appendingPathComponent(ancestor.lastPathComponent) } ?? ancestor
                let key = normalized(base.path)
                if let renamed = folderRenames[key] {
                    rebuilt = renamed
                } else if claimed.contains(key) {
                    let renamed = numberedFree(base)
                    folders.insert(normalized(renamed.path))
                    folderRenames[key] = renamed
                    rebuilt = renamed
                } else {
                    rebuilt = base
                }
            }
            components.append(url.lastPathComponent)
            guard let rebuilt else { return url }
            return components.reduce(rebuilt) { $0.appendingPathComponent($1) }
        }

        var resolved: [URL] = []
        resolved.reserveCapacity(destinations.count)
        for destination in destinations {
            let base = redirectingAncestors(destination)
            let candidate = free(base) ? base : numberedFree(base)
            claimed.insert(normalized(candidate.path))
            resolved.append(candidate)
        }
        return resolved
    }

    static func numbered(_ url: URL, _ counter: Int) -> URL {
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let numberedName = ext.isEmpty || stem.isEmpty
            ? "\(name) (\(counter))"
            : "\(stem) (\(counter)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(numberedName)
    }

    /// Default APFS volumes are case-insensitive (with full Unicode case
    /// folding, so "straße" equals "STRASSE") and normalisation-insensitive.
    static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
    }

    static func existingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
