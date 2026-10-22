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
            usePathStyle: pathStyle,
            useSSL: useSSL
        )
        let store = AccountStore(inMemoryAccounts: [account], secrets: [account.id: secret])
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
            guard let objects = try? await service.listAllObjects(
                account: account, secret: secret, bucket: bucket, prefix: prefix
            ) else { return }
            for object in objects where object.kind == .object {
                try? await service.delete(
                    account: account, secret: secret, bucket: bucket, key: object.key
                )
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

            let buckets = try await service.listBuckets(account: account, secret: secret, useCache: false)
            check(buckets.contains { $0.name == bucket }, "bucket appears in ListBuckets")

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
            let uploaded = await waitUntil {
                model.transfers.tasks.contains {
                    $0.key == prefix + uploadURL.lastPathComponent && $0.status == .completed
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

            let details = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            check(details.contentLength == Int64(uploadBody.utf8.count), "HeadObject reports the uploaded size")

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

            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: copyKey
            )
            try await service.delete(
                account: account, secret: secret, bucket: bucket, key: renamedKey
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
