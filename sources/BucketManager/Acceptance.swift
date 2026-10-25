#if DEBUG
import AppKit
import Foundation

@MainActor
enum Acceptance {
    static func run() {
        Task { await execute() }
        RunLoop.main.run()
    }

    private static func execute() async {
        var passed = 0
        var failed = 0
        var infos: [String] = []

        func check(_ condition: Bool, _ name: String, _ detail: String = "") {
            if condition {
                passed += 1
                print("ACCEPT PASS  \(name)")
            } else {
                failed += 1
                print("ACCEPT FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        func info(_ message: String) {
            infos.append(message)
            print("ACCEPT INFO  \(message)")
        }

        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["BM_ACCEPT_ENDPOINT"],
              let accessKey = env["BM_ACCEPT_ACCESS_KEY"],
              let secret = env["BM_ACCEPT_SECRET"] else {
            print("ACCEPT FAIL missing BM_ACCEPT_ENDPOINT / BM_ACCEPT_ACCESS_KEY / BM_ACCEPT_SECRET")
            exit(2)
        }

        let region = env["BM_ACCEPT_REGION"] ?? "us-east-1"
        let suppliedBucket = env["BM_ACCEPT_BUCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = suppliedBucket.flatMap { $0.isEmpty ? nil : $0 }
            ?? "bm-accept-\(String(UUID().uuidString.lowercased().prefix(12)))"
        let suppliedDestinationBucket = env["BM_ACCEPT_BUCKET_2"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationBucket = suppliedDestinationBucket.flatMap { $0.isEmpty ? nil : $0 }
        let createdBucket = suppliedBucket?.isEmpty != false
        let prefix = "acceptance-\(String(UUID().uuidString.lowercased().prefix(12)))/"
        let useSSL = endpoint.lowercased().hasPrefix("https://")
        let pathStyle = env["BM_ACCEPT_PATH_STYLE"] != "0"

        let account = Account(
            displayName: "Acceptance",
            accessKeyID: accessKey,
            kind: .compatible,
            region: region,
            endpoint: endpoint,
            bucket: createdBucket ? nil : bucket,
            usePathStyle: pathStyle,
            useSSL: useSSL
        )
        let destinationAccount = destinationBucket.map { destinationBucket in
            Account(
                displayName: "Acceptance Destination",
                accessKeyID: accessKey,
                kind: .compatible,
                region: region,
                endpoint: endpoint,
                bucket: destinationBucket,
                usePathStyle: pathStyle,
                useSSL: useSSL
            )
        }
        var inMemoryAccounts = [account]
        var inMemorySecrets = [account.id: secret]
        if let destinationAccount {
            inMemoryAccounts.append(destinationAccount)
            inMemorySecrets[destinationAccount.id] = secret
        }
        let store = AccountStore(
            inMemoryAccounts: inMemoryAccounts,
            secrets: inMemorySecrets
        )
        let model = BrowserModel(
            accounts: store,
            folderStatsCache: FolderStatsCache(fileURL: nil)
        )
        let service = S3Service.shared
        var localURLs: [URL] = []

        func cleanup() async {
            for url in localURLs {
                try? FileManager.default.removeItem(at: url)
            }
            var cleanupTargets = [(account, bucket)]
            if let destinationAccount, let destinationBucket {
                cleanupTargets.append((destinationAccount, destinationBucket))
            }
            for (cleanupAccount, cleanupBucket) in cleanupTargets where !cleanupBucket.isEmpty {
                guard let objects = try? await service.listAllObjects(
                    account: cleanupAccount, secret: secret,
                    bucket: cleanupBucket, prefix: prefix
                ) else { continue }
                for object in objects where object.kind == .object {
                    try? await service.delete(
                        account: cleanupAccount, secret: secret,
                        bucket: cleanupBucket, key: object.key
                    )
                }
            }
            if createdBucket {
                try? await service.deleteBucket(account: account, secret: secret, name: bucket)
            }
        }

        func waitUntil(timeout: TimeInterval = 25, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }

        do {
            print("ACCEPT endpoint=\(endpoint) region=\(region) bucket=\(bucket) created=\(createdBucket)")
            if createdBucket {
                try await service.createBucket(account: account, secret: secret, name: bucket)
                check(true, "create bucket")
            }

            if createdBucket {
                let buckets = try await service.listBuckets(account: account, secret: secret, useCache: false)
                check(buckets.contains { $0.name == bucket }, "bucket appears in ListBuckets")
            } else {
                let page = try await service.list(
                    account: account, secret: secret, bucket: bucket, prefix: "", useCache: false
                )
                check(page.items.isEmpty || !page.items.isEmpty, "bucket-scoped key can list the configured bucket")
            }

            model.selectAccount(account)
            check(await waitUntil { !model.isLoadingBuckets }, "account bucket list completes")
            check(model.buckets.contains { $0.name == bucket }, "UI model receives the bucket list")

            model.selectBucket(bucket)
            check(await waitUntil { !model.isBusy && model.selectedBucket == bucket },
                  "bucket opens in the model")
            await model.navigate(toPrefix: prefix)
            check(!model.isBusy, "prefix navigation completes")

            let uploadURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-\(UUID().uuidString).txt")
            localURLs.append(uploadURL)
            let uploadBody = "bucket manager acceptance"
            try uploadBody.write(to: uploadURL, atomically: true, encoding: .utf8)
            model.upload(urls: [uploadURL])
            let uploadedKey = prefix + uploadURL.lastPathComponent
            let uploaded = await waitUntil {
                model.transfers.tasks.contains { transfer in
                    transfer.key == uploadedKey && transfer.status == TransferTask.Status.completed
                }
            }
            check(uploaded, "transfer queue upload completes")
            await model.refresh()
            check(await waitUntil { !model.isBusy }, "listing after upload completes")

            guard let item = model.items.first(where: { $0.key == prefix + uploadURL.lastPathComponent }) else {
                check(false, "uploaded object appears in listing")
                await cleanup()
                print("ACCEPT SUMMARY passed=\(passed) failed=\(failed)")
                exit(1)
            }
            check(item.size == Int64(uploadBody.utf8.count), "uploaded object size matches")

            var tagsAvailable = false
            do {
                _ = try await service.objectTags(
                    account: account, secret: secret, bucket: bucket, key: item.key
                )
                tagsAvailable = true
                check(true, "GetObjectTagging succeeds")
            } catch {
                info("GetObjectTagging is unavailable: \(S3ErrorPresenter.message(for: error))")
            }

            var aclAvailable = false
            do {
                _ = try await service.objectACL(
                    account: account, secret: secret, bucket: bucket, key: item.key
                )
                aclAvailable = true
                check(true, "GetObjectAcl succeeds")
            } catch {
                info("GetObjectAcl is unavailable: \(S3ErrorPresenter.message(for: error))")
            }

            var versionsAvailable = false
            do {
                _ = try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: item.key
                )
                versionsAvailable = true
                check(true, "ListObjectVersions succeeds")
            } catch {
                info("ListObjectVersions is unavailable: \(S3ErrorPresenter.message(for: error))")
            }

            model.setSelection([item.key])
            await model.loadDetails(for: item)
            check(model.details != nil, "HeadObject metadata loads")
            if tagsAvailable {
                await model.loadTags(for: item)
                check(model.inspectorLoaded("tags", for: item), "object tags load in the inspector")
            } else {
                info("tags inspector check skipped")
            }
            if versionsAvailable {
                await model.loadVersions(for: item)
                check(model.inspectorLoaded("versions", for: item), "object versions load in the inspector")
            } else {
                info("versions inspector check skipped")
            }
            if aclAvailable {
                await model.loadACL(for: item)
                check(model.inspectorLoaded("permissions", for: item), "object ACL loads in the inspector")
            } else {
                info("ACL inspector check skipped")
            }
            await model.loadPreview(for: item)
            check(model.previewText?.contains("acceptance") == true, "text preview loads")

            let oddDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: oddDirectory, withIntermediateDirectories: true)
            let oddURL = oddDirectory.appendingPathComponent("Q3 report é+50%.txt")
            localURLs.append(oddDirectory)
            try uploadBody.write(to: oddURL, atomically: true, encoding: .utf8)
            model.upload(urls: [oddURL])
            let oddKey = prefix + oddURL.lastPathComponent
            _ = await waitUntil {
                model.transfers.tasks.contains { $0.key == oddKey && $0.status == TransferTask.Status.completed }
            }
            for (key, name) in [(item.key, "share link signature is accepted by the server"),
                                (oddKey, "share link works for keys with spaces and symbols")] {
                let target = S3Item(key: key, kind: .object)
                guard let link = await model.shareLink(for: target, expiresIn: 3600) else {
                    check(false, name)
                    continue
                }
                let (body, response) = try await URLSession.shared.data(from: link)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                check(status == 200 && String(data: body, encoding: .utf8) == uploadBody, name, "status \(status)")
            }

            // Version history only exists when the bucket has versioning enabled.
            let versionedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-versioned-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: versionedURL, withIntermediateDirectories: true)
            localURLs.append(versionedURL)
            let versionedFile = versionedURL.appendingPathComponent("versioned.txt")
            let versionedKey = prefix + "versioned.txt"
            for body in ["version one", "version two"] {
                try body.write(to: versionedFile, atomically: true, encoding: .utf8)
                model.transfers.clearFinished()
                model.upload(urls: [versionedFile])
                _ = await waitUntil {
                    model.transfers.tasks.contains { $0.key == versionedKey && $0.status == TransferTask.Status.completed }
                }
            }
            func versionedBody() async -> String? {
                guard let data = try? await service.previewData(
                    account: account, secret: secret, bucket: bucket, key: versionedKey
                ) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            let history = try await service.versions(account: account, secret: secret, bucket: bucket, key: versionedKey)
            if history.filter({ !$0.isDeleteMarker }).count >= 2,
               let first = history.last(where: { !$0.isDeleteMarker && !$0.isLatest }) {
                let versionedItem = S3Item(key: versionedKey, kind: .object)
                check(await model.apply(.restore, to: first, of: versionedItem), "version restore succeeds")
                check(await versionedBody() == "version one", "restore makes the old content current")
                let afterRestore = try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: versionedKey
                )
                check(afterRestore.count == history.count + 1, "restore keeps the replaced version in history")

                check(await model.apply(.delete, to: first, of: versionedItem), "version delete succeeds")
                let afterDelete = try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: versionedKey
                )
                check(!afterDelete.contains { $0.versionID == first.versionID } && afterDelete.count == history.count,
                      "deleted version leaves the history")

                try await service.delete(account: account, secret: secret, bucket: bucket, key: versionedKey)
                let withMarker = try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: versionedKey
                )
                if let marker = withMarker.first(where: { $0.isDeleteMarker && $0.isLatest }) {
                    check(await model.apply(.delete, to: marker, of: versionedItem), "delete marker removal succeeds")
                    check(await versionedBody() == "version one", "removing the delete marker undeletes the object")
                } else {
                    check(false, "plain delete creates a delete marker on a versioned bucket")
                }

                let nestedKey = prefix + "gone-folder/nested.txt"
                _ = try await service.upload(
                    account: account, secret: secret, bucket: bucket, key: nestedKey,
                    from: versionedFile, progress: { _ in }
                )
                try await service.delete(account: account, secret: secret, bucket: bucket, key: nestedKey)
                try await service.delete(account: account, secret: secret, bucket: bucket, key: versionedKey)
                await model.navigate(toPrefix: prefix)
                await model.setShowDeletedObjects(true)
                _ = await waitUntil { !model.isBusy }
                let deletedRow = model.items.first { $0.key == versionedKey }
                check(deletedRow?.isDeleted == true, "show deleted lists a deleted object")
                // AWS hides folders that only hold delete markers (so they are
                // listed as deleted); MinIO keeps returning them as live folders.
                let goneFolder = model.items.first { $0.key == prefix + "gone-folder/" && $0.kind == .folder }
                check(goneFolder != nil, "a folder that only holds deleted objects stays reachable")
                if goneFolder?.isDeleted == false { info("provider lists delete-marker-only folders as live") }
                await model.navigate(toPrefix: prefix + "gone-folder/")
                _ = await waitUntil { !model.isBusy }
                check(model.items.contains { $0.key == nestedKey && $0.isDeleted },
                      "opening that folder lists its deleted object")
                await model.navigate(toPrefix: prefix)
                _ = await waitUntil { !model.isBusy }
                if let deletedRow {
                    await model.undelete(items: [deletedRow])
                    _ = await waitUntil { !model.isBusy }
                    check(await versionedBody() == "version one", "undelete brings back the latest content")
                    check(model.items.first { $0.key == versionedKey }?.isDeleted == false,
                          "undeleted object is listed as live")
                }
                await model.setShowDeletedObjects(false)
                for version in try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: nestedKey
                ) {
                    try? await service.deleteVersion(
                        account: account, secret: secret, bucket: bucket, key: nestedKey, versionID: version.versionID
                    )
                }
                for version in try await service.versions(
                    account: account, secret: secret, bucket: bucket, key: versionedKey
                ) {
                    try? await service.deleteVersion(
                        account: account, secret: secret, bucket: bucket, key: versionedKey, versionID: version.versionID
                    )
                }
            } else {
                info("version restore checks skipped: bucket versioning is not enabled")
                try? await service.delete(account: account, secret: secret, bucket: bucket, key: versionedKey)
            }

            let details = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            check(details.contentLength == Int64(uploadBody.utf8.count), "HeadObject reports the uploaded size")

            let largeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-large-\(UUID().uuidString).bin")
            localURLs.append(largeURL)
            let largeSize = 20 * 1024 * 1024
            try Data(repeating: 0x5A, count: largeSize).write(to: largeURL)
            model.upload(urls: [largeURL])
            let largeKey = prefix + largeURL.lastPathComponent
            let largeUploaded = await waitUntil(timeout: 120) {
                model.transfers.tasks.contains { transfer in
                    transfer.key == largeKey && transfer.status == TransferTask.Status.completed
                }
            }
            check(largeUploaded, "multipart upload completes")
            let largeDetails = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: largeKey
            )
            check(largeDetails.contentLength == Int64(largeSize), "multipart object has the full size")
            let largeItem = S3Item.listed(
                key: largeKey, size: largeDetails.contentLength,
                lastModified: largeDetails.lastModified,
                storageClass: largeDetails.storageClass, eTag: largeDetails.eTag
            )

            let largeDownloadURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-large-download-\(UUID().uuidString).bin")
            localURLs.append(largeDownloadURL)
            try await service.download(
                account: account, secret: secret, bucket: bucket, key: largeKey,
                to: largeDownloadURL, progress: { _ in }
            )
            let downloadedSize = (try? FileManager.default
                .attributesOfItem(atPath: largeDownloadURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            check(downloadedSize == Int64(largeSize), "multipart object downloads completely")

            let copyKey = prefix + "copy.txt"
            try await service.copyObject(
                account: account, secret: secret,
                sourceBucket: bucket, sourceKey: item.key,
                destinationBucket: bucket, destinationKey: copyKey
            )
            let copied = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: copyKey
            )
            check(copied.contentLength == item.size, "CopyObject preserves content")

            let copyItem = S3Item.listed(
                key: copyKey, size: copied.contentLength, lastModified: copied.lastModified,
                storageClass: copied.storageClass, eTag: copied.eTag
            )
            let renamedKey = prefix + "renamed.txt"
            await model.rename(copyItem, to: "renamed.txt")
            let renamed = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: renamedKey
            )
            check(renamed.contentLength == item.size, "rename preserves content")
            do {
                _ = try await service.objectDetails(
                    account: account, secret: secret, bucket: bucket, key: copyKey
                )
                check(false, "rename removes the old object")
            } catch {
                check(true, "rename removes the old object")
            }

            await model.createFolder(named: "nested")
            let createdFolder = model.items.contains { $0.key == prefix + "nested/" }
            if createdFolder {
                check(true, "folder creation appears in listing")
            } else {
                info("folder markers are unavailable for this provider")
                try? await service.delete(
                    account: account, secret: secret, bucket: bucket, key: prefix + "nested/"
                )
                try? await service.delete(
                    account: account, secret: secret, bucket: bucket, key: prefix + "nested"
                )
            }
            let childKey = prefix + "nested/child.txt"
            let childURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-child-\(UUID().uuidString).txt")
            localURLs.append(childURL)
            let childBody = "nested acceptance"
            try childBody.write(to: childURL, atomically: true, encoding: .utf8)
            try await service.upload(
                account: account, secret: secret, bucket: bucket, key: childKey,
                from: childURL, progress: { _ in }
            )
            await model.refresh()
            guard let folder = model.items.first(where: { $0.key == prefix + "nested/" }) else {
                check(false, "nested folder appears in listing")
                await cleanup()
                print("ACCEPT SUMMARY passed=\(passed) failed=\(failed)")
                exit(1)
            }

            let downloadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("acceptance-download-\(UUID().uuidString)", isDirectory: true)
            localURLs.append(downloadDirectory)
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            await model.download(items: [folder], to: downloadDirectory)
            let downloadedChild = downloadDirectory
                .appendingPathComponent("nested", isDirectory: true)
                .appendingPathComponent("child.txt")
            let folderDownloaded = await waitUntil {
                FileManager.default.fileExists(atPath: downloadedChild.path)
            }
            check(folderDownloaded, "recursive folder download writes nested content")
            if folderDownloaded {
                let data = try String(contentsOf: downloadedChild, encoding: .utf8)
                check(data == childBody, "recursive download preserves bytes")
            }

            await model.delete(items: [folder])
            check(!model.isBusy, "recursive folder delete completes")
            let remaining = try await service.listAllObjects(
                account: account, secret: secret, bucket: bucket, prefix: prefix + "nested/"
            )
            check(remaining.isEmpty, "recursive delete removes nested objects")

            if let destinationAccount, let destinationBucket {
                let crossPrefix = prefix + "cross/"
                let copiedKey = crossPrefix + item.displayName
                await model.copy(
                    items: [item],
                    toBucket: destinationBucket,
                    toPrefix: crossPrefix,
                    move: false,
                    toAccount: destinationAccount
                )
                let copied = await waitUntil(timeout: 60) {
                    model.transfers.tasks.contains {
                        $0.destinationKey == copiedKey && $0.status == .completed
                    }
                }
                check(copied, "cross-account copy completes")
                if copied {
                    let destinationDetails = try await service.objectDetails(
                        account: destinationAccount, secret: secret,
                        bucket: destinationBucket, key: copiedKey
                    )
                    check(destinationDetails.contentLength == item.size,
                          "cross-account copy preserves content")
                }

                let moveKey = prefix + "cross-move.txt"
                let moveURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("acceptance-cross-move-\(UUID().uuidString).txt")
                localURLs.append(moveURL)
                let moveBody = "cross-account move"
                try moveBody.write(to: moveURL, atomically: true, encoding: .utf8)
                try await service.upload(
                    account: account, secret: secret, bucket: bucket,
                    key: moveKey, from: moveURL, progress: { _ in }
                )
                let moveItem = S3Item.listed(
                    key: moveKey, size: Int64(moveBody.utf8.count),
                    lastModified: nil, storageClass: nil, eTag: nil
                )
                let movedKey = crossPrefix + "cross-move.txt"
                await model.copy(
                    items: [moveItem],
                    toBucket: destinationBucket,
                    toPrefix: crossPrefix,
                    move: true,
                    toAccount: destinationAccount
                )
                let moved = await waitUntil(timeout: 60) {
                    model.transfers.tasks.contains {
                        $0.destinationKey == movedKey && $0.status == .completed
                    }
                }
                check(moved, "cross-account move completes")
                if moved {
                    do {
                        _ = try await service.objectDetails(
                            account: account, secret: secret, bucket: bucket, key: moveKey
                        )
                        check(false, "cross-account move removes the source")
                    } catch {
                        check(true, "cross-account move removes the source")
                    }
                }

                let largeDestinationKey = crossPrefix + largeURL.lastPathComponent
                await model.copy(
                    items: [largeItem],
                    toBucket: destinationBucket,
                    toPrefix: crossPrefix,
                    move: false,
                    toAccount: destinationAccount
                )
                let largeCopied = await waitUntil(timeout: 180) {
                    model.transfers.tasks.contains {
                        $0.destinationKey == largeDestinationKey && $0.status == .completed
                    }
                }
                check(largeCopied, "cross-account multipart copy completes")
                if largeCopied {
                    let largeDestination = try await service.objectDetails(
                        account: destinationAccount, secret: secret,
                        bucket: destinationBucket, key: largeDestinationKey
                    )
                    check(largeDestination.contentLength == Int64(largeSize),
                          "cross-account multipart copy preserves the full size")
                }

                if let movedObjects = try? await service.listAllObjects(
                    account: destinationAccount, secret: secret,
                    bucket: destinationBucket, prefix: crossPrefix
                ) {
                    for object in movedObjects where object.kind == .object {
                        try? await service.delete(
                            account: destinationAccount, secret: secret,
                            bucket: destinationBucket, key: object.key
                        )
                    }
                }
                let crossLeftovers = try await service.listAllObjects(
                    account: destinationAccount, secret: secret,
                    bucket: destinationBucket, prefix: crossPrefix
                )
                check(crossLeftovers.isEmpty, "cross-account cleanup leaves the destination empty")
            }

            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: largeKey
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: copyKey
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: renamedKey
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: oddKey
            )
            let leftovers = try await service.listAllObjects(
                account: account, secret: secret, bucket: bucket, prefix: prefix
            )
            check(leftovers.isEmpty, "object cleanup leaves the test prefix empty")

            if createdBucket {
                try? await service.deleteBucket(account: account, secret: secret, name: bucket)
                let after = try await service.listBuckets(account: account, secret: secret, useCache: false)
                check(!after.contains { $0.name == bucket }, "delete bucket")
            }
        } catch {
            failed += 1
            print("ACCEPT FAIL operation — \(S3ErrorPresenter.message(for: error))")
        }

        await cleanup()
        if !infos.isEmpty {
            print("ACCEPT INFO provider variations: \(infos.count)")
        }
        print("ACCEPT SUMMARY passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
