import Foundation

enum LogRedactor {
    private static let sensitiveFragments = [
        "authorization", "secret", "token", "password", "credential",
        "signature", "cookie", "session", "accesskey", "access-key",
        "privatekey", "private-key", "passphrase", "x-amz", "signedheaders",
        "signed-headers"
    ]

    static func record(
        _ record: LogRecord,
        settings: LoggingSettings
    ) -> LogRecord {
        var sanitized = record
        var text = record.message
        var values = record.metadata
        let mentioned = values.removeValue(forKey: objectKeysField)?
            .split(separator: "\n").map(String.init) ?? []
        if !settings.includeObjectKeys {
            // Keys also appear inside free-form messages ("Deleted a/b.txt")
            // and key-valued metadata; hide them all, longest first so a key
            // that contains another is replaced whole.
            var keys = mentioned + [record.key].compactMap { $0 }
            for (name, value) in values where isObjectKeyField(name) {
                keys.append(value)
                values[name] = "<object key>"
            }
            for key in Set(keys).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
                text = replacingWhole(key, in: text)
            }
        }
        sanitized.message = message(text)
        sanitized.accountName = record.accountName.map(message)
        sanitized.bucket = record.bucket.map(message)
        sanitized.key = settings.includeObjectKeys ? record.key.map(message) : nil
        sanitized.metadata = metadata(values)
        return sanitized
    }

    private static let objectKeysField = "_objectKeys"

    /// Replaces `key` only where it stands alone (between spaces, quotes,
    /// brackets, "/", "=", ":" or the line edges), so a short key such as "a"
    /// never turns "Created" into "Cre<object key>ted".
    static func replacingWhole(_ key: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        // A trailing "." counts as an edge only at the end of a sentence, so
        // key "a" does not match inside "a.txt".
        let pattern = #"(?<=^|[\s"'(\[/=:])"# + escaped + #"(?=$|[\s"')\]/,:;]|\.(?:$|\s))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<object key>")
    }

    /// Carries the keys mentioned in a message to the redactor; the field is
    /// always stripped before the record is stored.
    static func objectKeysMetadata(_ keys: [String]) -> [String: String] {
        keys.isEmpty ? [:] : [objectKeysField: keys.joined(separator: "\n")]
    }

    /// Metadata such as "sourceKey" or "destinationKey" (not "accessKey").
    static func isObjectKeyField(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("key") && !isSensitive(name) && lower != "key"
            || lower == "prefix"
    }

    static func message(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(cleaned.prefix(2_000))
    }

    static func metadata(_ values: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in values.prefix(40) {
            if isSensitive(key) {
                sanitized[message(key)] = "<redacted>"
            } else {
                sanitized[message(key)] = message(value)
            }
        }
        return sanitized
    }

    static func isSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveFragments.contains { lower.contains($0) }
    }

    static func endpointHost(_ endpoint: String?) -> String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        let candidate = endpoint.contains("://") ? endpoint : "https://\(endpoint)"
        guard let components = URLComponents(string: candidate),
              let host = components.host else { return nil }
        return host
    }

    static func requestID(from error: Error) -> String? {
        let text = String(describing: error)
        guard let range = text.range(of: "requestID: Optional(\"") else { return nil }
        let remainder = text[range.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        let value = String(remainder[..<end])
        return value.isEmpty ? nil : message(value)
    }
}
