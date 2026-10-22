import AppKit

private struct Bookmark: Codable {
    var accountID: UUID
    var bucket: String
    var prefix: String
    var title: String
}

@MainActor
final class MainWindowController: NSWindowController {
    let accounts: AccountStore
    let model: BrowserModel
    private let sidebar: SidebarViewController
    private let browser: BrowserViewController
    private let transfers: TransfersViewController

    private var titleBar: TitleBarView!
    private var menuBar: AppMenuBarView!
    private var addAccountSheet: AddAccountWindowController?
    private var storageSheet: StorageAccountsWindowController?
    private var logsWindowController: LogsWindowController?
    private var keyMonitor: Any?
    private var bookmarks: [Bookmark] = []

    init(accounts: AccountStore, model: BrowserModel) {
        self.accounts = accounts
        self.model = model
        self.sidebar = SidebarViewController(model: model)
        self.browser = BrowserViewController(model: model)
        self.transfers = TransfersViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.windowWidth, height: Theme.Metrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bucket Manager"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.Colors.titleBar
        window.minSize = NSSize(width: 900, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BucketManagerMainWindow")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }

        super.init(window: window)
        window.delegate = self

        loadBookmarks()
        buildContent()
        buildMenus()
        wire()
        installKeyMonitor()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func selectTabForSnapshot(_ id: String) {
        transfers.selectTab(id)
    }

    func showFilterForSnapshot(_ text: String) {
        browser.showFilterForSnapshot(text)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let split = self.window?.contentView?.subviews.compactMap({ $0 as? NSSplitView }).first {
                split.setPosition(Theme.Metrics.sidebarWidth, ofDividerAt: 0)
                if let right = split.arrangedSubviews.dropFirst().first as? NSSplitView {
                    right.setPosition(self.initialBrowserHeight(for: self.window?.contentView?.bounds.height ?? Theme.Metrics.windowHeight), ofDividerAt: 0)
                }
            }
        }
        sidebar.reload()
        if let account = model.selectedAccount, model.selectedBucket == nil {
            model.selectAccount(account)
        }
        browser.reload()
        transfers.reload()
        window?.makeFirstResponder(nil)
        if model.selectedBucket == nil {
            sidebar.focusInitial()
        } else {
            browser.focusInitial()
        }
    }

    // MARK: - Construction

    private func initialBrowserHeight(for height: CGFloat) -> CGFloat {
        let contentHeight = height - Theme.Metrics.titleBarHeight - Theme.Metrics.menuBarHeight
        return min(Theme.Metrics.initialBrowserHeight, max(160, contentHeight * 0.55))
    }

    private func buildContent() {
        guard let window else { return }
        let root = ThemedView()
        root.themeColor = Theme.Colors.window

        titleBar = TitleBarView()
        titleBar.title = "Bucket Manager"
        titleBar.translatesAutoresizingMaskIntoConstraints = false

        menuBar = AppMenuBarView()
        menuBar.translatesAutoresizingMaskIntoConstraints = false

        let rightSplit = NSSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.autosaveName = "BucketManagerRightSplit"
        rightSplit.translatesAutoresizingMaskIntoConstraints = false
        rightSplit.addArrangedSubview(browser.view)
        rightSplit.addArrangedSubview(transfers.view)
        rightSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "BucketManagerMainSplit"
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebar.view)
        split.addArrangedSubview(rightSplit)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.delegate = self
        rightSplit.delegate = self

        root.addSubview(titleBar)
        root.addSubview(menuBar)
        root.addSubview(split)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.titleBarHeight),

            menuBar.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            menuBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            menuBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            menuBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.menuBarHeight),

            split.topAnchor.constraint(equalTo: menuBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebar.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            sidebar.view.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            browser.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            transfers.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])

        window.contentView = root
    }

    private func wire() {
        sidebar.onAddAccount = { [weak self] in self?.presentAddAccount() }
        sidebar.onManageAccounts = { [weak self] in self?.presentStorageAccounts() }

        browser.onShowInspector = { [weak self] tab in self?.transfers.selectTab(tab) }
        browser.onBookmark = { [weak self] in self?.addBookmarkAction() }

        model.onTreeChange = { [weak self] in
            self?.sidebar.reload()
            self?.refreshMenus()
        }
        model.onFilesChange = { [weak self] in
            self?.browser.reload()
            self?.refreshMenus()
        }
        model.onChromeChange = { [weak self] in
            self?.browser.updateChrome()
            self?.sidebar.updateEmptyState()
            self?.refreshMenus()
        }
        model.onFolderMetric = { [weak self] key in
            self?.browser.updateFolderMetric(key)
        }
        model.onTransferChange = { [weak self] in
            self?.transfers.reload()
        }
        model.onDetailsChange = { [weak self] in
            self?.transfers.updateDetails()
        }
        model.onLogChange = { [weak self] in
            self?.transfers.updateLog()
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            if self.window?.firstResponder is NSTextView { return event }
            if self.handleCommandShortcut(event) { return nil }

            switch event.keyCode {
            case 96:
                Task { await self.model.refresh() }
                return nil
            case 120:
                guard self.browser.isTableFirstResponder else { return event }
                self.browser.renameSelected()
                return nil
            case 51, 117:
                guard self.browser.isTableFirstResponder else { return event }
                self.browser.deleteSelected()
                return nil
            case 53:
                guard self.browser.isTableFirstResponder else { return event }
                self.browser.goUp()
                return nil
            default:
                return event
            }
        }
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        let hasObjectSelection = model.selectedBucket != nil && model.selectedItem != nil
        let inTable = browser.isTableFirstResponder

        if flags == [.command] {
            switch event.keyCode {
            case 45:
                sidebar.newBucket()
                return true
            case 32:
                guard model.selectedBucket != nil else { return false }
                browser.uploadFiles()
                return true
            case 2:
                guard hasObjectSelection else { return false }
                browser.downloadSelected()
                return true
            case 15:
                Task { await model.refresh() }
                return true
            case 0:
                guard inTable, !model.visibleItems.isEmpty else { return false }
                browser.selectAllItems()
                return true
            case 7:
                guard inTable, !model.selection.isEmpty else { return false }
                browser.cutSelected()
                return true
            case 8:
                guard inTable, !model.selection.isEmpty else { return false }
                browser.copySelected()
                return true
            case 9:
                guard inTable, model.hasClipboard, model.selectedBucket != nil else { return false }
                browser.pasteItems()
                return true
            case 34:
                guard hasObjectSelection else { return false }
                browser.showProperties()
                return true
            case 3:
                guard model.selectedBucket != nil else { return false }
                browser.focusFilter()
                return true
            default:
                return false
            }
        }

        if flags == [.command, .shift] {
            switch event.keyCode {
            case 32:
                guard model.selectedBucket != nil else { return false }
                browser.uploadFolder()
                return true
            case 45:
                guard model.selectedBucket != nil else { return false }
                browser.newFolder()
                return true
            case 8:
                guard !model.selection.isEmpty else { return false }
                browser.copyTo()
                return true
            case 7:
                guard !model.selection.isEmpty else { return false }
                browser.moveTo()
                return true
            case 9:
                guard hasObjectSelection else { return false }
                browser.showVersions()
                return true
            case 11:
                guard model.selectedBucket != nil else { return false }
                addBookmarkAction()
                return true
            default:
                return false
            }
        }

        if flags == [.command, .option] {
            switch event.keyCode {
            case 45:
                addAccountAction()
                return true
            case 46:
                manageAccountsAction()
                return true
            default:
                return false
            }
        }

        return false
    }

    // MARK: - Sheets

    func presentAddAccount() {
        guard let window else { return }
        let sheet = AddAccountWindowController(
            account: nil,
            secret: nil,
            onSave: { [weak self] account, secret in
                guard let self, let secret else { return }
                do {
                    try self.accounts.add(account, secret: secret)
                    self.model.reloadAccounts()
                    self.model.selectAccount(account)
                    self.model.appendLog("Added account \(account.displayName)")
                } catch {
                    self.presentError("Could not save account", error.localizedDescription)
                }
            },
            onCancel: {}
        )
        addAccountSheet = sheet
        sheet.present(in: window)
    }

    func presentStorageAccounts() {
        guard let window else { return }
        let sheet = StorageAccountsWindowController(accounts: accounts, model: model)
        storageSheet = sheet
        sheet.present(in: window)
    }

    private func presentError(_ title: String, _ message: String) {
        AppLog.shared.error("\(title): \(message)")
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - Menu actions

    @objc private func addAccountAction() { presentAddAccount() }
    @objc private func manageAccountsAction() { presentStorageAccounts() }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String, let id = UUID(uuidString: idString),
              let account = accounts.account(id: id) else { return }
        model.selectAccount(account)
    }

    @objc private func newBucketAction() { sidebar.newBucket() }
    @objc private func deleteBucketAction() { sidebar.deleteBucketAction() }
    @objc private func refreshBucketsAction() { sidebar.refreshBuckets() }
    @objc func refreshAction() { Task { await model.refresh() } }

    @objc private func uploadFilesAction() { browser.uploadFiles() }
    @objc private func uploadFolderAction() { browser.uploadFolder() }
    @objc private func downloadAction() { browser.downloadSelected() }
    @objc private func deleteFilesAction() { browser.deleteSelected() }
    @objc private func newFolderAction() { browser.newFolder() }
    @objc private func renameAction() { browser.renameSelected() }
    @objc private func openAction() { browser.openSelected() }
    @objc private func copyAction() { browser.copySelected() }
    @objc private func cutAction() { browser.cutSelected() }
    @objc private func pasteAction() { browser.pasteItems() }
    @objc private func copyToAction() { browser.copyTo() }
    @objc private func moveToAction() { browser.moveTo() }
    @objc private func selectAllAction() { browser.selectAllItems() }
    @objc private func filterAction() { browser.focusFilter() }
    @objc private func propertiesAction() { browser.showProperties() }
    @objc private func versionsAction() { browser.showVersions() }

    @objc func showEventLogAction() { transfers.selectTab("log") }

    @objc func showLogsAction() {
        if logsWindowController == nil {
            logsWindowController = LogsWindowController()
        }
        logsWindowController?.showWindow(nil)
        logsWindowController?.window?.makeKeyAndOrderFront(nil)
        LogStore.shared.log(.info, category: .ui, event: "ui.logs.opened", message: "Logs window opened")
    }

    @objc func dumpDiagnostics() {
        let account = model.selectedAccount?.displayName ?? "none"
        let bucket = model.selectedBucket ?? "none"
        AppLog.shared.log("STATE account=\(account) bucket=\(bucket) prefix=\(model.prefix) items=\(model.items.count) status=\(model.status) busy=\(model.isBusy) error=\(model.errorMessage ?? "none")")
        for line in model.logs.suffix(30) { AppLog.shared.log("UI: \(line)") }
        browser.updateChrome()
    }

    @objc func showOptionsAction() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Options"
        alert.informativeText = """
        A calm, low-noise workspace for S3-compatible object storage.

        • Page size: 1,000 keys per request
        • Listing cache: 60 seconds
        • Inspector: active tab only, 180 ms debounce, 60 s metadata cache
        • Transfer concurrency: 4 simultaneous requests
        • Folder sizes: all rows in the current listing, one coalesced parent scan, 2 concurrent scans, 8 requests/second, 5 min persistent cache, 100,000-object cap

        These deliberate limits keep the app from bombarding an S3 endpoint.
        """

        let checkbox = NSButton(
            checkboxWithTitle: "Calculate folder sizes in the background",
            target: nil,
            action: nil
        )
        checkbox.state = model.calculateFolderSizes ? .on : .off
        checkbox.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.model.setCalculateFolderSizes(checkbox.state == .on)
            self.browser.refreshFolderStatsForListing()
        }
    }

    @objc func aboutAction() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Bucket Manager"
        alert.informativeText = """
        A native macOS client for S3-compatible object storage.

        Manage accounts, buckets, objects, transfers, and metadata in one focused workspace.

        Version \(version) · MIT License
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func shortcutsAction() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        ⌘N  New bucket
        ⌘U  Upload files
        ⇧⌘U Upload folder
        ⌘D  Download selected
        ⌘R  Refresh listing
        ⌘A  Select all
        ⌘F  Filter objects
        ⌘X / ⌘C / ⌘V  Cut / Copy / Paste objects
        ⇧⌘C / ⇧⌘X  Copy to / Move to
        ⌘I  Properties
        ⇧⌘V Versions
        F2  Rename
        Delete  Delete selected
        Esc  Go to parent folder
        F5  Refresh buckets and listing
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func addBookmarkAction() {
        guard let account = model.selectedAccount, let bucket = model.selectedBucket else { return }
        let bookmark = Bookmark(
            accountID: account.id,
            bucket: bucket,
            prefix: model.prefix,
            title: bucket + (model.prefix.isEmpty ? "" : "/" + model.prefix)
        )
        if !bookmarks.contains(where: { $0.accountID == bookmark.accountID && $0.bucket == bookmark.bucket && $0.prefix == bookmark.prefix }) {
            bookmarks.append(bookmark)
            saveBookmarks()
            refreshMenus()
        }
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 3, let id = UUID(uuidString: parts[0]),
              let account = accounts.account(id: id) else { return }
        model.selectAccount(account)
        model.openLocation(accountID: id, bucket: parts[1], prefix: parts[2])
    }

    @objc private func clearBookmarksAction() {
        bookmarks.removeAll()
        saveBookmarks()
        refreshMenus()
    }

    @objc private func testConnectionAction() {
        guard let account = model.selectedAccount, let window else { return }
        guard let secret = try? accounts.secret(for: account) else {
            presentError("No secret", "The Keychain does not contain a secret for this account.")
            return
        }
        Task {
            do {
                let buckets = try await S3Service.shared.listBuckets(account: account, secret: secret, useCache: false)
                let alert = NSAlert()
                alert.messageText = "Connection OK"
                alert.informativeText = "\(buckets.count) bucket\(buckets.count == 1 ? "" : "s") visible for \(account.displayName)."
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: nil)
            } catch {
                self.presentError("Connection failed", S3ErrorPresenter.message(for: error))
            }
        }
    }

    @objc private func generateWebURL() {
        guard let account = model.selectedAccount, let bucket = model.selectedBucket,
              let item = model.selectedItem, item.kind == .object else { return }
        let encodedKey = item.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.key
        let url: String
        if account.kind == .compatible, let endpoint = account.endpoint {
            let scheme = account.useSSL ? "https" : "http"
            let host = endpoint.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            if account.usePathStyle {
                url = "\(scheme)://\(host)/\(bucket)/\(encodedKey)"
            } else {
                url = "\(scheme)://\(bucket).\(host)/\(encodedKey)"
            }
        } else if account.region == "us-east-1" || account.region.isEmpty {
            url = "https://\(bucket).s3.amazonaws.com/\(encodedKey)"
        } else {
            url = "https://\(bucket).s3.\(account.region).amazonaws.com/\(encodedKey)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        model.appendLog("Copied URL \(url)")
        browser.updateChrome()
    }

    // MARK: - Bookmarks persistence

    private func loadBookmarks() {
        let defaults = UserDefaults.standard
        let legacyKey = "\(LegacyImport.defaultsPrefix)Bookmarks"
        guard let data = defaults.data(forKey: "BucketManagerBookmarks")
                ?? defaults.data(forKey: legacyKey) else { return }
        do {
            bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            AppLog.shared.error("Could not read saved bookmarks: \(error.localizedDescription)")
            return
        }
        if defaults.data(forKey: "BucketManagerBookmarks") == nil {
            defaults.set(data, forKey: "BucketManagerBookmarks")
        }
    }

    private func saveBookmarks() {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            UserDefaults.standard.set(data, forKey: "BucketManagerBookmarks")
        } catch {
            AppLog.shared.error("Could not save bookmarks: \(error.localizedDescription)")
        }
    }

    // MARK: - Menus

    private func buildMenus() {
        menuBar.setMenus([
            ("Accounts", accountsMenu()),
            ("Buckets", bucketsMenu()),
            ("Files", filesMenu()),
            ("Bookmarks", bookmarksMenu()),
            ("Tools", toolsMenu()),
            ("Help", helpMenu())
        ])
    }

    private func refreshMenus() {
        guard menuBar != nil else { return }
        buildMenus()
    }

    private func baseMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        return menu
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func accountsMenu() -> NSMenu {
        let menu = baseMenu()
        for account in accounts.accounts {
            let item = menu.addItem(withTitle: account.displayName, action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id.uuidString
            item.state = model.selectedAccount?.id == account.id ? .on : .off
        }
        if !accounts.accounts.isEmpty { menu.addItem(.separator()) }
        _ = item(menu, "Add new account…", #selector(addAccountAction), key: "n", modifiers: [.command, .option])
        _ = item(menu, "Manage accounts…", #selector(manageAccountsAction), key: "m", modifiers: [.command, .option])
        menu.addItem(.separator())
        _ = item(menu, "Exit", #selector(NSApplication.terminate(_:)), key: "q")
        menu.items.last?.target = NSApp
        return menu
    }

    private func bucketsMenu() -> NSMenu {
        let menu = baseMenu()
        _ = item(menu, "New bucket…", #selector(newBucketAction), key: "n")
        _ = item(menu, "Delete bucket…", #selector(deleteBucketAction))
        _ = item(menu, "Refresh buckets list", #selector(refreshBucketsAction), key: "r", modifiers: [.command, .shift])
        menu.addItem(.separator())
        let advanced = [
            "Edit Access Control List (ACL)…",
            "Add External Bucket…",
            "Mount as Windows Drive…",
            "Bucket Sharing Wizard…",
            "Edit Tags…",
            "Edit Bucket Policy…",
            "Edit Logging Settings…",
            "Edit Website Configuration…",
            "Edit Versioning Settings…",
            "Default Encryption Configuration…",
            "Public Access Block Configuration…",
            "Object Ownership Configuration…",
            "Object Lock",
            "Transfer Acceleration…",
            "Cross-Region Replication…",
            "Lifecycle Configuration…",
            "CORS Configuration…",
            "Intelligent Tiering Configuration…"
        ]
        for title in advanced {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.tag = 999
            item.isEnabled = false
        }
        _ = item(menu, "Generate Web URLs…", #selector(generateWebURL))
        let storage = menu.addItem(withTitle: "Change Storage Class to…", action: nil, keyEquivalent: "")
        storage.tag = 999
        storage.isEnabled = false
        return menu
    }

    private func filesMenu() -> NSMenu {
        let menu = baseMenu()
        _ = item(menu, "Open", #selector(openAction), key: "\r", modifiers: [])
        _ = item(menu, "Download…", #selector(downloadAction), key: "d")
        _ = item(menu, "Upload file(s)…", #selector(uploadFilesAction), key: "u")
        _ = item(menu, "Upload folder(s)…", #selector(uploadFolderAction), key: "u", modifiers: [.command, .shift])
        menu.addItem(.separator())
        _ = item(menu, "Cut", #selector(cutAction), key: "x")
        _ = item(menu, "Copy", #selector(copyAction), key: "c")
        _ = item(menu, "Paste", #selector(pasteAction), key: "v")
        _ = item(menu, "Copy to…", #selector(copyToAction), key: "c", modifiers: [.command, .shift])
        _ = item(menu, "Move to…", #selector(moveToAction), key: "x", modifiers: [.command, .shift])
        _ = item(menu, "Rename…", #selector(renameAction))
        _ = item(menu, "Delete", #selector(deleteFilesAction))
        menu.addItem(.separator())
        _ = item(menu, "Create New Folder…", #selector(newFolderAction), key: "n", modifiers: [.command, .shift])
        menu.addItem(.separator())
        _ = item(menu, "Properties", #selector(propertiesAction), key: "i")
        _ = item(menu, "Versions", #selector(versionsAction), key: "v", modifiers: [.command, .shift])
        menu.addItem(.separator())
        _ = item(menu, "Select All", #selector(selectAllAction), key: "a")
        _ = item(menu, "Filter Objects…", #selector(filterAction), key: "f")
        _ = item(menu, "Refresh", #selector(refreshAction), key: "r")
        return menu
    }

    private func bookmarksMenu() -> NSMenu {
        let menu = baseMenu()
        _ = item(menu, "Add Current Location", #selector(addBookmarkAction), key: "b", modifiers: [.command, .shift])
        if !bookmarks.isEmpty {
            menu.addItem(.separator())
            for bookmark in bookmarks {
                let item = menu.addItem(withTitle: bookmark.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(bookmark.accountID.uuidString)|\(bookmark.bucket)|\(bookmark.prefix)"
            }
            menu.addItem(.separator())
            _ = item(menu, "Clear Bookmarks", #selector(clearBookmarksAction))
        }
        return menu
    }

    private func toolsMenu() -> NSMenu {
        let menu = baseMenu()
        _ = item(menu, "Options…", #selector(showOptionsAction), key: ",")
        _ = item(menu, "Logs & Statistics…", #selector(showLogsAction), key: "l", modifiers: [.command, .option])
        _ = item(menu, "Event Log", #selector(showEventLogAction))
        _ = item(menu, "Test Connection", #selector(testConnectionAction))
        _ = item(menu, "Dump Diagnostics to Log", #selector(dumpDiagnostics), key: "d", modifiers: [.command, .shift])
        menu.addItem(.separator())
        _ = item(menu, "Refresh", #selector(refreshAction), key: "r")
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = baseMenu()
        _ = item(menu, "Keyboard Shortcuts", #selector(shortcutsAction))
        menu.addItem(.separator())
        _ = item(menu, "About Bucket Manager", #selector(aboutAction))
        return menu
    }
}

extension MainWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.isVertical ? 240 : 130
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.isVertical ? max(260, splitView.bounds.width - 560) : max(160, splitView.bounds.height - 130)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        true
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == 999 { return false }
        switch menuItem.action {
        case #selector(uploadFilesAction), #selector(uploadFolderAction), #selector(newFolderAction):
            return model.selectedBucket != nil
        case #selector(downloadAction), #selector(deleteFilesAction), #selector(renameAction),
             #selector(propertiesAction), #selector(versionsAction), #selector(generateWebURL):
            return model.selectedItem != nil
        case #selector(copyAction), #selector(cutAction):
            return !model.selection.isEmpty
        case #selector(pasteAction):
            return model.hasClipboard && model.selectedBucket != nil
        case #selector(copyToAction), #selector(moveToAction):
            return !model.selection.isEmpty && model.selectedBucket != nil
        case #selector(selectAllAction), #selector(filterAction):
            return !model.visibleItems.isEmpty
        case #selector(deleteBucketAction):
            return model.selectedBucket != nil
        case #selector(testConnectionAction), #selector(refreshBucketsAction):
            return model.selectedAccount != nil
        case #selector(addBookmarkAction):
            return model.selectedBucket != nil
        default:
            return true
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
