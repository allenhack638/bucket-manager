import AppKit
import Foundation

@MainActor
final class BrowserModel {
    enum SortColumn: String {
        case name, size, type, modified, storage, etag
    }

    struct ClipboardItem: Sendable {
        let accountID: UUID
        let bucket: String
        let key: String
    }

    let accounts: AccountStore
    let transfers: TransferQueue
    let folderStats: FolderStatsCoordinator
    private(set) var isDemoData = false
    private let service = S3Service.shared

    var onTreeChange: (() -> Void)?
    var onFilesChange: (() -> Void)?
    var onChromeChange: (() -> Void)?
    var onTransferChange: (() -> Void)?
    var onDetailsChange: (() -> Void)?
    var onLogChange: (() -> Void)?
    var onFolderMetric: ((String) -> Void)?

    private(set) var buckets: [S3Bucket] = []

    private(set) var selectedAccount: Account?
    private(set) var selectedBucket: String?
    private(set) var prefix: String = ""

    private(set) var items: [S3Item] = []
    private(set) var filterText = ""
    private(set) var nextToken: String?
    private(set) var isTruncated = false
    private(set) var selection: Set<String> = []
    private(set) var checked: Set<String> = []

    private(set) var isBusy = false
    private(set) var isLoadingBuckets = false
    private(set) var status = "Ready"
    private(set) var bucketError: String?
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?

    private(set) var details: ObjectDetails?
    private(set) var versions: [ObjectVersion] = []
    private(set) var acl: [String] = []
    private(set) var previewText: String?
    private(set) var previewImage: NSImage?

    private(set) var logs: [String] = []

    var calculateFolderSizes: Bool = true {
        didSet {
            UserDefaults.standard.set(calculateFolderSizes, forKey: "BucketManagerCalculateFolderSizes")
        }
    }

    private var sortColumn: SortColumn = .name
    private var sortAscending = true
    private var clipboard: [ClipboardItem] = []
    private var clipboardIsCut = false

    private var listingRequestID = 0
    private var bucketRequestID = 0
    private var sortRefreshScheduled = false
    private var detailsKey: String?
    private var versionsKey: String?
    private var aclKey: String?
    private(set) var tagsKey: String?
    private var previewKey: String?
    private(set) var tags: [String: String] = [:]

    private var detailsCache: [String: (details: ObjectDetails, at: Date)] = [:]
    private var tagsCache: [String: (tags: [String: String], at: Date)] = [:]
    private let metadataTTL: TimeInterval = 60
    private let metadataCacheLimit = 40
    private var inflightDetails: Set<String> = []
    private var inflightVersions: Set<String> = []
    private var inflightACL: Set<String> = []
    private var inflightTags: Set<String> = []
    private var inflightPreview: Set<String> = []

    init(
        accounts: AccountStore,
        folderStatsCache: FolderStatsCache = FolderStatsCache()
    ) {
        self.accounts = accounts
        self.transfers = TransferQueue(credentialProvider: { id in
            guard let account = accounts.account(id: id),
                  let secret = try? accounts.secret(for: account) else { return nil }
            return (account, secret)
        })
        self.folderStats = FolderStatsCoordinator(
            cache: folderStatsCache,
            scanner: FolderStatsScanner(service: S3Service.shared)
        )
        let defaults = UserDefaults.standard
        if let current = defaults.object(forKey: "BucketManagerCalculateFolderSizes") as? Bool {
            self.calculateFolderSizes = current
        } else if let legacy = defaults.object(forKey: "\(LegacyImport.defaultsPrefix)CalculateFolderSizes") as? Bool {
            self.calculateFolderSizes = legacy
            defaults.set(legacy, forKey: "BucketManagerCalculateFolderSizes")
        } else {
            self.calculateFolderSizes = true
        }
        transfers.onChange = { [weak self] in self?.onTransferChange?() }
        transfers.onLog = { [weak self] message in self?.appendLog(message) }
        transfers.onFinished = { [weak self] in
            guard let self else { return }
            Task { await self.refreshAfterTransfer() }
        }
        reloadAccounts()
        folderStats.onSnapshots = { [weak self] snapshots in
            guard let self else { return }
            for snapshot in snapshots {
                self.onFolderMetric?(snapshot.key.prefix)
            }
            if self.sortColumn == .size || self.sortColumn == .modified {
                guard !self.sortRefreshScheduled else { return }
                self.sortRefreshScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.sortRefreshScheduled = false
                    let before = self.items.map(\.key)
                    self.sortItems()
                    if self.items.map(\.key) != before {
                        self.onFilesChange?()
                    }
                }
            }
            self.onChromeChange?()
        }
    }

    // MARK: - Derived state

    var selectedItem: S3Item? {
        guard let key = selection.first else { return nil }
        return items.first { $0.key == key }
    }

    var selectedItems: [S3Item] { items.filter { selection.contains($0.key) } }

    var visibleItems: [S3Item] {
        guard !filterText.isEmpty else { return items }
        return items.filter {
            $0.displayName.localizedCaseInsensitiveContains(filterText)
                || $0.key.localizedCaseInsensitiveContains(filterText)
        }
    }

    var isFiltering: Bool { !filterText.isEmpty }

    var hasAccounts: Bool { !accounts.accounts.isEmpty }

    var currentPath: String {
        guard let selectedBucket else { return "" }
        return prefix.isEmpty ? "/\(selectedBucket)/" : "/\(selectedBucket)/\(prefix)"
    }

    func folderKey(for item: S3Item) -> FolderStatsKey? {
        guard item.kind == .folder, let account = selectedAccount, let bucket = selectedBucket else {
            return nil
        }
        return FolderStatsKey(accountID: account.id, bucket: bucket, prefix: item.key)
    }

    func folderSnapshot(for key: String) -> FolderStatsSnapshot? {
        guard let account = selectedAccount, let bucket = selectedBucket else { return nil }
        return folderStats.snapshot(
            for: FolderStatsKey(accountID: account.id, bucket: bucket, prefix: key)
        )
    }

    func sizeForDisplay(_ item: S3Item) -> Int64? {
        if item.kind == .object { return item.size }
        guard let key = folderKey(for: item) else { return nil }
        return folderStats.record(for: key)?.size
    }

    func modifiedForDisplay(_ item: S3Item) -> Date? {
        if item.kind == .object { return item.lastModified }
        guard let key = folderKey(for: item) else { return nil }
        return folderStats.record(for: key)?.newestObjectDate
    }

    func sizeText(for item: S3Item) -> String {
        if item.kind == .object { return item.size?.byteString ?? "" }
        return folderSnapshot(for: item.key)?.sizeText ?? ""
    }

    func modifiedText(for item: S3Item) -> String {
        if item.kind == .object { return item.lastModified?.s3ListString ?? "" }
        return folderSnapshot(for: item.key)?.modifiedText ?? ""
    }

    func folderTooltip(for item: S3Item) -> String? {
        guard item.kind == .folder else { return nil }
        return folderSnapshot(for: item.key)?.tooltip
    }

    var statusText: String {
        guard selectedBucket != nil else { return errorMessage ?? status }
        if errorMessage != nil, items.isEmpty { return "" }
        let visible = visibleItems
        let total = visible.reduce(Int64(0)) { $0 + (sizeForDisplay($1) ?? 0) }
        let count = visible.count
        let noun = count == 1 ? "file" : "files"
        var text: String
        if isFiltering {
            text = "\(count) of \(items.count) \(noun) (\(total.byteString))"
        } else {
            text = "\(count) \(noun) (\(total.byteString))"
        }
        if !selection.isEmpty {
            text += ", \(selection.count) file\(selection.count == 1 ? "" : "s") selected"
        }
        return text
    }

    var summaryText: String {
        let total = transfers.totalBytes
        let done = transfers.doneBytes
        let speed = transfers.aggregateSpeed
        let time = Self.durationString(transfers.tasks.reduce(0) { $0 + $1.elapsed })
        return "All (\(transfers.tasks.count))  ·  \(done.byteString) / \(total.byteString)  ·  \(speed.rateString)  ·  \(time)"
    }

    var summaryCompactText: String {
        let total = transfers.totalBytes
        let done = transfers.doneBytes
        let speed = transfers.aggregateSpeed
        return "All (\(transfers.tasks.count))  ·  \(done.byteString) / \(total.byteString)  ·  \(speed.rateString)"
    }

    static func durationString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Accounts / buckets

    func loadDemoData() {
        isDemoData = true
        let demo = Account(
            id: UUID(),
            displayName: "Amazon S3 Storage",
            accessKeyID: "EXAMPLE_ACCESS_KEY",
            kind: .amazonS3,
            region: "us-east-1"
        )
        selectedAccount = demo
        filterText = ""
        buckets = ["analytics-data", "app-logs", "archive", "backups-2026", "customer-uploads", "documents", "media-library", "my-backups", "my-photos", "data-lake", "photos", "production-data", "reports", "demo-storage", "static-content", "tests"].map { S3Bucket(name: $0, creationDate: Date()) }
        selectedBucket = "my-photos"
        prefix = ""

        let base = Date().addingTimeInterval(-30 * 86_400)
        items = [
            S3Item(key: "originals/", kind: .folder),
            S3Item(key: "thumbnails/", kind: .folder),
            S3Item(key: "Border_1px_Border.expected.png", kind: .object, size: 2_421_760, lastModified: base, storageClass: "STANDARD", eTag: "a1b2c3"),
            S3Item(key: "Border_2px_Border.expected.png", kind: .object, size: 3_890_204, lastModified: base, storageClass: "STANDARD", eTag: "d4e5f6"),
            S3Item(key: "Border_Bottom_Aligns_Content.expected.png", kind: .object, size: 5_746_688, lastModified: base, storageClass: "STANDARD", eTag: "g7h8i9"),
            S3Item(key: "Border_Brush_Offsets_Content.expected.png", kind: .object, size: 832_102, lastModified: base, storageClass: "STANDARD", eTag: "j1k2l3"),
            S3Item(key: "Border_Centers_Content_Horizontally.expected.png", kind: .object, size: 4_852_736, lastModified: base, storageClass: "STANDARD", eTag: "m4n5o6"),
            S3Item(key: "Border_Centers_Content_Vertically.expected.png", kind: .object, size: 15_421, lastModified: base, storageClass: "STANDARD", eTag: "p7q8r9"),
            S3Item(key: "Border_Fill.expected.png", kind: .object, size: 918_528, lastModified: base, storageClass: "STANDARD", eTag: "s1t2u3"),
            S3Item(key: "Border_Left_Aligns_Content.expected.png", kind: .object, size: 28_355, lastModified: base, storageClass: "STANDARD", eTag: "v4w5x6"),
            S3Item(key: "Border_Margin_Offsets_Content.expected.png", kind: .object, size: 46_284_800, lastModified: base, storageClass: "STANDARD_IA", eTag: "y7z8a9"),
            S3Item(key: "Border_Nested_Rotate.expected.png", kind: .object, size: 8_939, lastModified: base, storageClass: "STANDARD", eTag: "b1c2d3"),
            S3Item(key: "Border_NonUniform_CornerRadius.expected.png", kind: .object, size: 63_867_904, lastModified: base, storageClass: "INTELLIGENT_TIERING", eTag: "e4f5g6"),
            S3Item(key: "Border_Padding_Offsets_Content.expected.png", kind: .object, size: 5_222, lastModified: base, storageClass: "STANDARD", eTag: "h7i8j9"),
            S3Item(key: "Border_Right_Aligns_Content.expected.png", kind: .object, size: 1_268_736, lastModified: base, storageClass: "STANDARD_IA", eTag: "k1l2m3"),
            S3Item(key: "Border_Stretches_Content_Horizontally.expected.png", kind: .object, size: 68_413, lastModified: base, storageClass: "STANDARD", eTag: "n4o5p6"),
            S3Item(key: "Border_Stretches_Content_Vertically.expected.png", kind: .object, size: 3_145_728, lastModified: base, storageClass: "INTELLIGENT_TIERING", eTag: "q7r8s9"),
            S3Item(key: "Border_Top_Aligns_Content.expected.png", kind: .object, size: 15_360, lastModified: base, storageClass: "STANDARD", eTag: "t1u2v3"),
            S3Item(key: "Border_Uniform_CornerRadius.expected.png", kind: .object, size: 1_340_416, lastModified: base, storageClass: "STANDARD", eTag: "w4x5y6")
        ]
        if let account = selectedAccount, let bucket = selectedBucket {
            folderStats.seed(records: [
                FolderStatsRecord(
                    accountID: account.id, bucket: bucket, prefix: "originals/",
                    size: 12_480_512, objectCount: 27, newestObjectDate: base,
                    computedAt: Date(), partial: false
                ),
                FolderStatsRecord(
                    accountID: account.id, bucket: bucket, prefix: "thumbnails/",
                    size: 3_204_096, objectCount: 48, newestObjectDate: base,
                    computedAt: Date(), partial: false
                )
            ], persist: false)
        }
        selection = ["Border_2px_Border.expected.png"]
        checked = []
        status = "Ready"
        errorMessage = nil
        isTruncated = false
        statusTextCache = ""

        transfers.seedDemoTasks()
        appendLog("Loaded sample account for the layout snapshot")

        onTreeChange?()
        onFilesChange?()
        onChromeChange?()
        onTransferChange?()
        onDetailsChange?()
    }

    private var statusTextCache = ""

    func loadDemoDetails() {
        guard let item = selectedItem else { return }
        details = ObjectDetails(
            contentType: "image/png",
            contentLength: item.size,
            eTag: item.eTag,
            lastModified: item.lastModified,
            storageClass: item.storageClass ?? "STANDARD",
            versionID: "3HL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vjVBH40Nr8X8gdRQBpUMLUo",
            metadata: ["cache-control": "max-age=3600", "owner": "design-team"],
            cacheControl: "max-age=3600",
            contentDisposition: "inline",
            contentEncoding: "identity",
            contentLanguage: "en-US",
            serverSideEncryption: "AES256",
            expires: nil,
            acceptRanges: "bytes",
            tags: ["environment": "production", "team": "design"]
        )
        versions = [
            ObjectVersion(versionID: "3HL4kqt...", isLatest: true, isDeleteMarker: false, size: item.size, lastModified: item.lastModified, eTag: item.eTag, storageClass: "STANDARD"),
            ObjectVersion(versionID: "2GJ3jps...", isLatest: false, isDeleteMarker: false, size: (item.size ?? 0) - 1024, lastModified: item.lastModified?.addingTimeInterval(-86400), eTag: "older", storageClass: "STANDARD"),
            ObjectVersion(versionID: "1FI2ior...", isLatest: false, isDeleteMarker: true, size: nil, lastModified: item.lastModified?.addingTimeInterval(-172800), eTag: nil, storageClass: nil)
        ]
        acl = [
            "FULL_CONTROL — owner",
            "READ — AllUsers",
            "READ_ACP — AuthenticatedUsers"
        ]
        previewText = "PNG image preview (1.2 MB).\n\nThe Preview tab renders text files directly and shows a placeholder for images in this build."
        detailsKey = item.key
        versionsKey = item.key
        aclKey = item.key
        tags = details?.tags ?? [:]
        tagsKey = item.key
        onDetailsChange?()
        onLogChange?()
    }

    func clearLogsForSnapshot() {
        logs.removeAll()
        onLogChange?()
    }

    func setPrefixForSnapshot(_ value: String) {
        prefix = value
        onChromeChange?()
    }

    func setErrorForSnapshot(_ message: String) {
        errorMessage = message
        items = []
        isBusy = false
        onFilesChange?()
        onChromeChange?()
    }

    func clearBucketForDemo() {
        selectedBucket = nil
        prefix = ""
        items = []
        selection = []
        onFilesChange?()
        onChromeChange?()
    }

    func clearItemsForDemo() {
        items = []
        selection = []
        isTruncated = false
        onFilesChange?()
        onChromeChange?()
    }

    func reloadAccounts() {
        let selectedID = selectedAccount?.id
        if let selectedID, let account = accounts.account(id: selectedID) {
            selectedAccount = account
        } else if let first = accounts.accounts.first {
            if selectedAccount?.id != first.id { clearBrowserState() }
            selectedAccount = first
        } else {
            clearBrowserState()
            selectedAccount = nil
        }
        onTreeChange?()
        onChromeChange?()
    }

    private func clearBrowserState() {
        folderStats.cancelAll()
        listingRequestID += 1
        selectedBucket = nil
        prefix = ""
        buckets = []
        items = []
        filterText = ""
        nextToken = nil
        isTruncated = false
        isBusy = false
        isLoadingBuckets = false
        bucketError = nil
        errorMessage = nil
        status = "Ready"
        selection = []
        checked = []
        resetInspector()
        onFilesChange?()
    }

    func selectAccount(_ account: Account) {
        let accountChanged = selectedAccount?.id != account.id
        listingRequestID += 1
        bucketRequestID += 1
        let requestID = bucketRequestID
        selectedAccount = account
        selectedBucket = nil
        prefix = ""
        filterText = ""
        LogStore.shared.log(
            .info, category: .ui, event: "ui.account.opened",
            message: "Account opened", accountID: account.id,
            accountName: account.displayName
        )
        if accountChanged { buckets = [] }
        items = []
        nextToken = nil
        isTruncated = false
        isBusy = false
        isLoadingBuckets = true
        bucketError = nil
        errorMessage = nil
        status = "Loading buckets"
        selection = []
        checked = []
        resetInspector()
        onTreeChange?()
        onFilesChange?()
        onChromeChange?()

        if let scopedBucket = account.bucket?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scopedBucket.isEmpty {
            buckets = [S3Bucket(name: scopedBucket, creationDate: nil)]
            isLoadingBuckets = false
            status = "Ready"
            onTreeChange?()
            onChromeChange?()
            return
        }

        Task {
            await loadBuckets(account: account, requestID: requestID, useCache: true)
        }
    }

    private func loadBuckets(account: Account, requestID: Int, useCache: Bool) async {
        do {
            let secret = try accounts.secret(for: account)
            let list = try await service.listBuckets(account: account, secret: secret, useCache: useCache)
            guard requestID == bucketRequestID,
                  selectedAccount?.id == account.id else { return }
            buckets = list
            isLoadingBuckets = false
            bucketError = nil
            if selectedBucket == nil { status = "Ready" }
            onTreeChange?()
            onFilesChange?()
            onChromeChange?()
        } catch {
            guard requestID == bucketRequestID,
                  selectedAccount?.id == account.id else { return }
            isLoadingBuckets = false
            let detail = S3ErrorPresenter.message(for: error)
            if account.bucket?.isEmpty != false,
               detail.localizedCaseInsensitiveContains("denied") || detail.localizedCaseInsensitiveContains("not entitled") {
                bucketError = "This key cannot list all buckets. Edit the account and set its bucket name."
            } else {
                bucketError = detail
            }
            AppLog.shared.error("List buckets failed: \(S3ErrorPresenter.message(for: error))")
            onTreeChange?()
            onChromeChange?()
        }
    }

    func selectBucket(_ bucket: String) {
        guard let account = selectedAccount else { return }
        openLocation(accountID: account.id, bucket: bucket, prefix: "")
    }

    /// Selects an account, bucket and prefix as one atomic change. Folder rows
    /// in the sidebar can belong to a bucket other than the one currently open;
    /// updating only the prefix would leave the path bar on the old bucket.
    func openLocation(accountID: UUID, bucket: String, prefix newPrefix: String) {
        guard let account = accounts.account(id: accountID) else { return }
        let accountChanged = selectedAccount?.id != accountID
        if accountChanged {
            selectedAccount = account
            buckets = []
        }
        folderStats.cancelAll()
        listingRequestID += 1
        let requestID = listingRequestID
        selectedBucket = bucket
        prefix = newPrefix
        filterText = ""
        items = []
        nextToken = nil
        isTruncated = false
        selection = []
        checked = []
        errorMessage = nil
        status = "Loading \(bucket)/\(newPrefix)"
        isBusy = true
        LogStore.shared.log(
            .info, category: .ui, event: "ui.bucket.opened",
            message: "Bucket opened", accountID: account.id,
            accountName: account.displayName, bucket: bucket,
            operation: "openBucket", metadata: ["prefix": newPrefix]
        )
        resetInspector()
        onTreeChange?()
        onFilesChange?()
        onChromeChange?()
        Task {
            await reload(
                useCache: true,
                account: account,
                bucket: bucket,
                prefix: newPrefix,
                generation: requestID
            )
        }
    }

    func navigate(toPrefix newPrefix: String) async {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        folderStats.cancelAll()
        listingRequestID += 1
        let requestID = listingRequestID
        prefix = newPrefix
        filterText = ""
        items = []
        nextToken = nil
        isTruncated = false
        selection = []
        checked = []
        errorMessage = nil
        status = "Loading \(selectedBucket ?? "")/\(prefix)"
        isBusy = true
        LogStore.shared.log(
            .info, category: .ui, event: "ui.prefix.opened",
            message: "Prefix opened", accountID: account.id,
            accountName: account.displayName, bucket: bucket,
            operation: "openPrefix", metadata: ["prefix": newPrefix]
        )
        resetInspector()
        onFilesChange?()
        onChromeChange?()
        await reload(
            useCache: true,
            account: account,
            bucket: bucket,
            prefix: newPrefix,
            generation: requestID
        )
    }

    func up() async {
        guard !prefix.isEmpty else { return }
        var parts = prefix.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        let parent = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        await navigate(toPrefix: parent)
    }

    func open(_ item: S3Item) async {
        guard item.kind == .folder else { return }
        await navigate(toPrefix: item.key)
    }

    func refreshBuckets() async {
        guard let account = selectedAccount else { return }
        if let scopedBucket = account.bucket?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scopedBucket.isEmpty {
            buckets = [S3Bucket(name: scopedBucket, creationDate: nil)]
            isLoadingBuckets = false
            bucketError = nil
            if selectedBucket == nil { status = "Ready" }
            onTreeChange?()
            onChromeChange?()
            return
        }
        bucketRequestID += 1
        let requestID = bucketRequestID
        isLoadingBuckets = true
        if selectedBucket == nil {
            status = "Loading buckets"
            onChromeChange?()
        }
        do {
            let secret = try accounts.secret(for: account)
            let list = try await service.listBuckets(account: account, secret: secret, useCache: false)
            guard requestID == bucketRequestID,
                  selectedAccount?.id == account.id else { return }
            buckets = list
            isLoadingBuckets = false
            bucketError = nil
            if selectedBucket == nil {
                errorMessage = nil
                status = "Ready"
            }
            onTreeChange?()
            onChromeChange?()
        } catch {
            guard requestID == bucketRequestID,
                  selectedAccount?.id == account.id else { return }
            isLoadingBuckets = false
            bucketError = S3ErrorPresenter.message(for: error)
            AppLog.shared.error("Refresh buckets failed: \(S3ErrorPresenter.message(for: error))")
            onTreeChange?()
        }
    }

    // MARK: - Listing

    func reload(
        useCache: Bool = true,
        account targetAccount: Account? = nil,
        bucket targetBucket: String? = nil,
        prefix targetPrefixOverride: String? = nil,
        generation: Int? = nil
    ) async {
        guard let account = targetAccount ?? selectedAccount,
              let bucket = targetBucket ?? selectedBucket else {
            isBusy = false
            onFilesChange?()
            onChromeChange?()
            return
        }
        if generation == nil, !useCache {
            listingRequestID += 1
        }
        let requestID = generation ?? listingRequestID
        guard requestID == listingRequestID else { return }
        if !useCache {
            folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
        }
        folderStats.cancelAll()
        if !useCache {
            detailsCache.removeAll()
            tagsCache.removeAll()
            resetInspector()
        }
        let targetPrefix = targetPrefixOverride ?? prefix
        isBusy = true
        status = useCache ? "Loading \(bucket)/\(targetPrefix)" : "Refreshing \(bucket)/\(targetPrefix)"
        errorMessage = nil
        onChromeChange?()

        do {
            let secret = try accounts.secret(for: account)
            let page = try await service.list(
                account: account, secret: secret,
                bucket: bucket, prefix: targetPrefix, useCache: useCache
            )
            guard requestID == listingRequestID,
                  selectedAccount?.id == account.id,
                  selectedBucket == bucket,
                  prefix == targetPrefix else { return }
            items = page.items
            nextToken = page.nextToken
            isTruncated = page.isTruncated
            sortItems()
            lastUpdated = Date()
            status = "Ready"
            pruneSelection()
        } catch {
            guard requestID == listingRequestID,
                  selectedAccount?.id == account.id,
                  selectedBucket == bucket,
                  prefix == targetPrefix else { return }
            AppLog.shared.error("List bucket=\(bucket) prefix=\(targetPrefix): \(S3ErrorPresenter.message(for: error))")
            setError(error)
        }

        guard requestID == listingRequestID else { return }
        isBusy = false
        onFilesChange?()
        onChromeChange?()
    }

    func refresh() async {
        guard let account = selectedAccount else { return }
        guard let bucket = selectedBucket else {
            await refreshBuckets()
            return
        }
        await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
        await reload(useCache: false)
    }

    func loadMore() async {
        guard isTruncated, let token = nextToken,
              let account = selectedAccount, let bucket = selectedBucket else { return }
        let requestID = listingRequestID
        let targetPrefix = prefix
        isBusy = true
        status = "Loading more…"
        onChromeChange?()
        do {
            let secret = try accounts.secret(for: account)
            let page = try await service.list(
                account: account, secret: secret,
                bucket: bucket, prefix: targetPrefix,
                continuationToken: token, useCache: false
            )
            guard requestID == listingRequestID,
                  selectedAccount?.id == account.id,
                  selectedBucket == bucket,
                  prefix == targetPrefix else { return }
            let existing = Set(items.map(\.key))
            items.append(contentsOf: page.items.filter { !existing.contains($0.key) })
            nextToken = page.nextToken
            isTruncated = page.isTruncated
            sortItems()
            status = "Ready"
        } catch {
            guard requestID == listingRequestID,
                  selectedAccount?.id == account.id,
                  selectedBucket == bucket,
                  prefix == targetPrefix else { return }
            setError(error)
        }
        guard requestID == listingRequestID else { return }
        isBusy = false
        onFilesChange?()
        onChromeChange?()
    }

    func sort(by column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
        sortItems()
        onFilesChange?()
    }

    var currentSort: (column: SortColumn, ascending: Bool) { (sortColumn, sortAscending) }

    private func sortItems() {
        let ascending = sortAscending
        items.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .folder }
            let result: ComparisonResult
            switch sortColumn {
            case .name:
                result = lhs.displayName.localizedStandardCompare(rhs.displayName)
            case .size:
                let l = sizeForDisplay(lhs), r = sizeForDisplay(rhs)
                if l == nil || r == nil {
                    if l == nil && r == nil { result = .orderedSame }
                    else { return l != nil }
                } else {
                    result = l == r ? .orderedSame : (l! < r! ? .orderedAscending : .orderedDescending)
                }
            case .type:
                result = lhs.typeSortKey.localizedStandardCompare(rhs.typeSortKey)
            case .modified:
                let l = modifiedForDisplay(lhs), r = modifiedForDisplay(rhs)
                if l == nil || r == nil {
                    if l == nil && r == nil { result = .orderedSame }
                    else { return l != nil }
                } else {
                    result = l == r ? .orderedSame : (l! < r! ? .orderedAscending : .orderedDescending)
                }
            case .storage:
                result = (lhs.storageClass ?? "").localizedStandardCompare(rhs.storageClass ?? "")
            case .etag:
                result = (lhs.eTag ?? "").localizedStandardCompare(rhs.eTag ?? "")
            }
            if result == .orderedSame { return lhs.key < rhs.key }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: - Folder stats

    func invalidateFolderStats(accountID: UUID) {
        folderStats.invalidateAccount(accountID: accountID)
    }

    func flushTransfers() {
        transfers.flushPersistence()
    }

    func flushFolderStats() {
        folderStats.flush()
    }

    func setCalculateFolderSizes(_ enabled: Bool) {
        calculateFolderSizes = enabled
        LogStore.shared.audit(
            event: "settings.folder_sizes.changed",
            message: "Folder size setting changed",
            outcome: "success",
            metadata: ["enabled": String(enabled)]
        )
        if !enabled {
            folderStats.cancelAll()
            onFilesChange?()
        }
    }

    /// Requests cache-first stats for every folder row in the current listing.
    /// The coordinator coalesces siblings into one parent scan and keeps cached
    /// values visible while refreshing.
    func requestFolderStats(for visibleItems: [S3Item]) {
        guard calculateFolderSizes,
              let account = selectedAccount,
              let bucket = selectedBucket else {
            folderStats.cancelAll()
            return
        }
        let keys = visibleItems.compactMap { item -> FolderStatsKey? in
            guard item.kind == .folder else { return nil }
            return FolderStatsKey(accountID: account.id, bucket: bucket, prefix: item.key)
        }
        let secret = folderStats.needsScan(for: keys)
            ? ((try? accounts.secret(for: account)) ?? "")
            : ""
        folderStats.update(keys: keys, account: account, secret: secret)
    }

    private func pruneSelection() {
        let keys = Set(visibleItems.map(\.key))
        let oldSelection = selection
        selection = selection.intersection(keys)
        checked = checked.intersection(keys)
        if selection != oldSelection { resetInspector() }
    }

    func setFilter(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != filterText else { return }
        filterText = trimmed
        pruneSelection()
        onFilesChange?()
        onChromeChange?()
    }

    // MARK: - Selection

    func setSelection(_ keys: Set<String>) {
        if selection != keys {
            selection = keys
            errorMessage = nil
            status = "Ready"
            resetInspector()
        } else {
            selection = keys
        }
        onChromeChange?()
    }

    func toggleChecked(_ key: String) {
        if checked.contains(key) { checked.remove(key) } else { checked.insert(key) }
        onFilesChange?()
        onChromeChange?()
    }

    // MARK: - Operations

    func upload(urls: [URL]) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        for url in urls {
            let key = prefix + url.lastPathComponent
            transfers.enqueueUpload(account: account, secret: secret, bucket: bucket, key: key, url: url)
        }
        folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
        onTransferChange?()
    }

    func uploadDirectory(_ root: URL) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var queued = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let key = prefix + root.lastPathComponent + "/" + relative
            transfers.enqueueUpload(account: account, secret: secret, bucket: bucket, key: key, url: fileURL)
            queued += 1
        }
        appendLog("Queued \(queued) file(s) from folder \(root.lastPathComponent)")
        folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
        onTransferChange?()
    }

    func openObject(_ item: S3Item) {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BucketManagerPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(S3Key.safeLocalName(item.displayName))
        Task {
            do {
                try await service.download(
                    account: account, secret: secret, bucket: bucket, key: item.key,
                    to: destination, progress: { _ in }
                )
                appendLog("Opened \(item.key)")
                NSWorkspace.shared.open(destination)
            } catch {
                setError(error)
            }
        }
    }

    func download(items selected: [S3Item], to directory: URL) async {
        guard let account = selectedAccount, let bucket = selectedBucket, !selected.isEmpty else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }

        var downloads: [(item: S3Item, destination: URL)] = []
        var seen = Set<String>()
        for item in selected where item.kind == .object {
            guard !item.key.hasSuffix("/") else { continue }
            seen.insert(item.key)
            downloads.append((
                item,
                directory.appendingPathComponent(S3Key.safeLocalName(item.displayName))
            ))
        }

        for folder in selected where folder.kind == .folder {
            let folderPrefix = folder.key.hasSuffix("/") ? folder.key : folder.key + "/"
            do {
                let objects = try await service.listAllObjects(
                    account: account, secret: secret, bucket: bucket, prefix: folderPrefix
                )
                let root = directory.appendingPathComponent(
                    S3Key.safeLocalName(folder.displayName), isDirectory: true
                )
                for object in objects where object.kind == .object && !object.key.hasSuffix("/") {
                    guard seen.insert(object.key).inserted else { continue }
                    let relative = String(object.key.dropFirst(folderPrefix.count))
                    let safeRelative = S3Key.safeRelativePath(relative)
                    guard !safeRelative.isEmpty else { continue }
                    downloads.append((object, root.appendingPathComponent(safeRelative)))
                }
            } catch {
                setError(error)
                return
            }
        }

        for download in downloads {
            transfers.enqueueDownload(
                account: account, secret: secret, bucket: bucket, key: download.item.key,
                size: download.item.size ?? 0, to: download.destination
            )
        }
        onTransferChange?()
    }

    func delete(items selected: [S3Item]) async {
        guard let account = selectedAccount, let bucket = selectedBucket, !selected.isEmpty else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        isBusy = true
        status = "Preparing to delete…"
        onChromeChange?()

        var targets: [S3Item] = []
        var seen = Set<String>()
        var expandedPrefixes: [String] = []
        for item in selected where item.kind == .object {
            guard seen.insert(item.key).inserted else { continue }
            targets.append(item)
        }
        for folder in selected where folder.kind == .folder {
            let folderPrefix = folder.key.hasSuffix("/") ? folder.key : folder.key + "/"
            expandedPrefixes.append(folderPrefix)
            do {
                let objects = try await service.listAllObjects(
                    account: account, secret: secret, bucket: bucket, prefix: folderPrefix
                )
                for object in objects where object.kind == .object && !object.key.hasSuffix("/") {
                    guard seen.insert(object.key).inserted else { continue }
                    targets.append(object)
                }
                if seen.insert(folderPrefix).inserted {
                    targets.append(S3Item(key: folderPrefix, kind: .object))
                }
            } catch {
                isBusy = false
                setError(error)
                return
            }
        }

        guard !targets.isEmpty else {
            isBusy = false
            status = "Ready"
            onChromeChange?()
            return
        }

        status = "Deleting \(targets.count) object\(targets.count == 1 ? "" : "s")…"
        onChromeChange?()
        let results = await withTaskGroup(of: (String, String?).self) { group in
            for item in targets {
                group.addTask { [service, account, secret, bucket] in
                    do {
                        try await service.delete(
                            account: account, secret: secret, bucket: bucket, key: item.key
                        )
                        return (item.key, nil)
                    } catch {
                        return (item.key, S3ErrorPresenter.message(for: error))
                    }
                }
            }
            var values: [(String, String?)] = []
            for await value in group { values.append(value) }
            return values
        }
        var failures: [String] = []
        for (key, message) in results {
            if let message {
                let name = String(key.split(separator: "/").last ?? Substring(key))
                failures.append("\(name): \(message)")
            } else {
                appendLog("Deleted \(key)")
            }
        }
        await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
        for expandedPrefix in expandedPrefixes {
            await service.invalidateListing(account: account.id, bucket: bucket, prefix: expandedPrefix)
        }
        folderStats.invalidateBucket(accountID: account.id, bucket: bucket)
        await reload(useCache: false)
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
            status = "Some deletes failed"
        }
        auditOperation(
            event: targets.count == 1 ? "object.deleted" : "objects.deleted",
            message: failures.isEmpty ? "Objects deleted" : "Some objects failed to delete",
            account: account,
            bucket: bucket,
            key: selected.count == 1 ? selected[0].key : nil,
            outcome: failures.isEmpty ? "success" : "failure",
            metadata: [
                "count": String(targets.count),
                "folders": String(selected.filter { $0.kind == .folder }.count),
                "failed": String(failures.count)
            ]
        )
        isBusy = false
        onChromeChange?()
    }

    func createFolder(named name: String) async {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else {
            setError(NSError(domain: "BucketManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a folder name."
            ]))
            return
        }
        guard !clean.contains("/") else {
            setError(NSError(domain: "BucketManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Folder names cannot contain /."
            ]))
            return
        }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        do {
            try await service.createFolder(account: account, secret: secret, bucket: bucket, prefix: prefix, name: clean)
            appendLog("Created folder \(prefix + clean)/")
            auditOperation(
                event: "folder.created",
                message: "Folder created",
                account: account,
                bucket: bucket,
                key: prefix + clean + "/"
            )
            await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
            folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
            await reload(useCache: false)
        } catch {
            auditOperation(
                event: "folder.create.failed",
                message: "Folder creation failed",
                account: account,
                bucket: bucket,
                key: prefix + clean + "/",
                outcome: "failure"
            )
            setError(error)
        }
    }

    func rename(_ item: S3Item, to newName: String) async {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.displayName else { return }
        guard !trimmed.contains("/") else {
            setError(NSError(domain: "BucketManager", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Names cannot contain /."
            ]))
            return
        }
        let destination = prefix + trimmed
        do {
            try await service.copyObject(
                account: account, secret: secret,
                sourceBucket: bucket, sourceKey: item.key,
                destinationBucket: bucket, destinationKey: destination
            )
            try await service.delete(account: account, secret: secret, bucket: bucket, key: item.key)
            appendLog("Renamed \(item.key) to \(destination)")
            auditOperation(
                event: "object.renamed",
                message: "Object renamed",
                account: account,
                bucket: bucket,
                key: destination,
                metadata: ["sourceKey": item.key]
            )
            folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
            await reload(useCache: false)
        } catch {
            auditOperation(
                event: "object.rename.failed",
                message: "Object rename failed",
                account: account,
                bucket: bucket,
                key: destination,
                outcome: "failure"
            )
            setError(error)
        }
    }

    func copy(items selected: [S3Item], toBucket: String, toPrefix: String, move: Bool) async {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        isBusy = true
        status = "\(move ? "Moving" : "Copying") \(selected.count) object\(selected.count == 1 ? "" : "s")…"
        onChromeChange?()
        let results = await withTaskGroup(of: (String, String?).self) { group in
            for item in selected where item.kind == .object {
                group.addTask { [service, account, secret, bucket] in
                    let destination = toPrefix + item.displayName
                    do {
                        try await service.copyObject(
                            account: account, secret: secret,
                            sourceBucket: bucket, sourceKey: item.key,
                            destinationBucket: toBucket, destinationKey: destination
                        )
                        if move {
                            try await service.delete(
                                account: account, secret: secret, bucket: bucket, key: item.key
                            )
                        }
                        return (item.key, nil)
                    } catch {
                        return (item.key, S3ErrorPresenter.message(for: error))
                    }
                }
            }
            var values: [(String, String?)] = []
            for await value in group { values.append(value) }
            return values
        }

        var failures: [String] = []
        for (key, message) in results {
            if let message {
                failures.append("\(key): \(message)")
            } else {
                appendLog("\(move ? "Moved" : "Copied") \(key)")
            }
        }
        folderStats.invalidate(accountID: account.id, bucket: toBucket, prefix: toPrefix)
        if move {
            folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
        }
        await reload(useCache: false)
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
            status = "Some \(move ? "moves" : "copies") failed"
        }
        auditOperation(
            event: move ? "objects.moved" : "objects.copied",
            message: failures.isEmpty
                ? (move ? "Objects moved" : "Objects copied")
                : "Some object transfers failed",
            account: account,
            bucket: toBucket,
            key: toPrefix,
            outcome: failures.isEmpty ? "success" : "failure",
            metadata: [
                "count": String(selected.count),
                "failed": String(failures.count),
                "sourceBucket": bucket,
                "sourcePrefix": prefix
            ]
        )
        isBusy = false
        onChromeChange?()
    }

    func copySelectionToClipboard(cut: Bool) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        clipboard = selectedItems.map { ClipboardItem(accountID: account.id, bucket: bucket, key: $0.key) }
        clipboardIsCut = cut
        appendLog("\(cut ? "Cut" : "Copied") \(clipboard.count) object(s)")
    }

    var hasClipboard: Bool { !clipboard.isEmpty }

    func paste() async {
        guard let account = selectedAccount, let bucket = selectedBucket, !clipboard.isEmpty else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        isBusy = true
        status = "Pasting \(clipboard.count) object(s)…"
        onChromeChange?()
        do {
            for entry in clipboard {
                guard entry.accountID == account.id else {
                    throw NSError(domain: "BucketManager", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Copying between different accounts is not supported in this build."
                    ])
                }
                let name = String(entry.key.split(separator: "/").last ?? "object")
                let destination = prefix + name
                try await service.copyObject(
                    account: account, secret: secret,
                    sourceBucket: entry.bucket, sourceKey: entry.key,
                    destinationBucket: bucket, destinationKey: destination
                )
                if clipboardIsCut {
                    try await service.delete(account: account, secret: secret, bucket: entry.bucket, key: entry.key)
                }
            }
            appendLog("Pasted \(clipboard.count) object(s) into \(currentPath)")
            auditOperation(
                event: clipboardIsCut ? "clipboard.moved" : "clipboard.copied",
                message: "Clipboard paste completed",
                account: account,
                bucket: bucket,
                key: prefix,
                metadata: ["count": String(clipboard.count)]
            )
            let pastedEntries = clipboard
            if clipboardIsCut { clipboard = [] }
            status = "Ready"
            for entry in pastedEntries {
                let sourcePrefix = S3Key.parentPrefix(of: entry.key)
                folderStats.invalidate(accountID: account.id, bucket: entry.bucket, prefix: sourcePrefix)
            }
            folderStats.invalidate(accountID: account.id, bucket: bucket, prefix: prefix)
            await reload(useCache: false)
        } catch {
            setError(error)
        }
        isBusy = false
        onChromeChange?()
    }

    func createBucket(named name: String) async {
        guard let account = selectedAccount else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        do {
            try await service.createBucket(account: account, secret: secret, name: name)
            appendLog("Created bucket \(name)")
            auditOperation(
                event: "bucket.created",
                message: "Bucket created",
                account: account,
                bucket: name
            )
            await refreshBuckets()
        } catch {
            auditOperation(
                event: "bucket.create.failed",
                message: "Bucket creation failed",
                account: account,
                bucket: name,
                outcome: "failure"
            )
            setError(error)
        }
    }

    func deleteBucket(_ name: String) async {
        guard let account = selectedAccount else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        do {
            try await service.deleteBucket(account: account, secret: secret, name: name)
            appendLog("Deleted bucket \(name)")
            auditOperation(
                event: "bucket.deleted",
                message: "Bucket deleted",
                account: account,
                bucket: name
            )
            folderStats.invalidateBucket(accountID: account.id, bucket: name)
            if selectedBucket == name {
                selectedBucket = nil
                items = []
            }
            await refreshBuckets()
            onFilesChange?()
            onChromeChange?()
        } catch {
            auditOperation(
                event: "bucket.delete.failed",
                message: "Bucket deletion failed",
                account: account,
                bucket: name,
                outcome: "failure"
            )
            setError(error)
        }
    }

    private func auditOperation(
        event: String,
        message: String,
        account: Account,
        bucket: String?,
        key: String? = nil,
        outcome: String = "success",
        metadata: [String: String] = [:]
    ) {
        LogStore.shared.audit(
            event: event,
            message: message,
            accountID: account.id,
            accountName: account.displayName,
            bucket: bucket,
            key: key,
            outcome: outcome,
            metadata: metadata
        )
    }

    // MARK: - Inspector

    private func metadataKey(_ account: Account, _ bucket: String, _ key: String) -> String {
        account.id.uuidString + "\u{1F}" + bucket + "\u{1F}" + key
    }

    private func cacheDetails(_ value: ObjectDetails, for key: String) {
        detailsCache[key] = (value, Date())
        trimMetadataCaches()
    }

    private func cacheTags(_ value: [String: String], for key: String) {
        tagsCache[key] = (value, Date())
        trimMetadataCaches()
    }

    private func trimMetadataCaches() {
        let now = Date()
        detailsCache = detailsCache.filter { now.timeIntervalSince($0.value.at) < metadataTTL }
        tagsCache = tagsCache.filter { now.timeIntervalSince($0.value.at) < metadataTTL }
        if detailsCache.count > metadataCacheLimit {
            for entry in detailsCache.sorted(by: { $0.value.at < $1.value.at }).prefix(detailsCache.count - metadataCacheLimit) {
                detailsCache[entry.key] = nil
            }
        }
        if tagsCache.count > metadataCacheLimit {
            for entry in tagsCache.sorted(by: { $0.value.at < $1.value.at }).prefix(tagsCache.count - metadataCacheLimit) {
                tagsCache[entry.key] = nil
            }
        }
    }

    private func isCurrent(_ item: S3Item, account: Account, bucket: String) -> Bool {
        selectedAccount?.id == account.id && selectedBucket == bucket && selectedItem?.key == item.key
    }

    func inspectorLoaded(_ tab: String, for item: S3Item) -> Bool {
        switch tab {
        case "properties", "headers": return detailsKey == item.key
        case "tags": return tagsKey == item.key
        case "permissions": return aclKey == item.key
        case "versions": return versionsKey == item.key
        case "preview": return previewKey == item.key
        default: return true
        }
    }

    func loadDetails(for item: S3Item, force: Bool = false) async {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        if isDemoData {
            details = ObjectDetails(
                contentType: item.fileExtension == "png" ? "image/png" : "application/octet-stream",
                contentLength: item.size,
                eTag: item.eTag,
                lastModified: item.lastModified,
                storageClass: item.storageClass,
                versionID: "demo-v1",
                metadata: ["owner": "demo", "source": "sample-data"],
                tags: ["team": "design", "environment": "demo"]
            )
            detailsKey = item.key
            onDetailsChange?()
            return
        }
        let cacheKey = metadataKey(account, bucket, item.key)

        if !force, let cached = detailsCache[cacheKey], Date().timeIntervalSince(cached.at) < metadataTTL {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            details = cached.details
            detailsKey = item.key
            onDetailsChange?()
            return
        }
        if !force, detailsKey == item.key, details != nil { return }
        guard !inflightDetails.contains(cacheKey) else { return }
        inflightDetails.insert(cacheKey)
        defer { inflightDetails.remove(cacheKey) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let loaded = try await service.objectDetails(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            details = loaded
            detailsKey = item.key
            cacheDetails(loaded, for: cacheKey)
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            details = nil
            detailsKey = item.key
            onDetailsChange?()
            setError(error)
        }
    }

    func loadTags(for item: S3Item, force: Bool = false) async {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        if isDemoData {
            tags = ["team": "design", "environment": "demo"]
            tagsKey = item.key
            onDetailsChange?()
            return
        }
        let cacheKey = metadataKey(account, bucket, item.key)

        if !force, let cached = tagsCache[cacheKey], Date().timeIntervalSince(cached.at) < metadataTTL {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            tags = cached.tags
            tagsKey = item.key
            onDetailsChange?()
            return
        }
        if !force, tagsKey == item.key { return }
        guard !inflightTags.contains(cacheKey) else { return }
        inflightTags.insert(cacheKey)
        defer { inflightTags.remove(cacheKey) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let loaded = try await service.objectTags(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            tags = loaded
            tagsKey = item.key
            cacheTags(loaded, for: cacheKey)
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            tags = [:]
            tagsKey = item.key
            onDetailsChange?()
            setError(error)
        }
    }

    func loadVersions(for item: S3Item, force: Bool = false) async {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        if isDemoData {
            versions = [ObjectVersion(
                versionID: "demo-v1", isLatest: true, isDeleteMarker: false,
                size: item.size, lastModified: item.lastModified, eTag: item.eTag,
                storageClass: item.storageClass
            )]
            versionsKey = item.key
            onDetailsChange?()
            return
        }
        if !force, versionsKey == item.key { return }
        guard !inflightVersions.contains(item.key) else { return }
        inflightVersions.insert(item.key)
        defer { inflightVersions.remove(item.key) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let loaded = try await service.versions(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            versions = loaded
            versionsKey = item.key
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            versions = []
            versionsKey = item.key
            onDetailsChange?()
            setError(error)
        }
    }

    func loadACL(for item: S3Item, force: Bool = false) async {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        if isDemoData {
            acl = ["FULL_CONTROL — demo-owner", "READ — demo-reader"]
            aclKey = item.key
            onDetailsChange?()
            return
        }
        if !force, aclKey == item.key { return }
        guard !inflightACL.contains(item.key) else { return }
        inflightACL.insert(item.key)
        defer { inflightACL.remove(item.key) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let loaded = try await service.objectACL(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            acl = loaded
            aclKey = item.key
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            acl = []
            aclKey = item.key
            onDetailsChange?()
            setError(error)
        }
    }

    func loadPreview(for item: S3Item, force: Bool = false) async {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        if isDemoData {
            previewText = "[demo preview] \(item.displayName) — \((item.size ?? 0).byteString)"
            previewImage = nil
            previewKey = item.key
            onDetailsChange?()
            return
        }
        if !force, previewKey == item.key, previewText != nil || previewImage != nil { return }
        guard !inflightPreview.contains(item.key) else { return }
        inflightPreview.insert(item.key)
        defer { inflightPreview.remove(item.key) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let data = try await service.previewData(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(item.fileExtension),
               let image = NSImage(data: data) {
                previewImage = image
                previewText = nil
            } else if let text = String(data: data, encoding: .utf8) {
                previewImage = nil
                previewText = String(text.prefix(200_000))
            } else {
                previewImage = nil
                previewText = "[binary] \(item.displayName) — first \(Int64(data.count).byteString)"
            }
            previewKey = item.key
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            previewImage = nil
            previewText = "Preview failed: \(S3ErrorPresenter.message(for: error))"
            previewKey = item.key
            onDetailsChange?()
        }
    }

    func resetInspector() {
        details = nil
        versions = []
        acl = []
        tags = [:]
        previewText = nil
        previewImage = nil
        detailsKey = nil
        versionsKey = nil
        aclKey = nil
        tagsKey = nil
        previewKey = nil
        onDetailsChange?()
    }

    // MARK: - Log

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func appendLog(_ message: String) {
        AppLog.shared.log(message)
        logs.append("\(Self.logTimeFormatter.string(from: Date()))  \(message)")
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        onLogChange?()
    }

    // MARK: - Helpers

    private func refreshAfterTransfer() async {
        await reload(useCache: false)
    }

    private func setError(_ error: Error) {
        errorMessage = S3ErrorPresenter.message(for: error)
        status = "Error"
        AppLog.shared.error(errorMessage ?? "S3 operation failed")
        appendLog("Error: \(errorMessage ?? "")")
        onChromeChange?()
    }
}

extension Double {
    var rateString: String {
        guard self > 0 else { return "0 KB/s" }
        return "\(Int64(self).byteString)/s"
    }
}
