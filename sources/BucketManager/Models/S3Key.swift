import Foundation

enum S3Key {
    /// RFC 3986 unreserved characters plus "/": everything else in an
    /// x-amz-copy-source path is percent-encoded so "+", "&" and "?" survive.
    static let copySourceAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )
    static let queryValueAllowed = copySourceAllowed.subtracting(CharacterSet(charactersIn: "/"))

    static func parentPrefix(of key: String) -> String {
        var value = key
        if value.hasSuffix("/") { value.removeLast() }
        guard let slash = value.range(of: "/", options: .backwards) else { return "" }
        return String(value[..<slash.upperBound])
    }

    static func safeLocalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "_" }
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    static func safeRelativePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: true)
            .map { safeLocalName(String($0)) }
            .joined(separator: "/")
    }
}
