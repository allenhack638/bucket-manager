#if DEBUG
import AppKit

/// Headless interaction checks for the dialog controllers. These call the same
/// action methods the buttons call, so validation, save, and cancel behavior are
/// exercised without a screen-recording or accessibility permission.
@MainActor
enum UITest {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)

        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition {
                passed += 1
                print("UITEST PASS  \(name)")
            } else {
                failed += 1
                print("UITEST FAIL  \(name)")
            }
        }

        var saved: (Account, String?)?
        var cancelled = false
        let add = AddAccountWindowController(
            account: nil,
            secret: nil,
            onSave: { account, secret in saved = (account, secret) },
            onCancel: { cancelled = true }
        )

        add.testFill(name: "", access: "", secret: "", region: "us-east-1", endpoint: "", kind: .amazonS3)
        add.testSave()
        check(saved == nil && !add.testErrorText.isEmpty, "required fields block save")

        add.testFill(name: "Test Account", access: "EXAMPLE_ACCESS_KEY", secret: UUID().uuidString, region: "us-east-1", endpoint: "", kind: .amazonS3)
        add.testSave()
        check(saved?.0.displayName == "Test Account", "valid save emits account")
        check(saved?.1 == UUID().uuidString, "valid save emits secret")
        check(add.testErrorText.isEmpty, "successful save clears the error")

        saved = nil
        let compatible = AddAccountWindowController(
            account: nil,
            secret: nil,
            onSave: { account, secret in saved = (account, secret) },
            onCancel: {}
        )
        compatible.testFill(name: "Compatible", access: "KEY", secret: UUID().uuidString, region: "us-east-1", endpoint: "", kind: .compatible)
        compatible.testSave()
        check(saved == nil && !compatible.testErrorText.isEmpty, "compatible account requires an endpoint")

        compatible.testFill(
            name: "Compatible", access: "KEY", secret: UUID().uuidString, region: "us-east-1",
            endpoint: "https://s3.example.com", kind: .compatible, bucket: "example-bucket"
        )
        compatible.testSave()
        check(saved?.0.endpoint == "https://s3.example.com", "compatible endpoint is saved")
        check(saved?.0.bucket == "example-bucket", "bucket-scoped account saves its bucket")

        let existing = Account(
            displayName: "Existing",
            accessKeyID: "KEY",
            kind: .compatible,
            region: "us-east-1",
            endpoint: "https://old.example.com"
        )
        var edited: (Account, String?)?
        let accountStore = AccountStore(
            inMemoryAccounts: [existing],
            secrets: [existing.id: UUID().uuidString]
        )
        var renamed = existing
        renamed.displayName = "Renamed Account"
        try? accountStore.update(renamed, secret: nil)
        check(accountStore.account(id: existing.id)?.displayName == "Renamed Account",
              "account metadata update is persisted")
        accountStore.remove(renamed)
        check(accountStore.accounts.isEmpty, "account removal deletes the account")

        let editSheet = AddAccountWindowController(
            account: existing,
            secret: UUID().uuidString,
            onSave: { account, secret in edited = (account, secret) },
            onCancel: {}
        )
        check(editSheet.testEndpointControlsVisible,
              "editing a compatible account exposes endpoint controls")
        check(editSheet.testBucketControlVisible,
              "editing a compatible account exposes the bucket field")
        editSheet.testFill(
            name: "Existing", access: "KEY", secret: "", region: "us-east-1",
            endpoint: "https://new.example.com", kind: .compatible, bucket: "new-bucket"
        )
        editSheet.testSave()
        check(edited?.0.endpoint == "https://new.example.com",
              "editing an account saves the changed endpoint")
        check(edited?.0.bucket == "new-bucket", "editing an account saves the bucket")
        check(edited?.1 == nil, "blank secret keeps the existing Keychain secret")

        let scopedAccount = Account(
            displayName: "Bucket Scoped", accessKeyID: "KEY", kind: .compatible,
            endpoint: "https://s3.example.com", bucket: "only-bucket"
        )
        let scopedStore = AccountStore(inMemoryAccounts: [scopedAccount])
        let scopedModel = BrowserModel(accounts: scopedStore)
        scopedModel.selectAccount(scopedAccount)
        check(scopedModel.buckets.map(\.name) == ["only-bucket"],
              "bucket-scoped account skips ListBuckets")
        check(!scopedModel.isLoadingBuckets,
              "bucket-scoped account does not wait for ListBuckets")

        let typeSheet = AddAccountWindowController(
            account: existing, secret: UUID().uuidString,
            onSave: { _, _ in }, onCancel: {}
        )
        typeSheet.testFill(
            name: "Existing", access: "KEY", secret: "", region: "us-east-1",
            endpoint: "", kind: .amazonS3
        )
        check(!typeSheet.testEndpointControlsVisible,
              "Amazon S3 mode hides custom endpoint controls")
        typeSheet.testFill(
            name: "Existing", access: "KEY", secret: "", region: "us-east-1",
            endpoint: "https://new.example.com", kind: .compatible
        )
        check(typeSheet.testEndpointControlsVisible,
              "switching back to compatible restores endpoint controls")

        let cancelSheet = AddAccountWindowController(
            account: nil,
            secret: nil,
            onSave: { _, _ in failed += 1; print("UITEST FAIL  cancel triggered save") },
            onCancel: { cancelled = true }
        )
        cancelSheet.testCancel()
        check(cancelled, "cancel emits cancel callback")

        var destination: String?
        let crumbs = BreadcrumbView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        crumbs.onNavigate = { destination = $0 }
        crumbs.setPath(bucket: "my-bucket", prefix: "originals/2026/")
        crumbs.layout()
        func press(_ label: String) -> Bool {
            guard let button = crumbs.subviews.compactMap({ $0 as? NSButton })
                .first(where: { ($0.accessibilityLabel() ?? $0.title) == label }) else { return false }
            button.performClick(nil)
            return true
        }
        check(press("Open folder originals"), "breadcrumb exposes parent segments")
        check(destination == "originals/", "breadcrumb navigates to the parent prefix")
        destination = nil
        check(press("Open bucket my-bucket"), "breadcrumb exposes the bucket segment")
        check(destination == "", "breadcrumb navigates to the bucket root")
        destination = nil
        check(press("Current folder 2026"), "breadcrumb exposes the current segment")
        check(destination == nil, "current breadcrumb segment does not navigate")

        let marker = S3Item.listed(key: "new-folder/", size: 0, lastModified: nil, storageClass: "STANDARD", eTag: "x")
        check(marker.kind == .folder, "trailing-slash markers are folders")
        check(marker.displayName == "new-folder", "folder markers hide the trailing slash")
        check(S3Key.safeLocalName("..") == "_", "download names cannot escape the directory")
        check(S3Key.safeLocalName("a/b") == "a_b", "download names cannot contain separators")
        check(S3Key.safeRelativePath("photos/2026/a.jpg") == "photos/2026/a.jpg",
              "recursive downloads preserve safe nested paths")
        check(S3Key.safeRelativePath("../../etc/passwd") == "_/_/etc/passwd",
              "recursive downloads cannot escape the destination")
        check((try? EndpointValidator.normalized("s3.example.com", useSSL: true)) == "https://s3.example.com",
              "bare endpoints are upgraded to HTTPS")
        check((try? EndpointValidator.normalized("http://127.0.0.1:9000", useSSL: false)) != nil,
              "plain HTTP is allowed for loopback endpoints")
        check((try? EndpointValidator.normalized("http://s3.example.com", useSSL: false)) == nil,
              "plain HTTP is rejected for remote endpoints")
        check((try? EndpointValidator.normalized("https://user:pass@example.com", useSSL: true)) == nil,
              "endpoint userinfo is rejected")
        check((try? EndpointValidator.normalized("ftp://example.com", useSSL: true)) == nil,
              "non-HTTP endpoint schemes are rejected")
        check((try? EndpointValidator.normalized("https://example.com/path?q=1", useSSL: true)) == nil,
              "endpoint query strings are rejected")

        check(S3Key.parentPrefix(of: "folder/sub/item.txt") == "folder/sub/",
              "object keys resolve to their parent prefix")
        check(S3Key.parentPrefix(of: "folder/sub/") == "folder/",
              "folder keys resolve to their parent prefix")
        let accessDenied = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AccessDenied"]
        )
        check(S3ErrorPresenter.message(for: accessDenied).contains("Access denied"),
              "S3 errors map to a user-facing message")

        var secretReads = 0
        let cacheAccount = Account(displayName: "Cache", accessKeyID: "K", kind: .amazonS3)
        let cacheStore = AccountStore(
            inMemoryAccounts: [cacheAccount],
            secretLoader: { _ in
                secretReads += 1
                return "cache-secret"
            }
        )
        _ = try? cacheStore.secret(for: cacheAccount)
        _ = try? cacheStore.secret(for: cacheAccount)
        check(secretReads == 1, "secret loader runs once per account per launch")

        let demoStore = AccountStore(inMemoryAccounts: [])
        let demoModel = BrowserModel(accounts: demoStore)
        demoModel.loadDemoData()
        if let demoItem = demoModel.items.first(where: { $0.kind == .object }) {
            demoModel.setSelection([demoItem.key])
            check(!demoModel.inspectorLoaded("properties", for: demoItem), "inspector metadata starts unloaded")
            demoModel.loadDemoDetails()
            check(demoModel.inspectorLoaded("properties", for: demoItem), "properties cache is keyed to the selected object")
            check(demoModel.inspectorLoaded("tags", for: demoItem), "tags cache is keyed to the selected object")
        }

        check(demoModel.buckets.count == 16, "account buckets are exposed for the sidebar")
        check(demoModel.buckets.contains { $0.name == "my-photos" },
              "the sidebar bucket list contains account buckets")
        demoModel.setFilter("Border_2px")
        check(demoModel.visibleItems.count == 1, "filtering narrows the object list")
        check(demoModel.statusText.contains("of"), "filtered status reports the visible and total counts")
        demoModel.setSelection(Set(demoModel.visibleItems.map(\.key)))
        demoModel.setFilter("Border_1px")
        check(demoModel.selection.isEmpty, "filtering clears selections that are no longer visible")
        demoModel.setFilter("")
        check(demoModel.visibleItems.count == demoModel.items.count,
              "clearing the filter restores every object")

        let locationOne = Account(displayName: "One", accessKeyID: "A", kind: .amazonS3)
        let locationTwo = Account(displayName: "Two", accessKeyID: "B", kind: .amazonS3)
        let locationStore = AccountStore(inMemoryAccounts: [locationOne, locationTwo])
        let locationModel = BrowserModel(accounts: locationStore)
        locationModel.openLocation(accountID: locationTwo.id, bucket: "bucket-two", prefix: "folder/sub/")
        check(locationModel.selectedAccount?.id == locationTwo.id, "folder selection switches to the folder's account")
        check(locationModel.selectedBucket == "bucket-two", "folder selection switches to the folder's bucket")
        check(locationModel.prefix == "folder/sub/", "folder selection sets the full prefix")
        check(locationModel.items.isEmpty, "folder selection clears the previous listing")

        let switchAccount = Account(displayName: "Switch", accessKeyID: "KEY", kind: .amazonS3)
        let switchStore = AccountStore(inMemoryAccounts: [switchAccount])
        let switchModel = BrowserModel(accounts: switchStore)
        switchModel.selectBucket("new-bucket")
        check(switchModel.selectedBucket == "new-bucket", "bucket selection changes immediately")
        check(switchModel.prefix.isEmpty, "bucket selection resets the prefix immediately")
        check(switchModel.items.isEmpty, "bucket selection clears the previous listing immediately")

        let chromeStore = AccountStore(inMemoryAccounts: [])
        let chrome = MainWindowController(
            accounts: chromeStore,
            model: BrowserModel(accounts: chromeStore)
        )
        check(chrome.window?.standardWindowButton(.closeButton)?.isHidden == false,
              "native close traffic light is visible")
        check(chrome.window?.standardWindowButton(.miniaturizeButton)?.isHidden == false,
              "native minimize traffic light is visible")
        check(chrome.window?.standardWindowButton(.zoomButton)?.isHidden == false,
              "native zoom traffic light is visible")
        check((chrome.window?.standardWindowButton(.closeButton)?.frame.minX ?? 999) < 60,
              "native traffic lights are on the left")
        check(chrome.window?.styleMask.contains(.fullSizeContentView) == true,
              "full-size content keeps the custom chrome")
        check(Theme.Metrics.trafficLightInset >= 78, "titlebar reserves space for traffic lights")
        check(Theme.Icon.toolbar.size == 16 && Theme.Icon.toolbar.weight == .regular,
              "toolbar icon token follows the standard 16 pt size")
        check(Theme.Icon.action.size == 14, "action icon token follows the standard 14 pt size")
        check(Theme.Icon.row.size == 16 && Theme.Icon.status.size == 12,
              "table and status icon tokens follow their standard sizes")
        check(Theme.Icon.emptyState.size == 32 && Theme.Icon.header.size == 28,
              "empty-state and sheet-header icon tokens are not over-scaled")
        check(Theme.Icon.sortIndicator.weight == .semibold,
              "sort indicator weight is formalized")

        let metricKey = FolderStatsKey(accountID: UUID(), bucket: "bucket", prefix: "metrics/")
        let loading = FolderStatsSnapshot(key: metricKey, record: nil, state: .loading)
        check(loading.sizeText == "…", "folder size shows a loading ellipsis")
        let record = FolderStatsRecord(
            accountID: metricKey.accountID, bucket: metricKey.bucket, prefix: metricKey.prefix,
            size: 1024, objectCount: 3, newestObjectDate: Date(), computedAt: Date(), partial: false
        )
        let ready = FolderStatsSnapshot(key: metricKey, record: record, state: .ready)
        check(!ready.sizeText.isEmpty, "ready folder size is rendered")
        let partial = FolderStatsSnapshot(
            key: metricKey,
            record: FolderStatsRecord(
                accountID: metricKey.accountID, bucket: metricKey.bucket, prefix: metricKey.prefix,
                size: 1024, objectCount: 3, newestObjectDate: nil, computedAt: Date(), partial: true
            ),
            state: .partial
        )
        check(partial.sizeText.hasPrefix("≥"), "partial folder size is marked")
        let failedSnapshot = FolderStatsSnapshot(key: metricKey, record: nil, state: .failed("Access denied"))
        check(failedSnapshot.sizeText == "—", "failed folder size is a dash")

        let store = AccountStore(inMemoryAccounts: [
            Account(displayName: "One", accessKeyID: "A", kind: .amazonS3),
            Account(displayName: "Two", accessKeyID: "B", kind: .compatible, endpoint: "https://example.com")
        ])
        let model = BrowserModel(accounts: store)
        let storage = StorageAccountsWindowController(accounts: store, model: model)
        storage.reload()
        check(storage.testRowCount() == 2, "storage manager shows every account")
            var customButtonPressed = false
            let customButton = FlatButton("Test action", style: .action)
            customButton.onClick = { customButtonPressed = true }
            check(customButton.accessibilityRole() == .button,
                  "custom action button exposes the button role")
            check(customButton.accessibilityPerformPress() && customButtonPressed,
                  "custom action button performs its action through accessibility")

            let header = ColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
            let headerWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 24),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            headerWindow.contentView = header
            header.columns = [
                HeaderColumn(id: "name", title: "Name", width: 200, alignment: .left),
                HeaderColumn(id: "size", title: "Size", width: 100, alignment: .right)
            ]
            var sortedColumn: String?
            header.onSort = { sortedColumn = $0 }
            var resizedColumn: String?
            var resizedWidth: CGFloat = 0
            header.onResize = { id, width in
                resizedColumn = id
                resizedWidth = width
            }
            func mouse(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type,
                    location: NSPoint(x: x, y: 12),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            }
            if let down = mouse(.leftMouseDown, x: 200, window: headerWindow),
               let drag = mouse(.leftMouseDragged, x: 240, window: headerWindow),
               let up = mouse(.leftMouseUp, x: 240, window: headerWindow) {
                header.mouseDown(with: down)
                header.mouseDragged(with: drag)
                header.mouseUp(with: up)
            }
            check(resizedColumn == "name" && abs(resizedWidth - 240) < 1,
                  "column dividers resize their table column")
            check(sortedColumn == nil, "dragging a divider does not trigger sorting")
            check(header.columns.first?.width == 240,
                  "the header and table column widths stay synchronized")
            let headerChildren = header.accessibilityChildren() ?? []
            check(headerChildren.count == 2,
                  "each table column exposes a sort accessibility element")
            if let sizeElement = headerChildren.last as? NSAccessibilityElement {
                check(sizeElement.accessibilityLabel() == "Sort by Size",
                      "sort accessibility element names its column")
                check(sizeElement.accessibilityPerformPress() && sortedColumn == "size",
                      "sort accessibility element performs the sort action")
            }
            let tabButton = FlatButton("Event Log", style: .tab)
            check(tabButton.accessibilityRole() == .radioButton,
                  "inspector tabs expose the radio-button role")

            let menuButton = FlatButton("Tools", style: .menu)
            var menuOpened = false
            menuButton.onClick = { menuOpened = true }
            check(menuButton.accessibilityPerformPress() && menuOpened,
                  "menu buttons can be opened through accessibility")

            let tabStrip = TabStripView(frame: .zero)
            check(tabStrip.accessibilityRole() == .tabGroup,
                  "inspector tab strip exposes the tab-group role")





        print("UITEST SUMMARY passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
