import Foundation

struct Account: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case amazonS3
        case compatible
        case govCloud

        var displayName: String {
            switch self {
            case .amazonS3: return "Amazon S3 Storage"
            case .compatible: return "Amazon S3 Compatible Storage"
            case .govCloud: return "Amazon S3 GovCloud Storage (FIPS 140-2)"
            }
        }
    }

    var id: UUID = UUID()
    var displayName: String
    var accessKeyID: String
    var kind: Kind = .amazonS3
    var region: String = "us-east-1"
    var endpoint: String?
    var usePathStyle: Bool = false
    var useSSL: Bool = true
    var createdAt: Date = Date()

    var isAWS: Bool { kind != .compatible }
    var endpointHost: String? {
        guard kind == .compatible, let endpoint, !endpoint.isEmpty else { return nil }
        return endpoint
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        accessKeyID: String,
        kind: Kind = .amazonS3,
        region: String = "us-east-1",
        endpoint: String? = nil,
        usePathStyle: Bool = false,
        useSSL: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.accessKeyID = accessKeyID
        self.kind = kind
        self.region = region
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle
        self.useSSL = useSSL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, accessKeyID, kind, region, endpoint, usePathStyle, useSSL, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decode(String.self, forKey: .displayName)
        accessKeyID = try c.decode(String.self, forKey: .accessKeyID)
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        usePathStyle = try c.decodeIfPresent(Bool.self, forKey: .usePathStyle) ?? false
        useSSL = try c.decodeIfPresent(Bool.self, forKey: .useSSL) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        if let k = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            kind = k
        } else {
            kind = (endpoint?.isEmpty == false) ? .compatible : .amazonS3
        }
    }
}
