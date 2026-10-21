import AppKit

@MainActor
enum SnapshotRunner {
    static func runMain(path: String, size: NSSize, tab: String?, empty: String?, pathPrefix: String?, errorMessage: String?, filter: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = ProcessInfo.processInfo.environment["S3C_APPEARANCE"] == "dark"
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)

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
        app.appearance = ProcessInfo.processInfo.environment["S3C_APPEARANCE"] == "dark"
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)

        let accounts = AccountStore(inMemoryAccounts: [
            Account(displayName: "Amazon S3 Storage", accessKeyID: "EXAMPLE_ACCESS_KEY", kind: .amazonS3, region: "us-east-1"),
            Account(displayName: "S3-Compatible Storage", accessKeyID: "EXAMPLE0000000000000", kind: .compatible, region: "us-east-1", endpoint: "https://s3.example.com"),
            Account(displayName: "Wasabi Test", accessKeyID: "EXAMPLE0000000000001", kind: .compatible, region: "us-east-1", endpoint: "https://s3.wasabisys.com")
        ])
        let model = BrowserModel(accounts: accounts)
        model.reloadAccounts()

        var retained: [AnyObject] = []
        let window: NSWindow?
        if kind == "accounts" {
            let sheet = StorageAccountsWindowController(accounts: accounts, model: model)
            sheet.reload()
            retained.append(sheet)
            window = sheet.window
        } else {
            let sheet = AddAccountWindowController(account: nil, secret: nil, onSave: { _, _ in }, onCancel: {})
            retained.append(sheet)
            window = sheet.window
        }
        defer { _ = retained }
        guard let window else { return }
        window.setContentSize(size)
        window.orderFrontRegardless()
        render(window: window, to: path, size: size)
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
