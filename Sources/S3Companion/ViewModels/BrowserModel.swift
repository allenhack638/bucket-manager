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

    private(set) var roots: [BrowserNode] = []
    private(set) var buckets: [S3Bucket] = []

    private(set) var selectedAccount: Account?
    private(set) var selectedBucket: String?
    private(set) var prefix: String = ""

    private(set) var items: [S3Item] = []
    private(set) var nextToken: String?
    private(set) var isTruncated = false
    private(set) var selection: Set<String> = []
    private(set) var checked: Set<String> = []

    private(set) var isBusy = false
    private(set) var status = "Ready"
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?

    private(set) var details: ObjectDetails?
    private(set) var versions: [ObjectVersion] = []
    private(set) var acl: [String] = []
    private(set) var previewText: String?

    private(set) var logs: [String] = []

    var calculateFolderSizes: Bool = true {
        didSet {
            UserDefaults.standard.set(calculateFolderSizes, forKey: "S3CompanionCalculateFolderSizes")
        }
    }

    private var sortColumn: SortColumn = .name
    private var sortAscending = true
    private var clipboard: [ClipboardItem] = []
    private var clipboardIsCut = false

    private var listingRequestID = 0
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
        self.transfers = TransferQueue()
        self.folderStats = FolderStatsCoordinator(
            cache: folderStatsCache,
            scanner: FolderStatsScanner(service: S3Service.shared)
        )
        self.calculateFolderSizes = UserDefaults.standard.object(forKey: "S3CompanionCalculateFolderSizes") as? Bool ?? true
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
        let total = items.reduce(Int64(0)) { $0 + (sizeForDisplay($1) ?? 0) }
        let count = items.count
        let noun = count == 1 ? "file" : "files"
        var text = "\(count) \(noun) (\(total.byteString))"
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

    // MARK: - Accounts / tree

    /// Populates the UI with deterministic sample data for offscreen snapshots
    /// and layout self-tests. Never called by the normal launch path.
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
        roots = [BrowserNode(kind: .account, title: demo.displayName, accountID: demo.id)]
        buckets = ["analytics-data", "app-logs", "archive", "backups-2026", "customer-uploads", "documents", "media-library", "my-backups", "my-photos", "netsdk", "photos", "production-data", "reports", "s3browser", "static-content", "tests"].map { S3Bucket(name: $0, creationDate: Date()) }
        roots[0].children = buckets.map { BrowserNode(kind: .bucket, title: $0.name, accountID: demo.id, bucket: $0.name) }
        roots[0].didLoad = true
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

    /// Snapshot-only helper: clears the event log so its empty state can be rendered.
    func clearLogsForSnapshot() {
        logs.removeAll()
        onLogChange?()
    }

    /// Snapshot-only helper: shows a deep path without issuing a request.
    func setPrefixForSnapshot(_ value: String) {
        prefix = value
        onChromeChange?()
    }

    /// Snapshot-only helper: shows the error placeholder without a request.
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
        roots = accounts.accounts.map { account in
            BrowserNode(kind: .account, title: account.displayName, accountID: account.id)
        }
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
        nextToken = nil
        isTruncated = false
        isBusy = false
        errorMessage = nil
        status = "Ready"
        selection = []
        checked = []
        resetInspector()
        onFilesChange?()
    }

    func node(forAccountID id: UUID) -> BrowserNode? {
        roots.first { $0.accountID == id }
    }

    func loadChildren(of node: BrowserNode) async {
        guard !node.didLoad, !node.isLoading else { return }
        node.isLoading = true
        onTreeChange?()

        do {
            switch node.kind {
            case .account:
                guard let accountID = node.accountID, let account = accounts.account(id: accountID) else { break }
                let secret = try accounts.secret(for: account)
                let list = try await service.listBuckets(account: account, secret: secret)
                if accountID == selectedAccount?.id { buckets = list }
                node.children = list.map {
                    BrowserNode(kind: .bucket, title: $0.name, accountID: accountID, bucket: $0.name)
                }
            case .bucket:
                guard let account = account(for: node) else { break }
                let secret = try accounts.secret(for: account)
                let page = try await service.list(
                    account: account, secret: secret,
                    bucket: node.bucket ?? "", prefix: ""
                )
                node.children = folderNodes(from: page.items, accountID: account.id, bucket: node.bucket ?? "")
            case .folder:
                guard let account = account(for: node) else { break }
                let secret = try accounts.secret(for: account)
                let page = try await service.list(
                    account: account, secret: secret,
                    bucket: node.bucket ?? "", prefix: node.prefix ?? ""
                )
                node.children = folderNodes(from: page.items, accountID: account.id, bucket: node.bucket ?? "")
            }
            node.didLoad = true
        } catch {
            errorMessage = Self.friendly(error)
            status = "Error"
            AppLog.shared.error("Load children failed for \(node.kind) \"\(node.title)\": \(String(describing: error))")
        }

        node.isLoading = false
        onTreeChange?()
        onChromeChange?()
    }

    private func folderNodes(from items: [S3Item], accountID: UUID, bucket: String) -> [BrowserNode] {
        items.filter { $0.kind == .folder }.map {
            BrowserNode(kind: .folder, title: $0.displayName, accountID: accountID, bucket: bucket, prefix: $0.key)
        }
    }

    func selectAccount(_ account: Account) {
        listingRequestID += 1
        selectedAccount = account
        selectedBucket = nil
        prefix = ""
        items = []
        nextToken = nil
        isTruncated = false
        isBusy = false
        errorMessage = nil
        status = "Ready"
        selection = []
        checked = []
        resetInspector()
        onFilesChange?()
        onChromeChange?()

        Task {
            if let node = node(forAccountID: account.id) {
                node.didLoad = false
                await loadChildren(of: node)
            }
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
        if selectedAccount?.id != accountID {
            selectedAccount = account
            buckets = []
        }
        folderStats.cancelAll()
        listingRequestID += 1
        let requestID = listingRequestID
        selectedBucket = bucket
        prefix = newPrefix
        items = []
        nextToken = nil
        isTruncated = false
        selection = []
        checked = []
        errorMessage = nil
        status = "Loading \(bucket)/\(newPrefix)"
        isBusy = true
        resetInspector()
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
        items = []
        nextToken = nil
        isTruncated = false
        selection = []
        checked = []
        errorMessage = nil
        status = "Loading \(selectedBucket ?? "")/\(prefix)"
        isBusy = true
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
        do {
            let secret = try accounts.secret(for: account)
            buckets = try await service.listBuckets(account: account, secret: secret, useCache: false)
            if let node = node(forAccountID: account.id) {
                node.didLoad = false
                node.children = []
                await loadChildren(of: node)
            }
            onChromeChange?()
        } catch {
            setError(error)
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
            AppLog.shared.error("List bucket=\(bucket) prefix=\(targetPrefix): \(String(describing: error))")
            setError(error)
        }

        guard requestID == listingRequestID else { return }
        isBusy = false
        onFilesChange?()
        onChromeChange?()
    }

    func refresh() async {
        if let account = selectedAccount, let bucket = selectedBucket {
            await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
        }
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

    func flushFolderStats() {
        folderStats.flush()
    }

    func setCalculateFolderSizes(_ enabled: Bool) {
        calculateFolderSizes = enabled
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
        let keys = Set(items.map(\.key))
        let oldSelection = selection
        selection = selection.intersection(keys)
        checked = checked.intersection(keys)
        if selection != oldSelection { resetInspector() }
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

    func setChecked(_ keys: Set<String>, checked value: Bool) {
        if value { checked.formUnion(keys) } else { checked.subtract(keys) }
        onFilesChange?()
        onChromeChange?()
    }

    var keysForAction: Set<String> {
        if !checked.isEmpty { return checked }
        return selection
    }

    /// Object keys can contain "." and ".." segments. Never use them as a
    /// filesystem path component: they would escape the chosen directory.
    static func parentPrefix(of key: String) -> String {
        var value = key
        if value.hasSuffix("/") { value.removeLast() }
        guard let slash = value.range(of: "/", options: .backwards) else { return "" }
        return String(value[..<slash.upperBound])
    }

    static func safeLocalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "_" }
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
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
        onTransferChange?()
    }

    func openObject(_ item: S3Item) {
        guard item.kind == .object, let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S3CompanionPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.safeLocalName(item.displayName))
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

    func download(items selected: [S3Item], to directory: URL) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        guard let secret = try? accounts.secret(for: account) else {
            setError(S3ServiceError.missingCredentials)
            return
        }
        for item in selected where item.kind == .object {
            let destination = directory.appendingPathComponent(Self.safeLocalName(item.displayName))
            transfers.enqueueDownload(
                account: account, secret: secret, bucket: bucket, key: item.key,
                size: item.size ?? 0, to: destination
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
        status = "Deleting \(selected.count) object\(selected.count == 1 ? "" : "s")…"
        onChromeChange?()
        var failures: [String] = []
        for item in selected where item.kind == .object {
            do {
                try await service.delete(account: account, secret: secret, bucket: bucket, key: item.key)
                appendLog("Deleted \(item.key)")
            } catch {
                failures.append("\(item.displayName): \(Self.friendly(error))")
            }
        }
        await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
        await refreshTreeBucket(account: account, bucket: bucket)
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
            status = "Some deletes failed"
        } else {
            status = "Ready"
        }
        isBusy = false
        await reload(useCache: false)
        onChromeChange?()
    }

    func createFolder(named name: String) async {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else {
            setError(NSError(domain: "S3Companion", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a folder name."
            ]))
            return
        }
        guard !clean.contains("/") else {
            setError(NSError(domain: "S3Companion", code: 2, userInfo: [
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
            await service.invalidateListing(account: account.id, bucket: bucket, prefix: prefix)
            await reload(useCache: false)
            await refreshTreeBucket(account: account, bucket: bucket)
        } catch {
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
            setError(NSError(domain: "S3Companion", code: 3, userInfo: [
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
            await reload(useCache: false)
            await refreshTreeBucket(account: account, bucket: bucket)
        } catch {
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
        do {
            for item in selected where item.kind == .object {
                let destination = toPrefix + item.displayName
                try await service.copyObject(
                    account: account, secret: secret,
                    sourceBucket: bucket, sourceKey: item.key,
                    destinationBucket: toBucket, destinationKey: destination
                )
                if move {
                    try await service.delete(account: account, secret: secret, bucket: bucket, key: item.key)
                }
            }
            appendLog("\(move ? "Moved" : "Copied") \(selected.count) object(s) to /\(toBucket)/\(toPrefix)")
            status = "Ready"
            folderStats.invalidate(accountID: account.id, bucket: toBucket, prefix: toPrefix)
            await reload(useCache: false)
            await refreshTreeBucket(account: account, bucket: toBucket)
        } catch {
            setError(error)
        }
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
                    throw NSError(domain: "S3Companion", code: 1, userInfo: [
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
            let pastedEntries = clipboard
            if clipboardIsCut { clipboard = [] }
            status = "Ready"
            for entry in pastedEntries {
                let sourcePrefix = Self.parentPrefix(of: entry.key)
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
            await refreshBuckets()
        } catch {
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
            folderStats.invalidateBucket(accountID: account.id, bucket: name)
            if selectedBucket == name {
                selectedBucket = nil
                items = []
            }
            await refreshBuckets()
            onFilesChange?()
            onChromeChange?()
        } catch {
            setError(error)
        }
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
            cacheTags([:], for: cacheKey)
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
            previewKey = item.key
            onDetailsChange?()
            return
        }
        if !force, previewKey == item.key, previewText != nil { return }
        guard !inflightPreview.contains(item.key) else { return }
        inflightPreview.insert(item.key)
        defer { inflightPreview.remove(item.key) }

        guard let secret = try? accounts.secret(for: account) else { return }
        do {
            let data = try await service.previewData(
                account: account, secret: secret, bucket: bucket, key: item.key
            )
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            if NSImage(data: data) != nil,
               ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(item.fileExtension) {
                previewText = "[image] \(item.displayName) — \(Int64(data.count).byteString)"
            } else if let text = String(data: data, encoding: .utf8) {
                previewText = String(text.prefix(200_000))
            } else {
                previewText = "[binary] \(item.displayName) — first \(Int64(data.count).byteString)"
            }
            previewKey = item.key
            onDetailsChange?()
        } catch {
            guard isCurrent(item, account: account, bucket: bucket) else { return }
            previewText = "Preview failed: \(Self.friendly(error))"
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
        detailsKey = nil
        versionsKey = nil
        aclKey = nil
        tagsKey = nil
        previewKey = nil
        onDetailsChange?()
    }

    // MARK: - Log

    func appendLog(_ message: String) {
        AppLog.shared.log(message)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(message)")
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        onLogChange?()
    }

    func clearLog() {
        logs.removeAll()
        onLogChange?()
    }

    // MARK: - Helpers

    private func account(for node: BrowserNode) -> Account? {
        guard let id = node.accountID, let account = accounts.account(id: id) else { return nil }
        if selectedAccount?.id == id { return selectedAccount }
        return account
    }

    private func refreshTreeBucket(account: Account, bucket: String) async {
        if let accountNode = node(forAccountID: account.id),
           let bucketNode = accountNode.children.first(where: { $0.bucket == bucket }) {
            bucketNode.didLoad = false
            bucketNode.children = []
        }
    }

    private func refreshAfterTransfer() async {
        await reload(useCache: false)
        if let account = selectedAccount, let bucket = selectedBucket {
            await refreshTreeBucket(account: account, bucket: bucket)
            if let accountNode = node(forAccountID: account.id) {
                accountNode.didLoad = false
            }
        }
        onTreeChange?()
    }

    private func setError(_ error: Error) {
        errorMessage = Self.friendly(error)
        status = "Error"
        AppLog.shared.error("\(errorMessage ?? "")\nRAW: \(String(describing: error))")
        appendLog("Error: \(errorMessage ?? "")")
        onChromeChange?()
    }

    static func friendly(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("AccessDenied") { return "Access denied. Check the IAM policy for this access key." }
        if text.contains("InvalidAccessKeyId") { return "The access key ID is not valid." }
        if text.contains("SignatureDoesNotMatch") { return "The secret access key is not valid." }
        if text.contains("NoSuchBucket") { return "The bucket does not exist." }
        if text.contains("NoSuchKey") { return "The object does not exist." }
        if text.contains("RULESET_EXHAUSTED") { return "The custom endpoint could not be resolved. Check the endpoint URL." }
        if text.contains("User canceled") || text.contains("-128") {
            return "Keychain access was denied. Click Always Allow when macOS asks, or re-enter the secret via Accounts → Manage accounts."
        }
        if text.contains("notConnectedToInternet") || text.contains("networkConnectionLost") {
            return "Network connection lost."
        }
        return text.split(separator: "\n").first.map(String.init) ?? text
    }
}

extension Double {
    var rateString: String {
        guard self > 0 else { return "0 KB/s" }
        return "\(Int64(self).byteString)/s"
    }
}
