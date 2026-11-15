import Foundation

/// A newer Mac release found on GitHub.
struct AvailableUpdate: Equatable {
    let version: String
    let notes: String
    /// The DMG when the release has one, otherwise the release page.
    let downloadURL: URL
}

/// Asks GitHub for the newest Mac release. Only the public releases list is
/// requested; nothing about the user's accounts or buckets is sent.
enum UpdateChecker {
    static let releasesURL = URL(string: "https://api.github.com/repos/allenhack638/bucket-manager/releases?per_page=30")!
    static let tagPrefix = "macos-v"

    static let autoCheckKey = "BucketManagerAutoCheckUpdates"
    static let lastCheckKey = "BucketManagerLastUpdateCheck"
    static let notifiedVersionKey = "BucketManagerNotifiedUpdateVersion"
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]
    }

    enum CheckError: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(403), .http(429):
                return "GitHub is limiting requests right now. Try again in a few minutes."
            case .http(let status):
                return "GitHub answered with HTTP \(status)."
            }
        }
    }

    /// The version of the running app, or nil for an unbundled debug build.
    static var installedVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var automaticChecksEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// "1.2.3" or "v1.2.3" as numbers; anything after "-" or "+" is ignored.
    static func versionParts(_ value: String) -> [Int]? {
        var text = Substring(value)
        if text.hasPrefix("v") { text = text.dropFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = text[..<cut] }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = versionParts(candidate), let rhs = versionParts(installed) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Downloads are only opened from this project's own GitHub pages, over
    /// HTTPS. GitHub redirects the browser to its file host from there.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil else { return false }
        let raw = url.absoluteString.lowercased()
        guard !raw.contains("/..") && !raw.contains("%2e") else { return false }
        return url.path.hasPrefix("/allenhack638/bucket-manager/")
    }

    /// The newest published, non-prerelease Mac release newer than
    /// `installed`, from a GitHub releases list.
    static func update(from data: Data, installed: String) throws -> AvailableUpdate? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        let candidates = releases.compactMap { release -> (String, Release)? in
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix(tagPrefix) else { return nil }
            let version = String(release.tag_name.dropFirst(tagPrefix.count))
            return versionParts(version) == nil ? nil : (version, release)
        }
        guard let (version, release) = candidates.max(by: { isNewer($1.0, than: $0.0) }),
              isNewer(version, than: installed) else { return nil }

        let dmg = release.assets
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { isTrustedDownload($0) ? $0 : nil }
        guard let target = dmg ?? URL(string: release.html_url).flatMap({ isTrustedDownload($0) ? $0 : nil }) else {
            return nil
        }
        return AvailableUpdate(version: version, notes: notesExcerpt(release.body ?? ""), downloadURL: target)
    }

    /// Release notes as plain text (no Markdown heading or emphasis marks),
    /// trimmed to fit an alert.
    static func notesExcerpt(_ body: String, limit: Int = 900) -> String {
        let plain = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "(?m)^```\\w*[ \\t]*\\n?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func fetchLatest(installed: String) async throws -> AvailableUpdate? {
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BucketManager", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CheckError.http(http.statusCode)
        }
        return try update(from: data, installed: installed)
    }

    /// Whether the once-a-day automatic check is due.
    static func automaticCheckDue(now: Date = Date()) -> Bool {
        guard automaticChecksEnabled, installedVersion != nil else { return false }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        return now.timeIntervalSince(last) >= autoCheckInterval
    }
}
