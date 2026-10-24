import Foundation

enum EndpointValidationError: LocalizedError, Equatable {
    case empty
    case invalidSyntax
    case unsupportedScheme
    case missingHost
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
    case insecureRemoteHost

    var errorDescription: String? {
        switch self {
        case .empty:
            return "A custom endpoint is required for S3-compatible storage."
        case .invalidSyntax:
            return "The endpoint contains invalid characters or is not a valid URL."
        case .unsupportedScheme:
            return "The endpoint must use http:// or https://."
        case .missingHost:
            return "The endpoint must include a host name."
        case .credentialsNotAllowed:
            return "Do not embed usernames or passwords in the endpoint URL."
        case .queryOrFragmentNotAllowed:
            return "The endpoint must not contain a query string or fragment."
        case .insecureRemoteHost:
            return "Plain HTTP is only allowed for local or private-network endpoints. Use HTTPS for remote hosts."
        }
    }
}

enum EndpointValidator {
    static func normalized(_ raw: String, useSSL: Bool) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EndpointValidationError.empty }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw EndpointValidationError.invalidSyntax
        }

        let lower = trimmed.lowercased()
        let withScheme: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            withScheme = trimmed
        } else if lower.contains("://") {
            throw EndpointValidationError.unsupportedScheme
        } else {
            withScheme = (useSSL ? "https://" : "http://") + trimmed
        }

        guard var components = URLComponents(string: withScheme) else {
            throw EndpointValidationError.invalidSyntax
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw EndpointValidationError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw EndpointValidationError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw EndpointValidationError.queryOrFragmentNotAllowed
        }
        guard let host = components.host, !host.isEmpty else {
            throw EndpointValidationError.missingHost
        }

        let secure = scheme == "https"
        if secure != useSSL {
            components.scheme = useSSL ? "https" : "http"
        }
        if !useSSL, !isLocalHost(host) {
            throw EndpointValidationError.insecureRemoteHost
        }
        guard let url = components.url else {
            throw EndpointValidationError.invalidSyntax
        }
        return url.absoluteString
    }

    static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value == "::1" || value == "0:0:0:0:0:0:0:1" {
            return true
        }
        if !value.contains(".") {
            return true
        }
        if value.hasSuffix(".local") || value.hasSuffix(".lan") || value.hasSuffix(".internal") {
            return true
        }
        if value.contains(":"),
           value.hasPrefix("fc") || value.hasPrefix("fd") ||
           value.hasPrefix("fe8") || value.hasPrefix("fe9") ||
           value.hasPrefix("fea") || value.hasPrefix("feb") {
            return true
        }
        guard let octets = ipv4Octets(value) else { return false }
        if octets[0] == 127 || octets[0] == 10 {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        if octets[0] == 169 && octets[1] == 254 {
            return true
        }
        return false
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let number = Int(part), (0...255).contains(number) else { return nil }
            octets.append(number)
        }
        return octets
    }
}
