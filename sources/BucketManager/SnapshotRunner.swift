#if DEBUG
import AppKit

@MainActor
enum SnapshotRunner {
    /// Snapshots run as a bare executable, so load the brand icon from the repository.
    private static func prepare(_ app: NSApplication) {
        app.appearance = ProcessInfo.processInfo.environment["S3C_APPEARANCE"] == "dark"
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
        if let icon = NSImage(contentsOfFile: "assets/AppIcon.icns") {
            app.applicationIconImage = icon
        }
    }

    static func runMain(path: String, size: NSSize, tab: String?, empty: String?, pathPrefix: String?, errorMessage: String?, filter: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        prepare(app)

        let demoAccount = Account(
            displayName: "Amazon S3 Storage",
            accessKeyID: "EXAMPLE_ACCESS_KEY",
            kind: .amazonS3,
            region: "us-east-1"
        )
        let accounts = AccountStore(inMemoryAccounts: empty == "accounts" ? [] : [demoAccount])
        let model = BrowserModel(accounts: accounts)
        if empty != "accounts" {
            model.loadDemoData()
            if empty == "bucket" { model.clearBucketForDemo() }
            if empty == "folder" { model.clearItemsForDemo() }
            if empty == "log" { model.clearLogsForSnapshot() }
            if let pathPrefix { model.setPrefixForSnapshot(pathPrefix) }
            if let errorMessage { model.setErrorForSnapshot(errorMessage) }
            if CommandLine.arguments.contains("--show-deleted") { model.applyShowDeleted(true) }
        }

        let controller = MainWindowController(accounts: accounts, model: model)
        model.onTreeChange?()
        model.onFilesChange?()
        model.onChromeChange?()
        model.onTransferChange?()

        if let tab {
            if tab != "tasks" && tab != "log" { model.loadDemoDetails() }
            controller.selectTabForSnapshot(tab)
        }
        if let filter {
            controller.showFilterForSnapshot(filter)
        }

        guard let window = controller.window else { return }
        window.setContentSize(size)
        window.orderFrontRegardless()
        render(window: window, to: path, size: size)
        app.terminate(nil)
    }

    static func runSheet(path: String, size: NSSize, kind: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        prepare(app)

        let accounts = AccountStore(inMemoryAccounts: [
            Account(displayName: "Amazon S3 Storage", accessKeyID: "EXAMPLE_ACCESS_KEY", kind: .amazonS3, region: "us-east-1"),
            Account(displayName: "S3-Compatible Storage", accessKeyID: "EXAMPLE0000000000000", kind: .compatible, region: "us-east-1", endpoint: "https://s3.example.com"),
            Account(displayName: "Wasabi Test", accessKeyID: "EXAMPLE0000000000001", kind: .compatible, region: "us-east-1", endpoint: "https://s3.wasabisys.com")
        ])
        let model = BrowserModel(accounts: accounts)
        model.reloadAccounts()

        var retained: [AnyObject] = []
        let window: NSWindow?
        if kind == "share" || kind == "share-copied" {
            let alert = kind == "share"
                ? BrowserViewController.makeShareAlert(for: "IMG_7072.JPG").alert
                : BrowserViewController.makeShareLinkCopiedAlert(
                    URL(string: "https://demo-bucket.s3.us-east-1.amazonaws.com/photos/IMG_7072.JPG"
                        + "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=86400&X-Amz-Signature=0123456789abcdef")!,
                    lifetime: "1 day"
                )
            alert.layout()
            retained.append(alert)
            window = alert.window
        } else if kind == "accounts" {
            let sheet = StorageAccountsWindowController(accounts: accounts, model: model)
            sheet.reload()
            retained.append(sheet)
            window = sheet.window
        } else if kind == "edit", let account = accounts.accounts.first(where: { $0.kind == .compatible }) {
            let sheet = AddAccountWindowController(
                account: account, secret: UUID().uuidString,
                onSave: { _, _ in }, onCancel: {}
            )
            retained.append(sheet)
            window = sheet.window
        } else {
            let sheet = AddAccountWindowController(account: nil, secret: nil, onSave: { _, _ in }, onCancel: {})
            retained.append(sheet)
            window = sheet.window
        }
        defer { _ = retained }
        guard let window else { return }
        if kind.hasPrefix("share") {
            window.orderFrontRegardless()
            render(window: window, to: path, size: window.frame.size)
            app.terminate(nil)
            return
        }
        window.setContentSize(size)
        window.orderFrontRegardless()
        render(window: window, to: path, size: size)
        app.terminate(nil)
    }

    static func runLogs(path: String, size: NSSize, tab: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        prepare(app)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3c-logs-snapshot-\(UUID().uuidString)", isDirectory: true)
        let suite = "BucketManagerLogsSnapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = LogStore(directoryURL: directory, defaults: defaults)
        var settings = store.currentSettings()
        settings.diagnosticsEnabled = true
        settings.minimumLevel = .trace
        settings.auditEnabled = true
        settings.includeObjectKeys = true
        store.updateSettings(settings)

        let accountID = UUID()
        store.log(.info, category: .app, event: "app.launched", message: "Bucket Manager launched",
                  accountID: accountID, accountName: "Demo Account")
        store.log(.debug, category: .s3Request, event: "s3.request",
                  message: "ListObjectsV2 succeeded", accountID: accountID,
                  accountName: "Demo Account", bucket: "demo-bucket",
                  operation: "ListObjectsV2", outcome: "success", durationMs: 12,
                  metadata: ["prefix": "exports/"])
        store.log(.warning, category: .transfer, event: "transfer.failed",
                  message: "Upload part retried", accountID: accountID,
                  accountName: "Demo Account", bucket: "demo-bucket",
                  key: "exports/report.json.gz", operation: "UploadPart",
                  outcome: "failure", durationMs: 230)
        store.log(.error, category: .s3Request, event: "s3.request",
                  message: "HeadObject failed", accountID: accountID,
                  accountName: "Demo Account", bucket: "demo-bucket",
                  key: "missing.csv", operation: "HeadObject", outcome: "failure")
        store.audit(event: "account.added", message: "Account operation succeeded",
                    accountID: accountID, accountName: "Demo Account",
                    metadata: ["kind": "compatible", "bucket": "demo-bucket"])
        store.audit(event: "object.uploaded", message: "Upload transfer event",
                    accountID: accountID, accountName: "Demo Account",
                    bucket: "demo-bucket", key: "exports/report.json.gz",
                    operation: "upload", outcome: "success",
                    metadata: ["bytes": "81234567"])
        store.audit(event: "settings.logging.changed", message: "Logging settings updated",
                    outcome: "success")

        let metricsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3c-logs-snapshot-metrics-\(UUID().uuidString).json")
        let metrics = RequestMetricsStore(fileURL: metricsURL)
        let account = Account(
            displayName: "Demo Account", accessKeyID: "EXAMPLE",
            kind: .compatible, region: "us-east-005",
            endpoint: "https://s3.us-east-005.backblazeb2.com", bucket: "demo-bucket"
        )
        for (operation, count, failures) in [
            ("ListObjectsV2", 184, 0), ("GetObject", 92, 2), ("HeadObject", 48, 1), ("PutObject", 31, 0)
        ] {
            for index in 0..<count {
                metrics.record(
                    account: account, bucket: "demo-bucket", operation: operation,
                    outcome: index < failures ? "failure" : "success",
                    durationMs: Double(12 + index % 20), bytes: Int64(1024 * (index % 9))
                )
            }
        }
        metrics.flush()

        let controller = LogsWindowController(logStore: store, metricsStore: metrics)
        controller.selectTabForTesting(tab == "stats" ? 1 : tab == "settings" ? 2 : 0)
        guard let window = controller.window else { return }
        window.setContentSize(size)
        window.orderFrontRegardless()
        render(window: window, to: path, size: size)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: metricsURL)
        defaults.removePersistentDomain(forName: suite)
        app.terminate(nil)
    }

    private static func render(window: NSWindow, to path: String, size: NSSize) {
        guard let view = window.contentView else { return }

        if let split = view.subviews.compactMap({ $0 as? NSSplitView }).first {
            let sidebar = min(Theme.Metrics.sidebarWidth, max(240, size.width * 0.4))
            split.setPosition(sidebar, ofDividerAt: 0)
            if let right = split.arrangedSubviews.dropFirst().first as? NSSplitView {
                let contentHeight = size.height - Theme.Metrics.titleBarHeight - Theme.Metrics.menuBarHeight
                let browser = min(Theme.Metrics.initialBrowserHeight, max(160, contentHeight * 0.55))
                right.setPosition(browser, ofDividerAt: 0)
            }
        }

        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        view.layoutSubtreeIfNeeded()

        if ProcessInfo.processInfo.environment["S3C_A11Y"] == "1" {
            auditAccessibility(view)
        }

        let bounds = view.bounds
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot written: \(path) (\(Int(size.width))x\(Int(size.height)))\n".utf8))
    }

    private static func auditAccessibility(_ view: NSView, depth: Int = 0) {
        var label = view.accessibilityLabel() ?? ""
        if label.isEmpty, let field = view as? NSTextField { label = field.stringValue }
        if label.isEmpty, let button = view as? NSButton { label = button.title }
        let role = view.accessibilityRole()?.rawValue ?? ""
        let ignored = view is NSScroller || view is NSImageView || !view.isAccessibilityElement()
        let isInteractive = view is NSControl || view is NSTableView || view is NSTextView
        if isInteractive && !ignored && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && role != NSAccessibility.Role.scrollArea.rawValue {
            let description = String(describing: type(of: view))
            FileHandle.standardError.write(Data("A11Y missing label: \(description) role=\(role) frame=\(view.frame)\n".utf8))
        }
        for subview in view.subviews { auditAccessibility(subview, depth: depth + 1) }
    }
}
#endif
