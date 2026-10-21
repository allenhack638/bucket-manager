import Foundation

enum FolderStatsScanMode: String, Hashable, Sendable {
    case folder
    case parent
}

struct FolderStatsScanGroup: Hashable, Sendable {
    let accountID: UUID
    let bucket: String
    let target: String
    let mode: FolderStatsScanMode
    let keys: Set<FolderStatsKey>

    var targetID: String {
        "\(accountID.uuidString)|\(bucket)|\(mode.rawValue)|\(target)"
    }
}

actor FolderStatsScanner {
    private let service: S3Service
    private let policy: FolderStatsPolicy
    private let throttle: Throttle
    private let pacer: RateLimiter

    private struct Accumulator {
        var size: Int64 = 0
        var count: Int = 0
        var newest: Date?
    }

    init(service: S3Service, policy: FolderStatsPolicy = FolderStatsPolicy()) {
        self.service = service
        self.policy = policy
        self.throttle = Throttle(limit: policy.maxConcurrentScans)
        self.pacer = RateLimiter(requestsPerSecond: policy.pagesPerSecond)
    }

    /// One scan target per visible parent grouping. Multiple sibling folders
    /// share one recursive scan; a single folder is scanned directly.
    static func groups(for keys: [FolderStatsKey]) -> [FolderStatsScanGroup] {
        struct ParentKey: Hashable {
            let accountID: UUID
            let bucket: String
            let parent: String
        }

        var grouped: [ParentKey: Set<FolderStatsKey>] = [:]
        for key in keys {
            let parent = S3Key.parentPrefix(of: key.prefix)
            grouped[ParentKey(accountID: key.accountID, bucket: key.bucket, parent: parent), default: []]
                .insert(key)
        }

        return grouped.map { parentKey, groupedKeys in
            let isSingle = groupedKeys.count == 1
            let target = isSingle ? (groupedKeys.first?.prefix ?? parentKey.parent) : parentKey.parent
            return FolderStatsScanGroup(
                accountID: parentKey.accountID,
                bucket: parentKey.bucket,
                target: target,
                mode: isSingle ? .folder : .parent,
                keys: groupedKeys
            )
        }
    }

    func scan(group: FolderStatsScanGroup, account: Account, secret: String) async throws -> [FolderStatsRecord] {
        var accumulators: [String: Accumulator] = [:]
        for key in group.keys { accumulators[key.prefix] = Accumulator() }

        var token: String?
        var scanned = 0
        var partial = false
        var pages = 0

        repeat {
            try Task.checkCancellation()
            let currentToken = token
            try await pacer.acquire()
            let page = try await throttle.run {
                try Task.checkCancellation()
                return try await service.scanPage(
                    account: account,
                    secret: secret,
                    bucket: group.bucket,
                    prefix: group.target,
                    continuationToken: currentToken
                )
            }
            pages += 1

            for object in page.objects {
                try Task.checkCancellation()
                guard !object.key.hasSuffix("/") else { continue }
                scanned += 1
                for prefix in Self.folderPrefixes(for: object.key, target: group.target) {
                    var accumulator = accumulators[prefix, default: Accumulator()]
                    accumulator.size += object.size
                    accumulator.count += 1
                    if let date = object.lastModified,
                       accumulator.newest == nil || date > accumulator.newest! {
                        accumulator.newest = date
                    }
                    accumulators[prefix] = accumulator
                }
                if scanned >= policy.maxObjects {
                    partial = true
                    break
                }
            }

            if page.isTruncated && page.nextToken == nil { partial = true }
            token = partial ? nil : page.nextToken
            if pages >= 1000 && token != nil { partial = true }
            if partial || pages >= 1000 { break }
        } while token != nil

        let computedAt = Date()
        let records = accumulators.map { prefix, accumulator in
            FolderStatsRecord(
                accountID: group.accountID,
                bucket: group.bucket,
                prefix: prefix,
                size: accumulator.size,
                objectCount: accumulator.count,
                newestObjectDate: accumulator.newest,
                computedAt: computedAt,
                partial: partial
            )
        }

        AppLog.shared.log(
            "folderStats scan bucket=\(group.bucket) target=\(group.target) mode=\(group.mode.rawValue) objects=\(scanned) pages=\(pages) records=\(records.count) partial=\(partial)"
        )
        return records
    }

    private static func folderPrefixes(for key: String, target: String) -> [String] {
        guard key.hasPrefix(target) else { return [] }
        var prefixes: [String] = []
        if !target.isEmpty { prefixes.append(target) }

        var index = key.index(key.startIndex, offsetBy: target.count)
        while let slash = key[index...].firstIndex(of: "/") {
            let prefix = String(key[..<slash]) + "/"
            if !prefix.isEmpty { prefixes.append(prefix) }
            index = key.index(after: slash)
        }
        return prefixes
    }
}
