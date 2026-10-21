import Foundation

struct FolderStatsKey: Hashable, Codable, Sendable {
    let accountID: UUID
    let bucket: String
    let prefix: String
}

struct FolderStatsRecord: Codable, Hashable, Sendable {
    var accountID: UUID
    var bucket: String
    var prefix: String
    var size: Int64
    var objectCount: Int
    var newestObjectDate: Date?
    var computedAt: Date
    var partial: Bool

    var key: FolderStatsKey {
        FolderStatsKey(accountID: accountID, bucket: bucket, prefix: prefix)
    }
}

struct FolderStatsPolicy: Sendable {
    var freshTTL: TimeInterval = 5 * 60
    var maxObjects: Int = 100_000
    var maxConcurrentScans: Int = 2
    var pagesPerSecond: Double = 8
    var failureBackoff: TimeInterval = 60
}

struct FolderStatsSnapshot: Sendable {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case ready
        case refreshing
        case partial
        case failed(String)
    }

    var key: FolderStatsKey
    var record: FolderStatsRecord?
    var state: State

    var isPartial: Bool {
        if case .partial = state { return true }
        return record?.partial == true
    }

    var sizeText: String {
        if let record {
            let value = record.size.byteString
            return isPartial ? "≥ \(value)" : value
        }
        switch state {
        case .loading, .refreshing:
            return "…"
        case .failed:
            return "—"
        case .idle, .ready, .partial:
            return ""
        }
    }

    var modifiedText: String {
        if let record {
            return record.newestObjectDate?.s3ListString ?? "—"
        }
        switch state {
        case .loading, .refreshing, .failed:
            return "—"
        case .idle, .ready, .partial:
            return ""
        }
    }

    var tooltip: String? {
        guard let record else {
            switch state {
            case .loading:
                return "Calculating folder size…"
            case .refreshing:
                return "Refreshing folder size…"
            case .failed(let message):
                return message
            case .idle, .ready, .partial:
                return nil
            }
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let age = formatter.localizedString(for: record.computedAt, relativeTo: Date())
        var parts = [
            "\(record.objectCount) object\(record.objectCount == 1 ? "" : "s")",
            record.size.byteString,
            "updated \(age)"
        ]
        if isPartial {
            parts.append("partial result")
        }
        switch state {
        case .refreshing:
            parts.append("refreshing…")
        case .failed(let message):
            parts.append("refresh failed: \(message)")
        default:
            break
        }
        return parts.joined(separator: " · ")
    }
}
