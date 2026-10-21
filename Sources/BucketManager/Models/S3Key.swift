import Foundation

enum S3Key {
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
}
