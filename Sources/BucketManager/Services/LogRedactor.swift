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
        sanitized.message = message(record.message)
        sanitized.accountName = record.accountName.map(message)
        sanitized.bucket = record.bucket.map(message)
        sanitized.key = settings.includeObjectKeys ? record.key.map(message) : nil
        sanitized.metadata = metadata(record.metadata)
        return sanitized
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

    static func localPath(_ url: URL, includeFullPath: Bool) -> String {
        includeFullPath ? url.path : url.lastPathComponent
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
