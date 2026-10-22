import Foundation
import AWSS3
import AWSSDKIdentity
import Smithy
import SmithyIdentity
import UniformTypeIdentifiers

struct ListingPage: Sendable {
    var items: [S3Item]
    var nextToken: String?
    var isTruncated: Bool
}

struct S3ObjectSummary: Sendable {
    var key: String
    var size: Int64
    var lastModified: Date?
}

struct DownloadResult: Sendable {
    var eTag: String?
    var totalSize: Int64?
    var bytesWritten: Int64
}

struct S3ObjectPage: Sendable {
    var objects: [S3ObjectSummary]
    var nextToken: String?
    var isTruncated: Bool
}

enum S3ServiceError: Error, LocalizedError {
    case emptyBody
    case invalidEndpoint
    case missingCredentials
    case missingUploadID
    case missingETag
    case incompleteMultipartUpload
    case shortRead
    case incompleteDownload(expected: Int64, received: Int64)
    case sourceChangedDuringUpload
    case rangeRestart

    var errorDescription: String? {
        switch self {
        case .emptyBody: return "The server returned an empty response body."
        case .invalidEndpoint: return "The custom endpoint is not valid."
        case .missingCredentials: return "No saved credentials were found for this account."
        case .missingUploadID: return "The server did not return a multipart upload ID."
        case .missingETag: return "The server did not return an ETag for an uploaded part."
        case .incompleteMultipartUpload: return "The multipart upload is missing one or more parts."
        case .shortRead: return "The local file changed while it was being uploaded."
        case .sourceChangedDuringUpload: return "The local file changed during the upload; retry to restart from the current contents."
        case .rangeRestart: return "The remote object changed; restarting the download."
        case .incompleteDownload(let expected, let received):
            return "The download ended after \(received) of \(expected) bytes."
        }
    }
}

actor S3Service {
    static let shared = S3Service()

    private struct ClientKey: Hashable {
        let accessKey: String
        let secret: String
        let region: String
        let endpoint: String?
        let pathStyle: Bool
        let kind: Account.Kind
    }
    private var clients: [UUID: (client: S3Client, key: ClientKey)] = [:]
    private let throttle = Throttle(limit: 4)
    private let cacheTTL: TimeInterval = 60
    private let maxListCacheEntries = 256

    private struct CacheKey: Hashable {
        let account: UUID
        let bucket: String
        let prefix: String
    }
    private struct Cached {
        let page: ListingPage
        let at: Date
    }

    private var listCache: [CacheKey: Cached] = [:]
    private var bucketCache: [UUID: (buckets: [S3Bucket], at: Date)] = [:]

    // MARK: - Client lifecycle

    func client(for account: Account, secret: String) async throws -> S3Client {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = account.region.isEmpty ? "us-east-1" : account.region
        let endpoint = try endpointString(for: account)
        let key = ClientKey(
            accessKey: account.accessKeyID,
            secret: trimmedSecret,
            region: region,
            endpoint: endpoint,
            pathStyle: account.usePathStyle,
            kind: account.kind
        )
        if let cached = clients[account.id], cached.key == key { return cached.client }

        let credentials = AWSCredentialIdentity(accessKey: account.accessKeyID, secret: trimmedSecret)
        let resolver = StaticAWSCredentialIdentityResolver(credentials)
        var config = try await S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region,
            endpoint: endpoint
        )
        config.signingRegion = region
        #if DEBUG
        if ProcessInfo.processInfo.environment["S3C_LOG"] == "1" {
            config.clientLogMode = .request
        }
        #endif
        if account.usePathStyle { config.forcePathStyle = true }
        if account.kind == .compatible {
            config.interceptorProviders = [S3KeyPathInterceptorProvider(), StripXIDInterceptorProvider()]
        } else {
            config.interceptorProviders = [S3KeyPathInterceptorProvider()]
        }
        let client = S3Client(config: config)
        clients[account.id] = (client, key)
        LogStore.shared.log(
            .info,
            category: .security,
            event: "s3.client.created",
            message: "S3 client created",
            accountID: account.id,
            accountName: account.displayName,
            metadata: [
                "kind": account.kind.rawValue,
                "region": region,
                "endpointHost": LogRedactor.endpointHost(endpoint) ?? "aws",
                "pathStyle": String(account.usePathStyle)
            ]
        )
        return client
    }

    private func endpointString(for account: Account) throws -> String? {
        guard account.kind == .compatible else { return nil }
        do {
            return try EndpointValidator.normalized(account.endpoint ?? "", useSSL: account.useSSL)
        } catch {
            throw S3ServiceError.invalidEndpoint
        }
    }

    func invalidateClient(_ accountID: UUID) {
        clients[accountID] = nil
        bucketCache[accountID] = nil
        listCache = listCache.filter { $0.key.account != accountID }
    }

    private func recordRequest(
        _ operation: String,
        account: Account,
        bucket: String?,
        key: String?,
        started: Date,
        outcome: String,
        bytes: Int64,
        error: Error?
    ) {
        let duration = Date().timeIntervalSince(started) * 1_000
        RequestMetricsStore.shared.record(
            account: account,
            bucket: bucket,
            operation: operation,
            outcome: outcome,
            durationMs: duration,
            bytes: bytes
        )
        let canceled = outcome == "canceled"
        var metadata: [String: String] = [:]
        if let error, !canceled { metadata["error"] = S3ErrorPresenter.message(for: error) }
        LogStore.shared.log(
            canceled ? .debug : (outcome == "success" ? .debug : .warning),
            category: .s3Request,
            event: "s3.request",
            message: "\(operation) \(outcome)",
            accountID: account.id,
            accountName: account.displayName,
            bucket: bucket,
            key: key,
            operation: operation,
            outcome: outcome,
            durationMs: duration,
            bytes: bytes,
            requestID: error.flatMap { LogRedactor.requestID(from: $0) },
            metadata: metadata
        )
    }

    private func measured<T>(
        _ operation: String,
        account: Account,
        bucket: String? = nil,
        key: String? = nil,
        bytes: Int64 = 0,
        _ request: () async throws -> T
    ) async throws -> T {
        let started = Date()
        do {
            let result = try await request()
            recordRequest(
                operation, account: account, bucket: bucket, key: key,
                started: started, outcome: "success", bytes: bytes, error: nil
            )
            return result
        } catch {
            let canceled = error is CancellationError
            recordRequest(
                operation, account: account, bucket: bucket, key: key,
                started: started, outcome: canceled ? "canceled" : "failure",
                bytes: 0, error: error
            )
            throw error
        }
    }

    // MARK: - Buckets

    func listBuckets(account: Account, secret: String, useCache: Bool = true) async throws -> [S3Bucket] {
        if useCache, let hit = bucketCache[account.id], Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.buckets
        }
        let client = try await client(for: account, secret: secret)
        let output: ListBucketsOutput = try await measured(
            "ListBuckets", account: account, key: nil
        ) {
            try await throttle.run { try await client.listBuckets(input: ListBucketsInput()) }
        }
        let buckets = (output.buckets ?? []).compactMap { bucket -> S3Bucket? in
            guard let name = bucket.name else { return nil }
            return S3Bucket(name: name, creationDate: bucket.creationDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        bucketCache[account.id] = (buckets, Date())
        return buckets
    }

    func createBucket(account: Account, secret: String, name: String) async throws {
        let client = try await client(for: account, secret: secret)
        var input = CreateBucketInput(bucket: name)
        if account.region != "us-east-1" {
            input.createBucketConfiguration = S3ClientTypes.CreateBucketConfiguration(
                locationConstraint: S3ClientTypes.BucketLocationConstraint(rawValue: account.region)
            )
        }
        let finalInput = input
        _ = try await measured("CreateBucket", account: account, bucket: name) {
            try await throttle.run { try await client.createBucket(input: finalInput) }
        }
        bucketCache[account.id] = nil
    }

    func deleteBucket(account: Account, secret: String, name: String) async throws {
        let client = try await client(for: account, secret: secret)
        _ = try await measured("DeleteBucket", account: account, bucket: name) {
            try await throttle.run { try await client.deleteBucket(input: DeleteBucketInput(bucket: name)) }
        }
        bucketCache[account.id] = nil
        listCache = listCache.filter { $0.key.bucket != name || $0.key.account != account.id }
    }

    // MARK: - Objects

    func listAllObjects(
        account: Account,
        secret: String,
        bucket: String,
        prefix: String
    ) async throws -> [S3Item] {
        let client = try await client(for: account, secret: secret)
        var token: String?
        var items: [S3Item] = []
        repeat {
            let input = ListObjectsV2Input(
                bucket: bucket,
                continuationToken: token,
                maxKeys: 1000,
                prefix: prefix
            )
            let output: ListObjectsV2Output = try await measured(
                "ListObjectsV2", account: account, bucket: bucket, key: prefix
            ) {
                try await throttle.run {
                    try await client.listObjectsV2(input: input)
                }
            }
            for object in output.contents ?? [] {
                guard let key = object.key else { continue }
                items.append(S3Item.listed(
                    key: key,
                    size: object.size.map(Int64.init),
                    lastModified: object.lastModified,
                    storageClass: object.storageClass?.rawValue,
                    eTag: object.eTag
                ))
            }
            token = output.nextContinuationToken
            if output.isTruncated != true { break }
        } while token != nil
        return items
    }

    func list(
        account: Account,
        secret: String,
        bucket: String,
        prefix: String,
        continuationToken: String? = nil,
        useCache: Bool = true
    ) async throws -> ListingPage {
        let key = CacheKey(account: account.id, bucket: bucket, prefix: prefix)
        if continuationToken == nil, useCache, let hit = listCache[key],
           Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.page
        }

        let client = try await client(for: account, secret: secret)
        let input = ListObjectsV2Input(
            bucket: bucket,
            continuationToken: continuationToken,
            delimiter: "/",
            maxKeys: 1000,
            prefix: prefix
        )
        let output: ListObjectsV2Output = try await measured(
            "ListObjectsV2", account: account, bucket: bucket, key: prefix
        ) {
            try await throttle.run { try await client.listObjectsV2(input: input) }
        }

        var items: [S3Item] = []
        var seen = Set<String>()
        for commonPrefix in output.commonPrefixes ?? [] {
            guard let p = commonPrefix.prefix else { continue }
            seen.insert(p)
            items.append(S3Item(key: p, kind: .folder))
        }
        for object in output.contents ?? [] {
            guard let k = object.key, k != prefix, !seen.contains(k) else { continue }
            seen.insert(k)
            items.append(S3Item.listed(
                key: k,
                size: object.size.map(Int64.init),
                lastModified: object.lastModified,
                storageClass: object.storageClass?.rawValue,
                eTag: object.eTag
            ))
        }

        let page = ListingPage(
            items: items,
            nextToken: output.nextContinuationToken,
            isTruncated: output.isTruncated ?? false
        )
        if continuationToken == nil {
            let now = Date()
            listCache[key] = Cached(page: page, at: now)
            trimListCache(now: now)
        }
        return page
    }

    /// Raw recursive page used by the folder-stats scanner. No delimiter, no
    /// listing cache; the folder-stats subsystem owns its own cache/policy.
    func scanPage(
        account: Account,
        secret: String,
        bucket: String,
        prefix: String,
        continuationToken: String?
    ) async throws -> S3ObjectPage {
        let client = try await client(for: account, secret: secret)
        let input = ListObjectsV2Input(
            bucket: bucket,
            continuationToken: continuationToken,
            maxKeys: 1000,
            prefix: prefix
        )
        let output: ListObjectsV2Output = try await measured(
            "ListObjectsV2", account: account, bucket: bucket, key: prefix
        ) {
            try await throttle.run {
                try Task.checkCancellation()
                return try await client.listObjectsV2(input: input)
            }
        }
        let objects = (output.contents ?? []).compactMap { object -> S3ObjectSummary? in
            guard let key = object.key else { return nil }
            return S3ObjectSummary(
                key: key,
                size: Int64(object.size ?? 0),
                lastModified: object.lastModified
            )
        }
        return S3ObjectPage(
            objects: objects,
            nextToken: output.nextContinuationToken,
            isTruncated: output.isTruncated ?? false
        )
    }

    func invalidateListing(account: UUID, bucket: String, prefix: String) {
        listCache[CacheKey(account: account, bucket: bucket, prefix: prefix)] = nil
    }

    private func trimListCache(now: Date) {
        listCache = listCache.filter { now.timeIntervalSince($0.value.at) < cacheTTL }
        guard listCache.count > maxListCacheEntries else { return }
        let overflow = listCache.count - maxListCacheEntries
        for entry in listCache.sorted(by: { $0.value.at < $1.value.at }).prefix(overflow) {
            listCache[entry.key] = nil
        }
    }

    func objectDetails(account: Account, secret: String, bucket: String, key: String) async throws -> ObjectDetails {
        let client = try await client(for: account, secret: secret)
        let head: HeadObjectOutput = try await measured(
            "HeadObject", account: account, bucket: bucket, key: key
        ) {
            try await throttle.run {
                try await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
            }
        }

        return ObjectDetails(
            contentType: head.contentType,
            contentLength: head.contentLength.map(Int64.init),
            eTag: head.eTag,
            lastModified: head.lastModified,
            storageClass: head.storageClass?.rawValue,
            versionID: head.versionId,
            metadata: head.metadata ?? [:],
            cacheControl: head.cacheControl,
            contentDisposition: head.contentDisposition,
            contentEncoding: head.contentEncoding,
            contentLanguage: head.contentLanguage,
            serverSideEncryption: head.serverSideEncryption?.rawValue,
            expires: head.expires,
            acceptRanges: head.acceptRanges,
            tags: [:]
        )
    }

    func objectTags(account: Account, secret: String, bucket: String, key: String) async throws -> [String: String] {
        let client = try await client(for: account, secret: secret)
        let output: GetObjectTaggingOutput = try await measured(
            "GetObjectTagging", account: account, bucket: bucket, key: key
        ) {
            try await throttle.run {
                try await client.getObjectTagging(input: GetObjectTaggingInput(bucket: bucket, key: key))
            }
        }
        var tags: [String: String] = [:]
        for tag in output.tagSet ?? [] {
            if let k = tag.key, let v = tag.value { tags[k] = v }
        }
        return tags
    }

    func objectACL(account: Account, secret: String, bucket: String, key: String) async throws -> [String] {
        let client = try await client(for: account, secret: secret)
        let output: GetObjectAclOutput = try await measured(
            "GetObjectAcl", account: account, bucket: bucket, key: key
        ) {
            try await throttle.run {
                try await client.getObjectAcl(input: GetObjectAclInput(bucket: bucket, key: key))
            }
        }
        return (output.grants ?? []).map { grant in
            let grantee = grant.grantee?.displayName
                ?? grant.grantee?.uri
                ?? grant.grantee?.id
                ?? grant.grantee?.emailAddress
                ?? "Unknown"
            return "\(grant.permission?.rawValue ?? "Permission") — \(grantee)"
        }
    }

    func versions(account: Account, secret: String, bucket: String, key: String) async throws -> [ObjectVersion] {
        let client = try await client(for: account, secret: secret)
        let output: ListObjectVersionsOutput = try await measured(
            "ListObjectVersions", account: account, bucket: bucket, key: key
        ) {
            try await throttle.run {
                try await client.listObjectVersions(input: ListObjectVersionsInput(bucket: bucket, prefix: key))
            }
        }

        var result: [ObjectVersion] = []
        for version in output.versions ?? [] where version.key == key {
            result.append(ObjectVersion(
                versionID: version.versionId ?? "null",
                isLatest: version.isLatest ?? false,
                isDeleteMarker: false,
                size: version.size.map(Int64.init),
                lastModified: version.lastModified,
                eTag: version.eTag,
                storageClass: version.storageClass?.rawValue
            ))
        }
        for marker in output.deleteMarkers ?? [] where marker.key == key {
            result.append(ObjectVersion(
                versionID: marker.versionId ?? "null",
                isLatest: marker.isLatest ?? false,
                isDeleteMarker: true,
                size: nil,
                lastModified: marker.lastModified,
                eTag: nil,
                storageClass: nil
            ))
        }
        return result.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    func previewData(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        maxBytes: Int64 = 1_048_576
    ) async throws -> Data {
        let client = try await client(for: account, secret: secret)
        let output: GetObjectOutput = try await measured(
            "GetObject", account: account, bucket: bucket, key: key
        ) {
            try await throttle.run {
                try await client.getObject(input: GetObjectInput(
                    bucket: bucket,
                    key: key,
                    range: "bytes=0-\(maxBytes - 1)"
                ))
            }
        }
        guard let body = output.body else { throw S3ServiceError.emptyBody }
        return try await body.readData() ?? Data()
    }

    // MARK: - Transfers

    nonisolated static func downloadTemporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).bmdownload")
    }

    @discardableResult
    func download(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        to url: URL,
        resumeFrom: Int64 = 0,
        expectedETag: String? = nil,
        onMetadata: (@Sendable (String?, Int64?) -> Void)? = nil,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> DownloadResult {
        let started = Date()
        let fileManager = FileManager.default
        let temporaryURL = Self.downloadTemporaryURL(for: url)
        let parentDirectory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var offset = max(0, resumeFrom)
        var resumeETag = expectedETag
        if resumeETag == nil { offset = 0 }
        if !fileManager.fileExists(atPath: temporaryURL.path) {
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
            offset = 0
        }
        if offset > 0 {
            let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path)
            let temporarySize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if temporarySize < offset {
                offset = 0
                resumeETag = nil
                try? Self.truncate(temporaryURL, to: 0)
            }
            try? Self.truncate(temporaryURL, to: UInt64(offset))
        }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let client = try await client(for: account, secret: secret)
                var input = GetObjectInput(bucket: bucket, key: key)
                if offset > 0 {
                    input.range = "bytes=\(offset)-"
                    input.ifMatch = resumeETag
                }
                let requestInput = input
                let output: GetObjectOutput = try await throttle.run {
                    try await client.getObject(input: requestInput)
                }
                if offset > 0 {
                    guard output.contentRange != nil else { throw S3ServiceError.rangeRestart }
                    if let resumeETag, let returned = output.eTag, returned != resumeETag {
                        throw S3ServiceError.rangeRestart
                    }
                }
                guard let body = output.body else { throw S3ServiceError.emptyBody }
                let totalSize = Self.totalSize(from: output.contentRange)
                    ?? (offset == 0 ? output.contentLength.map(Int64.init) : nil)
                onMetadata?(output.eTag, totalSize)

                let handle = try FileHandle(forWritingTo: temporaryURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var received: Int64 = 0
                progress(offset)
                switch body {
                case .data(let data):
                    let payload = data ?? Data()
                    try handle.write(contentsOf: payload)
                    received = Int64(payload.count)
                    progress(offset + received)
                case .stream(let stream):
                    while let chunk = try await stream.readAsync(upToCount: 256 * 1024), !chunk.isEmpty {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                        progress(offset + received)
                    }
                case .noStream:
                    throw S3ServiceError.emptyBody
                }
                if let expected = output.contentLength.map(Int64.init), received != expected {
                    throw S3ServiceError.incompleteDownload(expected: expected, received: received)
                }
                try handle.close()
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: url)
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let finalSize = totalSize ?? (offset + received)
                recordRequest(
                    "GetObject", account: account, bucket: bucket, key: key,
                    started: started, outcome: "success", bytes: finalSize, error: nil
                )
                return DownloadResult(
                    eTag: output.eTag,
                    totalSize: totalSize,
                    bytesWritten: offset + received
                )
            } catch {
                if offset > 0, attempt == 0, Self.isRangeRestart(error) {
                    offset = 0
                    resumeETag = nil
                    try? Self.truncate(temporaryURL, to: 0)
                    lastError = error
                    continue
                }
                let canceled = Task.isCancelled || error is CancellationError
                recordRequest(
                    "GetObject", account: account, bucket: bucket, key: key,
                    started: started, outcome: canceled ? "canceled" : "failure",
                    bytes: 0, error: error
                )
                throw error
            }
        }
        throw lastError ?? S3ServiceError.rangeRestart
    }

    private static func truncate(_ url: URL, to offset: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: offset)
    }

    private static func totalSize(from contentRange: String?) -> Int64? {
        guard let contentRange,
              let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...])
    }

    private static func isRangeRestart(_ error: Error) -> Bool {
        if case S3ServiceError.rangeRestart = error { return true }
        let text = String(describing: error).lowercased()
        return text.contains("preconditionfailed") || text.contains("precondition failed") || text.contains("status code: 412")
    }

    private static let multipartThreshold: Int64 = 16 * 1024 * 1024
    private static let multipartConcurrency = 4
    private static let maximumPartCount = 9_999

    func upload(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        from url: URL,
        multipartStore: MultipartUploadStore = .shared,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.multipartThreshold {
            try await uploadMultipart(
                account: account,
                secret: secret,
                bucket: bucket,
                key: key,
                from: url,
                size: size,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
                store: multipartStore,
                progress: progress,
                forceRestart: false
            )
            return
        }

        let client = try await client(for: account, secret: secret)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Some S3-compatible servers reject chunked PUTs without Content-Length.
        var input = PutObjectInput(body: .data(data), bucket: bucket, key: key)
        input.contentLength = Int(size)
        input.contentType = Self.mimeType(for: url)
        let finalInput = input
        _ = try await measured("PutObject", account: account, bucket: bucket, key: key, bytes: size) {
            try await throttle.run { try await client.putObject(input: finalInput) }
        }
        progress(size)
        invalidateListing(account: account.id, bucket: bucket, prefix: S3Key.parentPrefix(of: key))
    }

    func abortMultipart(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        store: MultipartUploadStore = .shared
    ) async {
        guard let record = await store.record(accountID: account.id, bucket: bucket, key: key) else {
            return
        }
        if let client = try? await client(for: account, secret: secret) {
            await abortMultipart(
                client: client,
                account: account,
                bucket: bucket,
                key: key,
                uploadID: record.uploadID
            )
        }
        await store.remove(accountID: account.id, bucket: bucket, key: key)
        LogStore.shared.audit(
            event: "multipart.aborted",
            message: "Multipart upload aborted",
            accountID: account.id,
            accountName: account.displayName,
            bucket: bucket,
            key: key,
            operation: "AbortMultipartUpload"
        )
    }

    private func uploadMultipart(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        from url: URL,
        size: Int64,
        modified: TimeInterval?,
        store: MultipartUploadStore,
        progress: @escaping @Sendable (Int64) -> Void,
        forceRestart: Bool
    ) async throws {
        try Task.checkCancellation()
        let partSize = Self.multipartPartSize(for: size)
        let totalParts = Int((size + Int64(partSize) - 1) / Int64(partSize))
        let client = try await client(for: account, secret: secret)
        let existing = await store.record(accountID: account.id, bucket: bucket, key: key)

        if let existing, forceRestart || !existing.matches(fileSize: size, fileModified: modified, partSize: partSize) {
            await abortMultipart(
                client: client,
                account: account,
                bucket: bucket,
                key: key,
                uploadID: existing.uploadID
            )
            await store.remove(accountID: account.id, bucket: bucket, key: key)
        }

        var record: MultipartUploadRecord
        if !forceRestart,
           let existing,
           existing.matches(fileSize: size, fileModified: modified, partSize: partSize) {
            record = existing
            LogStore.shared.audit(
                event: "multipart.resumed",
                message: "Multipart upload resumed",
                accountID: account.id,
                accountName: account.displayName,
                bucket: bucket,
                key: key,
                operation: "CreateMultipartUpload",
                metadata: ["completedParts": String(existing.parts.count), "totalParts": String(totalParts)]
            )
        } else {
            var input = CreateMultipartUploadInput(bucket: bucket, key: key)
            input.contentType = Self.mimeType(for: url)
            let finalInput = input
            let output: CreateMultipartUploadOutput = try await measured(
                "CreateMultipartUpload", account: account, bucket: bucket, key: key
            ) {
                try await throttle.run {
                    try await client.createMultipartUpload(input: finalInput)
                }
            }
            guard let uploadID = output.uploadId, !uploadID.isEmpty else {
                throw S3ServiceError.missingUploadID
            }
            record = MultipartUploadRecord(
                accountID: account.id,
                bucket: bucket,
                key: key,
                uploadID: uploadID,
                fileSize: size,
                fileModified: modified,
                partSize: partSize,
                parts: [],
                createdAt: Date(),
                updatedAt: Date()
            )
            await store.save(record)
            try Task.checkCancellation()
            LogStore.shared.audit(
                event: "multipart.started",
                message: "Multipart upload started",
                accountID: account.id,
                accountName: account.displayName,
                bucket: bucket,
                key: key,
                operation: "CreateMultipartUpload",
                metadata: ["totalParts": String(totalParts), "bytes": String(size)]
            )
        }

        var partMap: [Int: MultipartPart] = [:]
        for part in record.parts where part.number >= 1 && part.number <= totalParts {
            partMap[part.number] = part
        }
        record.parts = partMap.values.sorted { $0.number < $1.number }
        await store.save(record)
        progress(record.bytesCompleted(totalSize: size))

        let missing = (1...totalParts).filter { partMap[$0] == nil }
        do {
            let uploadID = record.uploadID
            try await withThrowingTaskGroup(of: MultipartPart.self) { group in
                var nextIndex = 0
                var inFlight = 0
                while nextIndex < missing.count || inFlight > 0 {
                    try Task.checkCancellation()
                    try Self.verifySourceUnchanged(url: url, size: size, modified: modified)
                    while inFlight < Self.multipartConcurrency, nextIndex < missing.count {
                        let number = missing[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            try await self.uploadPart(
                                client: client,
                                account: account,
                                bucket: bucket,
                                key: key,
                                uploadID: uploadID,
                                url: url,
                                partNumber: number,
                                partSize: partSize,
                                totalSize: size
                            )
                        }
                    }
                    guard inFlight > 0, let part = try await group.next() else { break }
                    inFlight -= 1
                    partMap[part.number] = part
                    record.parts = partMap.values.sorted { $0.number < $1.number }
                    record.updatedAt = Date()
                    await store.save(record)
                    progress(record.bytesCompleted(totalSize: size))
                }
            }

            try Task.checkCancellation()
            try Self.verifySourceUnchanged(url: url, size: size, modified: modified)
            guard partMap.count == totalParts else {
                throw S3ServiceError.incompleteMultipartUpload
            }
            let completedParts = partMap.values
                .sorted { $0.number < $1.number }
                .map { S3ClientTypes.CompletedPart(eTag: $0.eTag, partNumber: $0.number) }
            let input = CompleteMultipartUploadInput(
                bucket: bucket,
                key: key,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                uploadId: record.uploadID
            )
            _ = try await measured(
                "CompleteMultipartUpload", account: account, bucket: bucket, key: key
            ) {
                try await throttle.run {
                    try await client.completeMultipartUpload(input: input)
                }
            }
        } catch {
            if !forceRestart, Self.isRecoverableMultipartStateError(error) {
                await store.remove(accountID: account.id, bucket: bucket, key: key)
                try await uploadMultipart(
                    account: account,
                    secret: secret,
                    bucket: bucket,
                    key: key,
                    from: url,
                    size: size,
                    modified: modified,
                    store: store,
                    progress: progress,
                    forceRestart: true
                )
                return
            }
            throw error
        }

        await store.remove(accountID: account.id, bucket: bucket, key: key)
        progress(size)
        invalidateListing(account: account.id, bucket: bucket, prefix: S3Key.parentPrefix(of: key))
        LogStore.shared.audit(
            event: "multipart.completed",
            message: "Multipart upload completed",
            accountID: account.id,
            accountName: account.displayName,
            bucket: bucket,
            key: key,
            operation: "CompleteMultipartUpload",
            metadata: ["totalParts": String(totalParts), "bytes": String(size)]
        )
    }

    private func uploadPart(
        client: S3Client,
        account: Account,
        bucket: String,
        key: String,
        uploadID: String,
        url: URL,
        partNumber: Int,
        partSize: Int,
        totalSize: Int64
    ) async throws -> MultipartPart {
        try Task.checkCancellation()
        let offset = Int64(partNumber - 1) * Int64(partSize)
        let length = Int(min(Int64(partSize), totalSize - offset))
        let data = try Self.readPart(url: url, offset: offset, length: length)
        try Task.checkCancellation()

        var input = UploadPartInput(
            body: .data(data),
            bucket: bucket,
            contentLength: data.count,
            key: key,
            partNumber: partNumber,
            uploadId: uploadID
        )
        input.contentLength = data.count
        let finalInput = input
        let output: UploadPartOutput = try await measured(
            "UploadPart",
            account: account,
            bucket: bucket,
            key: key,
            bytes: Int64(data.count)
        ) {
            try await throttle.run {
                try await client.uploadPart(input: finalInput)
            }
        }
        guard let eTag = output.eTag, !eTag.isEmpty else {
            throw S3ServiceError.missingETag
        }
        return MultipartPart(number: partNumber, eTag: eTag)
    }

    private func abortMultipart(
        client: S3Client,
        account: Account,
        bucket: String,
        key: String,
        uploadID: String
    ) async {
        do {
            _ = try await measured(
                "AbortMultipartUpload", account: account, bucket: bucket, key: key
            ) {
                try await throttle.run {
                    try await client.abortMultipartUpload(input: AbortMultipartUploadInput(
                        bucket: bucket,
                        key: key,
                        uploadId: uploadID
                    ))
                }
            }
        } catch {
            LogStore.shared.log(
                .warning,
                category: .s3Request,
                event: "multipart.abort.failed",
                message: "Abort multipart upload failed",
                accountID: account.id,
                accountName: account.displayName,
                bucket: bucket,
                key: key,
                operation: "AbortMultipartUpload",
                outcome: "failure"
            )
        }
    }

    private static func multipartPartSize(for size: Int64) -> Int {
        var partSize = 8 * 1024 * 1024
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["S3C_MULTIPART_PART_SIZE"],
           let override = Int(raw),
           override >= 5 * 1024 * 1024 {
            partSize = override
        }
        #endif
        let required = Int((size + Int64(Self.maximumPartCount) - 1) / Int64(Self.maximumPartCount))
        partSize = max(partSize, required)
        let mebibyte = 1024 * 1024
        return max(5 * mebibyte, ((partSize + mebibyte - 1) / mebibyte) * mebibyte)
    }

    private nonisolated static func verifySourceUnchanged(
        url: URL, size: Int64, modified: TimeInterval?
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.int64Value
        guard currentSize == size else {
            throw S3ServiceError.sourceChangedDuringUpload
        }
        if let modified,
           let currentModified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970,
           abs(currentModified - modified) > 0.01 {
            throw S3ServiceError.sourceChangedDuringUpload
        }
    }

    private nonisolated static func readPart(url: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw S3ServiceError.shortRead
        }
        return data
    }

    private nonisolated static func isRecoverableMultipartStateError(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("nosuchupload") || text.contains("invalidpart")
    }

    func delete(account: Account, secret: String, bucket: String, key: String) async throws {
        let client = try await client(for: account, secret: secret)
        _ = try await measured("DeleteObject", account: account, bucket: bucket, key: key) {
            try await throttle.run {
                try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
            }
        }
        invalidateListing(account: account.id, bucket: bucket, prefix: S3Key.parentPrefix(of: key))
    }

    func createFolder(account: Account, secret: String, bucket: String, prefix: String, name: String) async throws {
        let client = try await client(for: account, secret: secret)
        let base = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : prefix + "/"
        let key = base + name + "/"
        var input = PutObjectInput(body: .data(Data()), bucket: bucket, key: key)
        input.contentType = "application/x-directory"
        let finalInput = input
        _ = try await measured("PutObject", account: account, bucket: bucket, key: key) {
            try await throttle.run { try await client.putObject(input: finalInput) }
        }
        invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
        invalidateListing(account: account.id, bucket: bucket, prefix: base)
    }

    func copyObject(
        account: Account,
        secret: String,
        sourceBucket: String,
        sourceKey: String,
        destinationBucket: String,
        destinationKey: String
    ) async throws {
        let client = try await client(for: account, secret: secret)
        let encodedSource = "/\(sourceBucket)/\(sourceKey)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(sourceBucket)/\(sourceKey)"
        _ = try await measured(
            "CopyObject", account: account, bucket: destinationBucket, key: destinationKey
        ) {
            try await throttle.run {
                try await client.copyObject(input: CopyObjectInput(
                    bucket: destinationBucket,
                    copySource: encodedSource,
                    key: destinationKey
                ))
            }
        }
        invalidateListing(account: account.id, bucket: sourceBucket, prefix: S3Key.parentPrefix(of: sourceKey))
        invalidateListing(account: account.id, bucket: destinationBucket, prefix: S3Key.parentPrefix(of: destinationKey))
    }

    nonisolated static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
