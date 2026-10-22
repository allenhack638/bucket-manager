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

    var errorDescription: String? {
        switch self {
        case .emptyBody: return "The server returned an empty response body."
        case .invalidEndpoint: return "The custom endpoint is not valid."
        case .missingCredentials: return "No saved credentials were found for this account."
        case .missingUploadID: return "The server did not return a multipart upload ID."
        case .missingETag: return "The server did not return an ETag for an uploaded part."
        case .incompleteMultipartUpload: return "The multipart upload is missing one or more parts."
        case .shortRead: return "The local file changed while it was being uploaded."
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

        AppLog.shared.log("S3 credential shape: accessKeyLen=\(account.accessKeyID.count)")
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
        AppLog.shared.log("S3 client: account=\"\(account.displayName)\" kind=\(account.kind.rawValue) region=\(region) endpoint=\(endpoint ?? "aws") pathStyle=\(account.usePathStyle)")
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

    // MARK: - Buckets

    func listBuckets(account: Account, secret: String, useCache: Bool = true) async throws -> [S3Bucket] {
        if useCache, let hit = bucketCache[account.id], Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.buckets
        }
        let client = try await client(for: account, secret: secret)
        AppLog.shared.log("listBuckets start account=\"\(account.displayName)\"")
        let output: ListBucketsOutput
        do {
            output = try await throttle.run { try await client.listBuckets(input: ListBucketsInput()) }
        } catch {
            AppLog.shared.error("listBuckets failed account=\"\(account.displayName)\": \(String(describing: error))")
            throw error
        }
        let buckets = (output.buckets ?? []).compactMap { bucket -> S3Bucket? in
            guard let name = bucket.name else { return nil }
            return S3Bucket(name: name, creationDate: bucket.creationDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        bucketCache[account.id] = (buckets, Date())
        AppLog.shared.log("listBuckets ok account=\"\(account.displayName)\" count=\(buckets.count)")
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
        _ = try await throttle.run { try await client.createBucket(input: finalInput) }
        bucketCache[account.id] = nil
    }

    func deleteBucket(account: Account, secret: String, name: String) async throws {
        let client = try await client(for: account, secret: secret)
        _ = try await throttle.run { try await client.deleteBucket(input: DeleteBucketInput(bucket: name)) }
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
            let output = try await throttle.run {
                try await client.listObjectsV2(input: input)
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
        AppLog.shared.log("Recursive list ok bucket=\(bucket) prefix=\(prefix) count=\(items.count)")
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
        let output: ListObjectsV2Output
        do {
            output = try await throttle.run { try await client.listObjectsV2(input: input) }
        } catch {
            AppLog.shared.error("ListObjectsV2 failed bucket=\(bucket) prefix=\(prefix): \(String(describing: error))")
            throw error
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
        AppLog.shared.log("listObjectsV2 ok bucket=\(bucket) prefix=\(prefix) count=\(items.count)")
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
        do {
            let output = try await throttle.run {
                try Task.checkCancellation()
                return try await client.listObjectsV2(input: input)
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
        } catch {
            AppLog.shared.error("scanPage failed bucket=\(bucket) prefix=\(prefix): \(String(describing: error))")
            throw error
        }
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
        AppLog.shared.log("headObject bucket=\(bucket) key=\(key)")
        let head = try await throttle.run {
            try await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
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
        AppLog.shared.log("getObjectTagging bucket=\(bucket) key=\(key)")
        let output = try await throttle.run {
            try await client.getObjectTagging(input: GetObjectTaggingInput(bucket: bucket, key: key))
        }
        var tags: [String: String] = [:]
        for tag in output.tagSet ?? [] {
            if let k = tag.key, let v = tag.value { tags[k] = v }
        }
        return tags
    }

    func objectACL(account: Account, secret: String, bucket: String, key: String) async throws -> [String] {
        let client = try await client(for: account, secret: secret)
        AppLog.shared.log("getObjectAcl bucket=\(bucket) key=\(key)")
        let output = try await throttle.run {
            try await client.getObjectAcl(input: GetObjectAclInput(bucket: bucket, key: key))
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
        AppLog.shared.log("listObjectVersions bucket=\(bucket) key=\(key)")
        let output = try await throttle.run {
            try await client.listObjectVersions(input: ListObjectVersionsInput(bucket: bucket, prefix: key))
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
        let output = try await throttle.run {
            try await client.getObject(input: GetObjectInput(
                bucket: bucket,
                key: key,
                range: "bytes=0-\(maxBytes - 1)"
            ))
        }
        guard let body = output.body else { throw S3ServiceError.emptyBody }
        return try await body.readData() ?? Data()
    }

    // MARK: - Transfers

    func download(
        account: Account,
        secret: String,
        bucket: String,
        key: String,
        to url: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let client = try await client(for: account, secret: secret)
        let output = try await throttle.run {
            try await client.getObject(input: GetObjectInput(bucket: bucket, key: key))
        }
        guard let body = output.body else { throw S3ServiceError.emptyBody }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        defer { try? handle.close() }

        var written: Int64 = 0
        switch body {
        case .data(let data):
            let payload = data ?? Data()
            try handle.write(contentsOf: payload)
            written = Int64(payload.count)
            progress(written)
        case .stream(let stream):
            while let chunk = try await stream.readAsync(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written)
            }
        case .noStream:
            throw S3ServiceError.emptyBody
        }
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
        _ = try await throttle.run { try await client.putObject(input: finalInput) }
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
            await abortMultipart(client: client, bucket: bucket, key: key, uploadID: record.uploadID)
        }
        await store.remove(accountID: account.id, bucket: bucket, key: key)
        AppLog.shared.log("Aborted multipart upload bucket=\(bucket) key=\(key)")
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
            await abortMultipart(client: client, bucket: bucket, key: key, uploadID: existing.uploadID)
            await store.remove(accountID: account.id, bucket: bucket, key: key)
        }

        var record: MultipartUploadRecord
        if !forceRestart,
           let existing,
           existing.matches(fileSize: size, fileModified: modified, partSize: partSize) {
            record = existing
            AppLog.shared.log("Resume multipart bucket=\(bucket) key=\(key) parts=\(existing.parts.count)/\(totalParts)")
        } else {
            var input = CreateMultipartUploadInput(bucket: bucket, key: key)
            input.contentType = Self.mimeType(for: url)
            let finalInput = input
            let output = try await throttle.run {
                try await client.createMultipartUpload(input: finalInput)
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
            AppLog.shared.log("Start multipart bucket=\(bucket) key=\(key) parts=\(totalParts) size=\(size)")
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
            for start in stride(from: 0, to: missing.count, by: Self.multipartConcurrency) {
                try Task.checkCancellation()
                let end = min(start + Self.multipartConcurrency, missing.count)
                let batch = Array(missing[start..<end])
                let uploaded = try await withThrowingTaskGroup(of: MultipartPart.self) { group in
                    for number in batch {
                        group.addTask {
                            try await self.uploadPart(
                                client: client,
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
                    var results: [MultipartPart] = []
                    for try await part in group {
                        results.append(part)
                    }
                    return results
                }
                try Task.checkCancellation()
                for part in uploaded {
                    partMap[part.number] = part
                }
                record.parts = partMap.values.sorted { $0.number < $1.number }
                record.updatedAt = Date()
                await store.save(record)
                progress(record.bytesCompleted(totalSize: size))
            }

            try Task.checkCancellation()
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
            _ = try await throttle.run {
                try await client.completeMultipartUpload(input: input)
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
        AppLog.shared.log("Completed multipart bucket=\(bucket) key=\(key) parts=\(totalParts)")
    }

    private func uploadPart(
        client: S3Client,
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
        let output = try await throttle.run {
            try await client.uploadPart(input: finalInput)
        }
        guard let eTag = output.eTag, !eTag.isEmpty else {
            throw S3ServiceError.missingETag
        }
        return MultipartPart(number: partNumber, eTag: eTag)
    }

    private func abortMultipart(client: S3Client, bucket: String, key: String, uploadID: String) async {
        do {
            _ = try await throttle.run {
                try await client.abortMultipartUpload(input: AbortMultipartUploadInput(
                    bucket: bucket,
                    key: key,
                    uploadId: uploadID
                ))
            }
        } catch {
            AppLog.shared.error("Abort multipart failed bucket=\(bucket) key=\(key): \(String(describing: error))")
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
        _ = try await throttle.run {
            try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
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
        _ = try await throttle.run { try await client.putObject(input: finalInput) }
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
        _ = try await throttle.run {
            try await client.copyObject(input: CopyObjectInput(
                bucket: destinationBucket,
                copySource: encodedSource,
                key: destinationKey
            ))
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
