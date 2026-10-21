import Foundation

/// End-to-end harness against `scripts/fake_s3.py`. It drives the real AWS SDK
/// and BrowserModel, so listing XML, signing interception, error mapping,
/// folder markers, stale responses, caching and transfers are all exercised.
enum E2E {
    @MainActor
    private static func markerSnapshotSize(_ snapshot: FolderStatsSnapshot?) -> Int64? {
        snapshot?.record?.size
    }

    @MainActor
    static func run(port: String) {
        Task { @MainActor in
            let base = URL(string: "http://127.0.0.1:\(port)")!
            var passed = 0
            var failed = 0

            func check(_ condition: Bool, _ name: String) {
                if condition {
                    passed += 1
                    print("E2E PASS  \(name)")
                } else {
                    failed += 1
                    print("E2E FAIL  \(name)")
                }
            }

            func json(_ path: String) async -> [String: Any] {
                guard let (data, _) = try? await URLSession.shared.data(
                    from: base.appendingPathComponent(path)
                ) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }

            func stats() async -> [String: Int] {
                let raw = await json("__stats")
                return raw.compactMapValues { $0 as? Int }
            }

            func lastPut() async -> String {
                let raw = await json("__last_put")
                return raw["key"] as? String ?? ""
            }

            func lastDelete() async -> String {
                let raw = await json("__last_delete")
                return raw["key"] as? String ?? ""
            }

            func listTiming() async -> (times: [Double], maxActive: Int) {
                let raw = await json("__times")
                let times = (raw["times"] as? [NSNumber])?.map(\.doubleValue) ?? []
                return (times, raw["max_active"] as? Int ?? 0)
            }

            func resetStats() async {
                _ = try? await URLSession.shared.data(from: base.appendingPathComponent("__reset"))
            }

            func waitUntil(timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if await condition() { return true }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return await condition()
            }

            let account = Account(
                displayName: "E2E",
                accessKeyID: "test",
                kind: .compatible,
                region: "us-east-1",
                endpoint: base.absoluteString,
                usePathStyle: true,
                useSSL: false
            )
            let secret = UUID().uuidString
            let store = AccountStore(inMemoryAccounts: [account], secrets: [account.id: secret])
            let folderCacheURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("s3c-folder-stats-\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: folderCacheURL)
            let folderCache = FolderStatsCache(fileURL: folderCacheURL)
            let model = BrowserModel(accounts: store, folderStatsCache: folderCache)
            let service = S3Service.shared

            do {
                let buckets = try await service.listBuckets(
                    account: account, secret: secret, useCache: false
                )
                check(
                    Set(buckets.map(\.name)) == Set(["alpha", "beta", "denied", "fast", "slow"]),
                    "listBuckets returns the fake buckets"
                )
            } catch {
                check(false, "listBuckets failed: \(error)")
            }

            do {
                let page = try await service.list(
                    account: account, secret: secret,
                    bucket: "alpha", prefix: "", useCache: false
                )
                check(page.items.contains { $0.key == "photos/" && $0.kind == .folder },
                      "CommonPrefixes entries are folders")
                check(page.items.contains { $0.key == "marker/" && $0.kind == .folder },
                      "trailing-slash Contents markers are folders")
                check(page.items.contains { $0.key == "readme.txt" && $0.kind == .object },
                      "ordinary Contents entries are objects")
            } catch {
                check(false, "alpha listing failed: \(error)")
            }

            do {
                let details = try await service.objectDetails(
                    account: account, secret: secret, bucket: "alpha", key: "readme.txt"
                )
                check(details.contentType == "text/plain", "HeadObject content type")
                check(details.contentLength == 12, "HeadObject content length")
                check(details.metadata["owner"] == "e2e", "HeadObject user metadata")
            } catch {
                check(false, "HeadObject failed: \(error)")
            }

            do {
                let tags = try await service.objectTags(
                    account: account, secret: secret, bucket: "alpha", key: "readme.txt"
                )
                check(tags["team"] == "design", "GetObjectTagging returns tags")
            } catch {
                check(false, "GetObjectTagging failed: \(error)")
            }

            do {
                let acl = try await service.objectACL(
                    account: account, secret: secret, bucket: "alpha", key: "readme.txt"
                )
                check(acl.contains { $0.contains("FULL_CONTROL") }, "GetObjectAcl returns grants")
            } catch {
                check(false, "GetObjectAcl failed: \(error)")
            }

            do {
                let versions = try await service.versions(
                    account: account, secret: secret, bucket: "alpha", key: "readme.txt"
                )
                check(versions.count == 1 && versions[0].versionID == "v1",
                      "ListObjectVersions returns a version")
            } catch {
                check(false, "ListObjectVersions failed: \(error)")
            }

            do {
                let data = try await service.previewData(
                    account: account, secret: secret, bucket: "alpha", key: "readme.txt"
                )
                check(String(data: data, encoding: .utf8)?.contains("fake s3") == true,
                      "GetObject preview returns data")
            } catch {
                check(false, "GetObject preview failed: \(error)")
            }

            model.openLocation(accountID: account.id, bucket: "alpha", prefix: "")
            check(model.selectedBucket == "alpha", "openLocation sets the bucket immediately")
            check(model.items.isEmpty, "openLocation clears old rows immediately")
            let alphaLoaded = await waitUntil { !model.isBusy }
            check(alphaLoaded, "alpha listing completes")
            let readme = model.items.first { $0.key == "readme.txt" }
            check(readme != nil, "alpha listing contains readme.txt")
            check(model.items.contains { $0.key == "marker/" && $0.kind == .folder },
                  "model renders the trailing-slash marker as a folder")

            let photosFolder = model.items.first { $0.key == "photos/" }
            let pagedFolder = model.items.first { $0.key == "paged/" }
            let deniedFolder = model.items.first { $0.key == "deniedfolder/" }
            let markerFolder = model.items.first { $0.key == "marker/" }
            let slowFolder = model.items.first { $0.key == "slowfolder/" }
            check(photosFolder != nil && pagedFolder != nil && deniedFolder != nil && markerFolder != nil,
                  "alpha listing contains the metrics test folders")

            if let photosFolder, let pagedFolder, let deniedFolder, let markerFolder {
                model.setCalculateFolderSizes(true)
                await resetStats()
                model.requestFolderStats(for: [photosFolder, pagedFolder, deniedFolder, markerFolder])
                let metricsDone = await waitUntil {
                    model.folderSnapshot(for: "photos/")?.state == .ready
                        && model.folderSnapshot(for: "paged/")?.state == .ready
                        && model.folderSnapshot(for: "deniedfolder/")?.state == .ready
                        && model.folderSnapshot(for: "marker/")?.state == .ready
                }
                check(metricsDone, "visible folder stats complete")

                let photosSnapshot = model.folderSnapshot(for: "photos/")
                let pagedSnapshot = model.folderSnapshot(for: "paged/")
                let deniedSnapshot = model.folderSnapshot(for: "deniedfolder/")
                check(photosSnapshot?.record?.size == 600, "recursive folder size sums nested objects")
                check(photosSnapshot?.record?.objectCount == 3, "recursive folder object count")
                check(photosSnapshot?.record?.newestObjectDate != nil, "folder last modified comes from contents")
                check(pagedSnapshot?.record?.size == 150, "parent scan sums every child's objects")
                check(markerSnapshotSize(model.folderSnapshot(for: "marker/")) == 5, "marker folder size")
                check(deniedSnapshot?.record?.size == 7, "parent scan includes readable sibling prefixes")

                let counts = await stats()
                check(counts["list"] == 1, "sibling folders coalesce into one parent scan (got \(counts["list"] ?? 0))")
                check(model.folderSnapshot(for: "emptyfolder/") == nil,
                      "rows outside the visible request set are not published")
                let nestedKey = FolderStatsKey(accountID: account.id, bucket: "alpha", prefix: "photos/2026/")
                check(model.folderStats.record(for: nestedKey)?.size == 500,
                      "one parent scan also caches nested descendant stats")

                let metricCount = counts["list"] ?? 0
                model.requestFolderStats(for: [photosFolder, pagedFolder, deniedFolder, markerFolder])
                try? await Task.sleep(nanoseconds: 250_000_000)
                check((await stats())["list"] == metricCount,
                      "fresh cached folder stats are reused without requests")

                model.sort(by: .size)
                let ascending = model.items.filter { $0.kind == .folder }.map(\.key)
                let markerIndex = ascending.firstIndex(of: "marker/") ?? -1
                let pagedIndex = ascending.firstIndex(of: "paged/") ?? -1
                let photosIndex = ascending.firstIndex(of: "photos/") ?? -1
                check(markerIndex < pagedIndex && pagedIndex < photosIndex,
                      "folder size sorting uses cached computed values")
                model.sort(by: .size)
                let descending = model.items.filter { $0.kind == .folder }.map(\.key)
                check((descending.firstIndex(of: "photos/") ?? -1) < (descending.firstIndex(of: "paged/") ?? -1),
                      "folder size sorting toggles direction")

                // A denied folder must fail only when it is scanned directly;
                // a readable parent scan should not invent an error for it.
                model.folderStats.invalidate(
                    accountID: account.id, bucket: "alpha", prefix: "deniedfolder/"
                )
                await resetStats()
                model.requestFolderStats(for: [deniedFolder])
                let deniedDone = await waitUntil {
                    if case .failed = model.folderSnapshot(for: "deniedfolder/")?.state { return true }
                    return false
                }
                check(deniedDone, "denied folder scan reports a failure")
                check(model.folderSnapshot(for: "deniedfolder/")?.sizeText == "—",
                      "denied folder shows an unavailable placeholder")

                model.folderStats.invalidate(accountID: account.id, bucket: "alpha", prefix: "paged/")
                await resetStats()
                model.requestFolderStats(for: [pagedFolder])
                let pagedDone = await waitUntil {
                    model.folderSnapshot(for: "paged/")?.state == .ready
                }
                check(pagedDone && model.folderSnapshot(for: "paged/")?.record?.size == 150,
                      "targeted folder scan paginates")
                let pagedCounts = await stats()
                check(pagedCounts["list"] == 3,
                      "targeted paginated scan issues one request per page (got \(pagedCounts["list"] ?? 0))")
                let pagedTiming = await listTiming()
                let sortedTimes = pagedTiming.times.sorted()
                let gaps = zip(sortedTimes.dropFirst(), sortedTimes).map { $0 - $1 }
                check((gaps.min() ?? 1) >= 0.08,
                      "folder scan pages are paced (min gap \((gaps.min() ?? 1)))")

                // Direct scanner checks: partial cap and two-scan concurrency.
                var partialPolicy = FolderStatsPolicy()
                partialPolicy.maxObjects = 2
                let partialScanner = FolderStatsScanner(service: service, policy: partialPolicy)
                let pagedKey = FolderStatsKey(accountID: account.id, bucket: "alpha", prefix: "paged/")
                let pagedGroup = FolderStatsScanGroup(
                    accountID: account.id, bucket: "alpha", target: "paged/",
                    mode: .folder, keys: [pagedKey]
                )
                if let partialRecords = try? await partialScanner.scan(
                    group: pagedGroup, account: account, secret: secret
                ) {
                    let record = partialRecords.first { $0.prefix == "paged/" }
                    check(record?.partial == true && record?.objectCount == 2 && record?.size == 30,
                          "folder stats cap returns a partial record")
                } else {
                    check(false, "partial folder scan failed")
                }

                if let slowFolder {
                    let slowKey = FolderStatsKey(accountID: account.id, bucket: "alpha", prefix: slowFolder.key)
                    let photosKey = FolderStatsKey(accountID: account.id, bucket: "alpha", prefix: photosFolder.key)
                    let slowGroup = FolderStatsScanGroup(
                        accountID: account.id, bucket: "alpha", target: slowFolder.key,
                        mode: .folder, keys: [slowKey]
                    )
                    let photosGroup = FolderStatsScanGroup(
                        accountID: account.id, bucket: "alpha", target: photosFolder.key,
                        mode: .folder, keys: [photosKey]
                    )
                    await resetStats()
                    let scanner = FolderStatsScanner(service: service)
                    async let slowResult = scanner.scan(group: slowGroup, account: account, secret: secret)
                    async let photosResult = scanner.scan(group: photosGroup, account: account, secret: secret)
                    _ = try? await (slowResult, photosResult)
                    let timing = await listTiming()
                    check(timing.maxActive == 2,
                          "folder scanner honors the 2-request concurrency cap (got \(timing.maxActive))")
                }

                if let slowFolder {
                    await resetStats()
                    model.requestFolderStats(for: [slowFolder])
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    model.requestFolderStats(for: [])
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    check(model.folderSnapshot(for: slowFolder.key) == nil,
                          "cancelled folder scans are discarded")
                }

                // Persistent cache: a new cache/model instance must serve the
                // same values without touching the endpoint.
                folderCache.flush()
                let attributes = try? FileManager.default.attributesOfItem(atPath: folderCacheURL.path)
                let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
                check(permissions == 0o600, "folder-stats cache is 0600 (got \(String(permissions ?? 0, radix: 8)))")

                let restartedCache = FolderStatsCache(fileURL: folderCacheURL)
                let photosKey = FolderStatsKey(accountID: account.id, bucket: "alpha", prefix: "photos/")
                check(restartedCache.record(for: photosKey)?.size == 600,
                      "folder stats survive a cache store restart")

                let restartedModel = BrowserModel(accounts: store, folderStatsCache: restartedCache)
                restartedModel.openLocation(accountID: account.id, bucket: "alpha", prefix: "")
                _ = await waitUntil { !restartedModel.isBusy }
                try? await Task.sleep(nanoseconds: 200_000_000)
                await resetStats()
                if let restartedPhotos = restartedModel.items.first(where: { $0.key == "photos/" }) {
                    restartedModel.requestFolderStats(for: [restartedPhotos])
                    let cachedDone = await waitUntil {
                        restartedModel.folderSnapshot(for: "photos/")?.state == .ready
                    }
                    check(cachedDone && restartedModel.folderSnapshot(for: "photos/")?.record?.size == 600,
                          "restarted model renders cached folder stats")
                    let restartedCounts = await stats()
                    check((restartedCounts["list"] ?? 0) == 0,
                          "restarted cache renders without a folder-stat list request (got \(restartedCounts["list"] ?? 0))")
                }
                // A stale record must stay visible while one refresh runs.
                folderCache.upsert([FolderStatsRecord(
                    accountID: account.id, bucket: "alpha", prefix: "marker/",
                    size: 5, objectCount: 1, newestObjectDate: Date().addingTimeInterval(-3_600),
                    computedAt: Date().addingTimeInterval(-3_600), partial: false
                )])
                folderCache.flush()
                let staleCache = FolderStatsCache(fileURL: folderCacheURL)
                let staleModel = BrowserModel(accounts: store, folderStatsCache: staleCache)
                staleModel.openLocation(accountID: account.id, bucket: "alpha", prefix: "")
                _ = await waitUntil { !staleModel.isBusy }
                try? await Task.sleep(nanoseconds: 150_000_000)
                await resetStats()
                if let markerItem = staleModel.items.first(where: { $0.key == "marker/" }) {
                    staleModel.requestFolderStats(for: [markerItem])
                    let immediate = staleModel.folderSnapshot(for: "marker/")
                    check(immediate?.state == .refreshing && immediate?.record?.size == 5,
                          "stale cache stays visible while refreshing")
                    let refreshed = await waitUntil {
                        staleModel.folderSnapshot(for: "marker/")?.state == .ready
                    }
                    check(refreshed, "stale cache refreshes in the background")
                    check(((await stats())["list"] ?? 0) >= 1,
                          "stale refresh issued a scan")
                }
                try? FileManager.default.removeItem(at: folderCacheURL)
            }

            if let readme {
                model.setSelection([readme.key])
                await resetStats()
                await model.loadDetails(for: readme)
                await model.loadTags(for: readme)
                await model.loadACL(for: readme)
                await model.loadVersions(for: readme)
                await model.loadPreview(for: readme)
                await model.loadDetails(for: readme)
                await model.loadTags(for: readme)
                await model.loadACL(for: readme)
                await model.loadVersions(for: readme)
                await model.loadPreview(for: readme)
                let counts = await stats()
                check(counts["head"] == 1, "HeadObject fetched once (got \(counts["head"] ?? 0))")
                check(counts["tags"] == 1, "GetObjectTagging fetched once (got \(counts["tags"] ?? 0))")
                check(counts["acl"] == 1, "GetObjectAcl fetched once (got \(counts["acl"] ?? 0))")
                check(counts["versions"] == 1, "ListObjectVersions fetched once (got \(counts["versions"] ?? 0))")
                check(counts["getObject"] == 1, "preview GetObject fetched once (got \(counts["getObject"] ?? 0))")
            }

            model.openLocation(accountID: account.id, bucket: "alpha", prefix: "photos/")
            _ = await waitUntil { !model.isBusy }
            if let photo = model.items.first(where: { $0.key == "photos/a.jpg" }) {
                model.setSelection([photo.key])
                await model.loadPreview(for: photo)
                check(model.previewImage != nil, "image preview decodes image data")
                check(model.previewText == nil, "image preview does not fall back to text")
            } else {
                check(false, "fake image object is listed")
            }

            model.openLocation(accountID: account.id, bucket: "alpha", prefix: "folder/")
            _ = await waitUntil { !model.isBusy }
            await model.createFolder(named: "new")
            let created = await waitUntil { !model.isBusy }
            check(created, "folder creation reload completes")
            check(model.items.contains { $0.key == "folder/new/" && $0.kind == .folder },
                  "created folder renders as a folder, not a text file")
            let putKey = await lastPut()
            check(putKey == "folder/new/", "folder PUT key ends with / (got \(putKey))")

            do {
                try await service.delete(
                    account: account, secret: secret, bucket: "alpha", key: "folder/new/"
                )
                let deleteKey = await lastDelete()
                check(deleteKey == "folder/new/", "DeleteObject keeps the folder slash (got \(deleteKey))")
            } catch {
                check(false, "DeleteObject failed: \(error)")
            }

            model.openLocation(accountID: account.id, bucket: "denied", prefix: "")
            check(model.items.isEmpty, "denied bucket clears old rows immediately")
            let denied = await waitUntil { !model.isBusy }
            check(denied, "denied listing completes")
            check(model.selectedBucket == "denied", "denied bucket remains selected")
            check(model.items.isEmpty, "denied bucket keeps an empty table")
            check((model.errorMessage ?? "").lowercased().contains("access denied"),
                  "denied bucket maps to an Access denied message")

            await resetStats()
            model.openLocation(accountID: account.id, bucket: "slow", prefix: "")
            // Let the slow request reach the server before switching, so this
            // exercises a genuinely in-flight stale response (not cancellation).
            try? await Task.sleep(nanoseconds: 150_000_000)
            model.openLocation(accountID: account.id, bucket: "fast", prefix: "")
            let fast = await waitUntil { !model.isBusy }
            check(fast, "fast bucket completes")
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            check(model.selectedBucket == "fast", "late slow response does not change the bucket")
            check(model.items.contains { $0.key == "fast-item.txt" }, "fast rows survive the slow response")
            check(!model.items.contains { $0.key == "slow-item.txt" }, "slow rows are discarded")
            let staleCounts = await stats()
            check((staleCounts["list"] ?? 0) == 2,
                  "two bucket switches issued two list requests (got \(staleCounts["list"] ?? 0))")

            await resetStats()
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        _ = try? await service.list(
                            account: account, secret: secret, bucket: "throttle",
                            prefix: "\(index)/", useCache: false
                        )
                    }
                }
            }
            let globalTiming = await listTiming()
            check(globalTiming.maxActive <= 4,
                  "global list throttle caps at 4 (got \(globalTiming.maxActive))")

            await resetStats()
            model.openLocation(accountID: account.id, bucket: "alpha", prefix: "")
            let cached = await waitUntil { !model.isBusy }
            let cacheCounts = await stats()
            check(cached, "cached alpha listing completes")
            check((cacheCounts["list"] ?? 0) == 0, "repeat alpha listing used the 60s cache")

            model.openLocation(accountID: account.id, bucket: "beta", prefix: "beta-folder/")
            let beta = await waitUntil { !model.isBusy }
            check(beta, "cross-bucket folder listing completes")
            check(model.selectedBucket == "beta", "cross-bucket folder switches the bucket")
            check(model.prefix == "beta-folder/", "cross-bucket folder keeps the full prefix")
            check(model.items.contains { $0.key == "beta-folder/item.txt" },
                  "cross-bucket folder lists its own objects")

            model.openLocation(accountID: account.id, bucket: "alpha", prefix: "")
            _ = await waitUntil { !model.isBusy }
            if let readme = model.items.first(where: { $0.key == "readme.txt" }) {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("s3c-e2e-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                model.download(items: [readme], to: directory)
                let target = directory.appendingPathComponent("readme.txt")
                var downloaded = false
                for _ in 0..<80 {
                    if FileManager.default.fileExists(atPath: target.path) { downloaded = true; break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                check(downloaded, "download writes the object to disk")
                if downloaded {
                    check((try? String(contentsOf: target, encoding: .utf8))?.contains("fake s3") == true,
                          "downloaded bytes match the server")
                }
                try? FileManager.default.removeItem(at: directory)
            }

            let uploadURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("e2e-upload-\(UUID().uuidString).txt")
            try? "uploaded by e2e".write(to: uploadURL, atomically: true, encoding: .utf8)
            model.upload(urls: [uploadURL])
            var uploaded = false
            for _ in 0..<80 {
                let key = await lastPut()
                if key.hasSuffix(uploadURL.lastPathComponent) { uploaded = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            check(uploaded, "upload PUTs the object under the current prefix")
            try? FileManager.default.removeItem(at: uploadURL)

            print("E2E SUMMARY passed=\(passed) failed=\(failed)")
            exit(failed == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }
}
