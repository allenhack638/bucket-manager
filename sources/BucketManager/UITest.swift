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

        let testSecret = UUID().uuidString
        add.testFill(name: "Test Account", access: "AKIA" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)), secret: testSecret, region: "us-east-1", endpoint: "", kind: .amazonS3)
        add.testSave()
        check(saved?.0.displayName == "Test Account", "valid save emits account")
        check(saved?.1 == testSecret, "valid save emits secret")
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
        demoModel.setFilter("IMG_7072")
        check(demoModel.visibleItems.count == 1, "filtering narrows the object list")
        check(demoModel.statusText.contains("of"), "filtered status reports the visible and total counts")
        demoModel.setSelection(Set(demoModel.visibleItems.map(\.key)))
        demoModel.setFilter("IMG_7071")
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
        check(Theme.Icon.emptyState.size == 32 && Theme.Metrics.brandIconSize == 38,
              "empty-state and account-brand icons use their standard sizes")
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

            let passcodePassword = UUID().uuidString
            let passcode = PasscodeHasher.make(password: passcodePassword)
            check(passcode.salt.count == 16 && passcode.hash.count == 32,
                  "admin passcode uses a salted 256-bit verifier")
            check(PasscodeHasher.verify(passcodePassword, against: passcode),
                  "admin passcode verifier accepts the correct passphrase")
            check(!PasscodeHasher.verify(UUID().uuidString, against: passcode),
                  "admin passcode verifier rejects a wrong passphrase")
            let secondPasscode = PasscodeHasher.make(password: passcodePassword, iterations: 10)
            check(passcode.hash != secondPasscode.hash,
                  "admin passcode verifiers are salted per creation")
            AdminAuthSession.shared.lock()
            check(!AdminAuthSession.shared.isUnlocked, "admin authorization starts locked")
            AdminAuthSession.shared.unlock()
            check(AdminAuthSession.shared.isUnlocked, "admin authorization unlocks the session")
            AdminAuthSession.shared.lock()

            let logDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("s3c-log-test-\(UUID().uuidString)", isDirectory: true)
            let defaultsName = "BucketManagerLoggingTests-\(UUID().uuidString)"
            let testDefaults = UserDefaults(suiteName: defaultsName) ?? .standard
            testDefaults.removePersistentDomain(forName: defaultsName)
            let logStore = LogStore(directoryURL: logDirectory, defaults: testDefaults)
            let initialSettings = logStore.currentSettings()
            check(!initialSettings.diagnosticsEnabled, "diagnostic logging defaults off")
            check(initialSettings.auditEnabled, "audit logging defaults on")

            logStore.log(.info, category: .app, event: "test.disabled", message: "hidden")
            logStore.audit(event: "test.audit", message: "visible audit")
            logStore.flush()
            let defaultRecords = logStore.recent()
            check(defaultRecords.contains { $0.event == "test.audit" },
                  "audit records are written while diagnostics are off")
            check(!defaultRecords.contains { $0.event == "test.disabled" },
                  "diagnostic records are suppressed by default")

            var enabled = initialSettings
            enabled.diagnosticsEnabled = true
            enabled.minimumLevel = .debug
            enabled.includeObjectKeys = false
            logStore.updateSettings(enabled)
            logStore.log(
                .debug,
                category: .s3Request,
                event: "test.request",
                message: "request",
                accountID: UUID(),
                accountName: "Test",
                bucket: "bucket",
                key: "private/key.txt",
                operation: "ListObjectsV2",
                outcome: "success",
                metadata: [
                    "Authorization": "super-secret-value",
                    "x-amz-security-token": "super-secret-value"
                ]
            )
            logStore.flush()
            let diagnosticRecords = logStore.recent()
            check(diagnosticRecords.contains { $0.event == "test.request" },
                  "enabled diagnostics write structured records")
            check(diagnosticRecords.first { $0.event == "test.request" }?.key == nil,
                  "object keys are redacted when disabled")
            check(diagnosticRecords.first { $0.event == "test.request" }?.metadata["Authorization"] == "<redacted>",
                  "authorization metadata is redacted")
            let diagnosticFiles = (try? FileManager.default.contentsOfDirectory(
                at: logDirectory, includingPropertiesForKeys: nil
            )) ?? []
            let diagnosticFile = diagnosticFiles.first { $0.lastPathComponent.hasPrefix("diagnostic-") }
            let diagnosticText = diagnosticFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            check(!diagnosticText.contains("super-secret-value"),
                  "redacted secrets never reach disk")
            let permissions = diagnosticFile.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?
                    .intValue
            } ?? 0
            check(permissions == 0o600, "diagnostic log files are owner-only")

            var rotationSettings = logStore.currentSettings()
            rotationSettings.diagnosticsEnabled = true
            rotationSettings.minimumLevel = .trace
            rotationSettings.maxFileBytes = 200
            rotationSettings.diagnosticRetentionDays = 1
            let oldLog = logDirectory.appendingPathComponent("diagnostic-2000-01-01.jsonl")
            try? Data("{}\n".utf8).write(to: oldLog)
            logStore.updateSettings(rotationSettings)
            logStore.flush()
            check(!FileManager.default.fileExists(atPath: oldLog.path),
                  "retention removes expired diagnostic files")
            for index in 0..<10 {
                logStore.log(
                    .info, category: .app, event: "rotation.\(index)",
                    message: String(repeating: "x", count: 300)
                )
            }
            logStore.flush()
            let rotatedFiles = (try? FileManager.default.contentsOfDirectory(
                at: logDirectory, includingPropertiesForKeys: nil
            )) ?? []
            check(rotatedFiles.contains { $0.lastPathComponent.hasSuffix(".jsonl.1") },
                  "size rotation keeps a backup log file")

            enabled.minimumLevel = .error
            logStore.updateSettings(enabled)
            logStore.log(.warning, category: .app, event: "test.warning", message: "filtered")
            logStore.flush()
            check(!logStore.recent().contains { $0.event == "test.warning" },
                  "minimum log level filters lower-severity records")

            let metricsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("s3c-metrics-test-\(UUID().uuidString).json")
            let metrics = RequestMetricsStore(fileURL: metricsURL)
            let metricsAccount = Account(
                displayName: "Metrics Test",
                accessKeyID: "KEY",
                kind: .compatible,
                endpoint: "https://example.com"
            )
            metrics.record(
                account: metricsAccount, bucket: "alpha", operation: "ListObjectsV2",
                outcome: "success", durationMs: 12, bytes: 100
            )
            metrics.record(
                account: metricsAccount, bucket: "alpha", operation: "GetObject",
                outcome: "failure", durationMs: 30
            )
            let metricSnapshot = metrics.snapshot()
            check(metricSnapshot.contains { $0.operation == "ListObjectsV2" && $0.count == 1 && $0.bytes == 100 },
                  "request metrics aggregate per operation")
            check(metricSnapshot.contains { $0.operation == "GetObject" && $0.failures == 1 },
                  "request metrics count failures")
            metrics.flush()
            let metricsPermissions = (try? FileManager.default.attributesOfItem(
                atPath: metricsURL.path
            )[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check(metricsPermissions == 0o600, "request metrics file is owner-only")
            let reopenedMetrics = RequestMetricsStore(fileURL: metricsURL)
            let reloadedMetrics = reopenedMetrics.snapshot()
            check(reloadedMetrics.contains { $0.operation == "ListObjectsV2" && $0.count == 1 },
                  "request metrics persist across store reload")
            check(reloadedMetrics.allSatisfy { $0.sessionCount == 0 },
                  "request metric session counts reset on reload")
            reopenedMetrics.clear()
            check(reopenedMetrics.snapshot().isEmpty, "request metrics can be cleared")
            reopenedMetrics.record(
                account: metricsAccount, bucket: "alpha", operation: "ListObjectsV2",
                outcome: "success", durationMs: 8, bytes: 50
            )
            let logsWindow = LogsWindowController(logStore: logStore, metricsStore: reopenedMetrics)
            logsWindow.reloadForTesting()
            check(logsWindow.testVisibleLogCount > 0,
                  "logs window loads persisted audit records")
            check(logsWindow.testMetricRowCount > 0,
                  "logs window loads request statistics")
            logsWindow.testSetSearch("no-such-record-\(UUID().uuidString)")
            check(logsWindow.testVisibleLogCount == 0,
                  "logs search filters records")
            logsWindow.testSetSearch("test.audit")
            check(logsWindow.testVisibleLogCount > 0,
                  "logs search finds matching records")
            logsWindow.window?.close()

            try? FileManager.default.removeItem(at: logDirectory)
            try? FileManager.default.removeItem(at: metricsURL)
            testDefaults.removePersistentDomain(forName: defaultsName)

        let queueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bm-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let queueSource = queueDir.appendingPathComponent("source.bin")
        try? Data(repeating: 0x41, count: 100).write(to: queueSource)
        let sourceModified = (try? FileManager.default.attributesOfItem(atPath: queueSource.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970
        let queueAccount = Account(
            displayName: "Queue Test",
            accessKeyID: "QUEUEKEY",
            kind: .compatible,
            endpoint: "https://queue.example.test"
        )
        let queueStoreURL = queueDir.appendingPathComponent("transfer-queue.json")
        let queueStore = TransferQueueStore(fileURL: queueStoreURL)
        let validUpload = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "source.bin", localPath: queueSource.path,
            size: 100, bytesDone: 20, status: .paused, error: nil,
            fileModified: sourceModified
        )
        let runningUpload = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "running.bin", localPath: queueSource.path,
            size: 100, bytesDone: 40, status: .running, error: nil
        )
        let queuedDownload = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .download,
            bucket: "alpha", key: "download.bin", localPath: queueDir.appendingPathComponent("download.bin").path,
            size: 200, bytesDone: 0, status: .queued, error: nil
        )
        let missingUpload = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "missing.bin", localPath: queueDir.appendingPathComponent("missing.bin").path,
            size: 50, bytesDone: 10, status: .failed, error: "old failure"
        )
        let pausedMissing = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "paused-missing.bin", localPath: queueDir.appendingPathComponent("paused-missing.bin").path,
            size: 50, bytesDone: 10, status: .paused, error: nil
        )
        let changedSize = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "changed-size.bin", localPath: queueSource.path,
            size: 101, bytesDone: 5, status: .paused, error: nil,
            fileModified: sourceModified
        )
        let sameSizeChanged = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "same-size-changed.bin", localPath: queueSource.path,
            size: 100, bytesDone: 5, status: .paused, error: nil,
            fileModified: sourceModified.map { $0 - 10 }
        )
        let completedTask = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .upload,
            bucket: "alpha", key: "done.bin", localPath: queueSource.path,
            size: 10, bytesDone: 10, status: .completed, error: nil
        )
        queueStore.save([validUpload, runningUpload, queuedDownload, missingUpload, pausedMissing, changedSize, sameSizeChanged, completedTask])
        let queueMode = (try? FileManager.default.attributesOfItem(atPath: queueStoreURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(queueMode == 0o600, "queue state file is owner-only")

        let restoredQueue = TransferQueue(stateStore: TransferQueueStore(fileURL: queueStoreURL), credentialProvider: nil)
        check(restoredQueue.tasks.count == 7, "completed/canceled transfer tasks are not restored")
        if let restoredRunning = restoredQueue.tasks.first(where: { $0.key == "running.bin" }) {
            check(restoredRunning.status == .paused, "running transfer restores paused")
        } else {
            check(false, "running transfer restores paused")
        }
        if let restoredQueued = restoredQueue.tasks.first(where: { $0.key == "download.bin" }) {
            check(restoredQueued.status == .paused, "queued transfer restores paused")
            check(restoredQueued.accountID == queueAccount.id, "restored transfer keeps its account id")
        } else {
            check(false, "queued transfer restores paused")
            check(false, "restored transfer keeps its account id")
        }
        if let restoredFailed = restoredQueue.tasks.first(where: { $0.key == "missing.bin" }) {
            check(restoredFailed.status == .failed, "failed transfer keeps failed state")
            check(restoredFailed.error == "old failure", "failed transfer keeps its error")
        } else {
            check(false, "failed transfer keeps failed state")
            check(false, "failed transfer keeps its error")
        }
        if let restoredUpload = restoredQueue.tasks.first(where: { $0.key == "source.bin" }) {
            check(restoredUpload.bytesDone == 20, "restored upload keeps completed bytes")
            check(restoredUpload.status == .paused, "restored upload is paused")
            check(restoredUpload.id == validUpload.id, "restored upload keeps its task id")
        } else {
            check(false, "restored upload keeps completed bytes")
            check(false, "restored upload is paused")
            check(false, "restored upload keeps its task id")
        }
        if let changed = restoredQueue.tasks.first(where: { $0.key == "changed-size.bin" }) {
            check(changed.status == .failed, "changed upload source is not silently resumed")
            check(changed.error?.contains("changed") == true, "changed upload source explains the failure")
        } else {
            check(false, "changed upload source is not silently resumed")
            check(false, "changed upload source explains the failure")
        }
        if let sameSize = restoredQueue.tasks.first(where: { $0.key == "same-size-changed.bin" }) {
            check(sameSize.status == .failed, "same-size edited upload is rejected by modification time")
        } else {
            check(false, "same-size edited upload is rejected by modification time")
        }
        if let missing = restoredQueue.tasks.first(where: { $0.key == "paused-missing.bin" }) {
            check(missing.status == .failed, "missing upload source is not silently resumed")
            check(missing.error?.isEmpty == false, "missing upload source gets an actionable error")
        } else {
            check(false, "missing upload source is not silently resumed")
            check(false, "missing upload source gets an actionable error")
        }
        restoredQueue.flushPersistence()
        let roundTrip = queueStore.load()
        check(roundTrip.count == 7, "flushed queue omits completed tasks")
        check(!roundTrip.contains { $0.key == "done.bin" }, "completed task is never persisted")
        let queueText = (try? String(contentsOf: queueStoreURL, encoding: .utf8)) ?? ""
        check(!queueText.contains(queueAccount.accessKeyID), "queue state never contains credentials")

        let noProviderURL = queueDir.appendingPathComponent("no-provider.json")
        let noProviderStore = TransferQueueStore(fileURL: noProviderURL)
        noProviderStore.save([validUpload])
        let noProviderQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: noProviderURL),
            credentialProvider: nil
        )
        noProviderQueue.startAll()
        check(noProviderQueue.tasks.first?.status == .failed,
              "restored task without credentials fails safely")
        check(noProviderQueue.tasks.first?.error?.lowercased().contains("credential") == true,
              "restored task without credentials reports the cause")
        check(noProviderQueue.tasks.first?.bytesDone == 20,
              "retry preserves resumable upload progress")
        noProviderQueue.flushPersistence()

        let pumpStoreURL = queueDir.appendingPathComponent("pump-queue.json")
        let pumpStore = TransferQueueStore(fileURL: pumpStoreURL)
        pumpStore.save((0..<6).map { index in
            PersistedTransferTask(
                id: UUID(), accountID: queueAccount.id, direction: .upload,
                bucket: "alpha", key: "pump-\(index).bin", localPath: queueSource.path,
                size: 100, bytesDone: 0, status: .paused, error: nil,
                fileModified: sourceModified
            )
        })
        let pumpQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: pumpStoreURL),
            credentialProvider: nil
        )
        pumpQueue.startAll()
        check(pumpQueue.tasks.allSatisfy { $0.status == .failed },
              "pump keeps draining queued tasks after synchronous start failures")
        check(pumpQueue.tasks.allSatisfy {
            $0.error?.lowercased().contains("credential") == true
        }, "every stranded task reports its start failure")
        pumpQueue.flushPersistence()

        let unreadableURL = queueDir.appendingPathComponent("does-not-exist.bin")
        let unreadableQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: queueDir.appendingPathComponent("unreadable-queue.json")),
            credentialProvider: nil
        )
        unreadableQueue.enqueueUpload(
            account: queueAccount, secret: UUID().uuidString, bucket: "alpha", key: "unreadable.bin", url: unreadableURL
        )
        check(unreadableQueue.tasks.first?.status == .failed,
              "unreadable upload source is rejected at enqueue")
        check(unreadableQueue.tasks.first?.error?.lowercased().contains("readable") == true,
              "unreadable upload source has an actionable error")
        unreadableQueue.flushPersistence()

        let resumeURL = queueDir.appendingPathComponent("resume-queue.json")
        let resumePath = queueDir.appendingPathComponent("resume.bin")
        let resumeTemporary = S3Service.downloadTemporaryURL(for: resumePath)
        try? Data(repeating: 0x44, count: 100).write(to: resumeTemporary)
        let partialDownload = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .download,
            bucket: "alpha", key: "resume.bin",
            localPath: resumePath.path, size: 200, bytesDone: 100,
            status: .paused, error: nil, downloadETag: "\"etag-resume\""
        )
        TransferQueueStore(fileURL: resumeURL).save([partialDownload])
        let resumeQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: resumeURL),
            credentialProvider: nil
        )
        check(resumeQueue.tasks.first?.bytesDone == 100,
              "partial download progress is restored")
        check(resumeQueue.tasks.first?.downloadETag == "\"etag-resume\"",
              "download ETag is restored for range validation")
        check(resumeQueue.tasks.first?.status == .paused,
              "partial download restores paused")
        try? Data("keep destination".utf8).write(to: resumePath)
        if let resumeTask = resumeQueue.tasks.first {
            resumeQueue.cancel(id: resumeTask.id)
        }
        check(!FileManager.default.fileExists(atPath: resumeTemporary.path),
              "canceling a partial download removes its temporary file")
        check(FileManager.default.fileExists(atPath: resumePath.path),
              "canceling a partial download preserves the destination")
        resumeQueue.flushPersistence()

        let cancelPath = queueDir.appendingPathComponent("pre-existing-download.bin")
        try? Data("keep me".utf8).write(to: cancelPath)
        let cancelURL = queueDir.appendingPathComponent("cancel-download-queue.json")
        let cancelStore = TransferQueueStore(fileURL: cancelURL)
        cancelStore.save([
            PersistedTransferTask(
                id: UUID(), accountID: queueAccount.id, direction: .download,
                bucket: "alpha", key: "download.bin", localPath: cancelPath.path,
                size: 20, bytesDone: 0, status: .queued, error: nil
            )
        ])
        let cancelQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: cancelURL),
            credentialProvider: nil
        )
        if let cancelTask = cancelQueue.tasks.first {
            cancelQueue.cancel(id: cancelTask.id)
        }
        check(FileManager.default.fileExists(atPath: cancelPath.path),
              "canceling a queued download preserves an existing destination")
        cancelQueue.flushPersistence()

        let copyTemp = queueDir.appendingPathComponent(
            "BucketManager-Copy-\(UUID().uuidString).tmp"
        )
        try? Data("copy".utf8).write(to: copyTemp)
        let copyDestinationAccount = UUID()
        let copyRecord = PersistedTransferTask(
            id: UUID(), accountID: queueAccount.id, direction: .copy,
            bucket: "alpha", key: "source/copy.txt", localPath: copyTemp.path,
            size: 10, bytesDone: 4, status: .paused, error: nil,
            destinationAccountID: copyDestinationAccount,
            destinationBucket: "archive", destinationKey: "incoming/copy.txt",
            moveSource: true, sourceETag: "\"etag-copy\"",
            destinationUploadID: "upload-copy"
        )
        let copyURL = queueDir.appendingPathComponent("copy-queue.json")
        TransferQueueStore(fileURL: copyURL).save([copyRecord])
        let copyQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: copyURL),
            credentialProvider: nil
        )
        if let restoredCopy = copyQueue.tasks.first {
            check(restoredCopy.direction == .copy, "copy transfer restores its direction")
            check(restoredCopy.status == .paused, "copy transfer restores paused")
            check(restoredCopy.destinationAccountID == copyDestinationAccount,
                  "copy transfer keeps destination account")
            check(restoredCopy.destinationBucket == "archive",
                  "copy transfer keeps destination bucket")
            check(restoredCopy.destinationKey == "incoming/copy.txt",
                  "copy transfer keeps destination key")
            check(restoredCopy.moveSource, "copy transfer keeps move intent")
            check(restoredCopy.destinationUploadID == "upload-copy",
                  "copy transfer keeps destination upload id")
            check(restoredCopy.bytesDone == 0, "copy transfer restarts from zero")
            check(!FileManager.default.fileExists(atPath: copyTemp.path),
                  "copy restore discards its temporary file")
            check(restoredCopy.title.contains("Moving"), "copy transfer title reflects move intent")
        } else {
            check(false, "copy transfer restores its direction")
        }
        copyQueue.flushPersistence()

        let unsafeCopyPath = queueDir.appendingPathComponent("keep-me.txt")
        try? Data("keep".utf8).write(to: unsafeCopyPath)
        let unsafeCopyURL = queueDir.appendingPathComponent("unsafe-copy-queue.json")
        TransferQueueStore(fileURL: unsafeCopyURL).save([
            PersistedTransferTask(
                id: UUID(), accountID: queueAccount.id, direction: .copy,
                bucket: "alpha", key: "source.txt", localPath: unsafeCopyPath.path,
                size: 4, bytesDone: 0, status: .paused, error: nil,
                destinationAccountID: copyDestinationAccount,
                destinationBucket: "archive", destinationKey: "source.txt"
            )
        ])
        let unsafeCopyQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: unsafeCopyURL),
            credentialProvider: nil
        )
        check(FileManager.default.fileExists(atPath: unsafeCopyPath.path),
              "restored copy never deletes an unsafe path")
        check(unsafeCopyQueue.tasks.first?.status == .failed,
              "unsafe restored copy fails safely")
        check(unsafeCopyQueue.tasks.first?.error?.lowercased().contains("invalid") == true,
              "unsafe restored copy reports its invalid path")

        let corruptURL = queueDir.appendingPathComponent("corrupt-queue.json")
        try? Data("not-json".utf8).write(to: corruptURL)
        check(TransferQueueStore(fileURL: corruptURL).load().isEmpty, "corrupt queue state fails safely")

        let mixedURL = queueDir.appendingPathComponent("mixed-queue.json")
        let validData = (try? JSONEncoder().encode([validUpload])) ?? Data()
        var mixedArray = ((try? JSONSerialization.jsonObject(with: validData)) as? [Any]) ?? []
        mixedArray.append(["id": UUID().uuidString, "status": "Bogus"])
        try? JSONSerialization.data(withJSONObject: mixedArray).write(to: mixedURL)
        check(TransferQueueStore(fileURL: mixedURL).load().count == 1,
              "one invalid queue record does not discard valid records")
        check(FileManager.default.fileExists(atPath: mixedURL.path),
              "partially invalid queue state is preserved")
        check(FileManager.default.fileExists(atPath: mixedURL.appendingPathExtension("corrupt").path),
              "partially invalid queue state is backed up")

        let emptyQueue = TransferQueue(
            stateStore: TransferQueueStore(fileURL: queueDir.appendingPathComponent("empty.json")),
            credentialProvider: nil
        )
        check(emptyQueue.tasks.isEmpty, "missing queue state starts empty")
        try? FileManager.default.removeItem(at: queueDir)

        let maintenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BucketManager-maintenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: maintenanceDir, withIntermediateDirectories: true)
        let orphanTemp = maintenanceDir.appendingPathComponent("orphan.bmdownload")
        let activeTemp = maintenanceDir.appendingPathComponent("active.bmdownload")
        let orphanCopyTemp = maintenanceDir.appendingPathComponent(
            "BucketManager-Copy-\(UUID().uuidString).tmp"
        )
        let unrelatedFile = maintenanceDir.appendingPathComponent("keep.txt")
        try? Data("orphan".utf8).write(to: orphanTemp)
        try? Data("active".utf8).write(to: activeTemp)
        try? Data("copy".utf8).write(to: orphanCopyTemp)
        try? Data("keep".utf8).write(to: unrelatedFile)
        let registryURL = maintenanceDir.appendingPathComponent("download-temps.json")
        let registry = DownloadTempRegistry(fileURL: registryURL)
        registry.register(orphanTemp)
        registry.register(activeTemp)
        registry.register(orphanCopyTemp)
        registry.register(unrelatedFile)
        registry.cleanup(active: [activeTemp.path])
        check(!FileManager.default.fileExists(atPath: orphanTemp.path),
              "orphan download temp file is removed")
        check(!FileManager.default.fileExists(atPath: orphanCopyTemp.path),
              "orphan copy temp file is removed")
        check(FileManager.default.fileExists(atPath: activeTemp.path),
              "active download temp file is preserved")
        check(FileManager.default.fileExists(atPath: unrelatedFile.path),
              "cleanup never removes a non-download file")
        check(DownloadTempRegistry(fileURL: registryURL).registered().map(\.path) == [activeTemp.path],
              "active download temp remains registered")
        let registryAttributes = try? FileManager.default.attributesOfItem(atPath: registryURL.path)
        let registryMode = (registryAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(registryMode == 0o600, "download temp registry is owner-only")

        let staleStateDir = maintenanceDir.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: staleStateDir, withIntermediateDirectories: true)
        let staleTemp = staleStateDir.appendingPathComponent(".transfer-queue-old.tmp")
        try? Data("stale".utf8).write(to: staleTemp)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: staleTemp.path
        )
        _ = TransferQueueStore(fileURL: staleStateDir.appendingPathComponent("transfer-queue.json"))
        check(!FileManager.default.fileExists(atPath: staleTemp.path),
              "stale queue atomic-write temporary file is removed")

        let now = Date()
        let activeUploadAccount = UUID()
        let activeUploadTask = {
            var task = TransferTask(
                direction: .upload, bucket: "alpha", key: "active.bin",
                localURL: maintenanceDir.appendingPathComponent("active.bin"), size: 100
            )
            task.accountID = activeUploadAccount
            task.status = .paused
            return task
        }()
        let activeRecord = MultipartUploadRecord(
            accountID: activeUploadAccount, bucket: "alpha", key: "active.bin",
            uploadID: "active-upload", fileSize: 100, fileModified: nil,
            partSize: 8, parts: [], createdAt: now.addingTimeInterval(-600),
            updatedAt: now
        )
        let orphanRecord = MultipartUploadRecord(
            accountID: UUID(), bucket: "alpha", key: "orphan.bin",
            uploadID: "orphan-upload", fileSize: 100, fileModified: nil,
            partSize: 8, parts: [], createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600)
        )
        var pausedCopy = TransferTask(
            direction: .copy, bucket: "source.bin", key: "source.bin",
            localURL: maintenanceDir.appendingPathComponent("copy.bin"), size: 100
        )
        pausedCopy.destinationAccountID = activeUploadAccount
        pausedCopy.destinationBucket = "alpha"
        pausedCopy.destinationKey = "copy.bin"
        pausedCopy.status = .paused
        let orphanCopyRecord = MultipartUploadRecord(
            accountID: activeUploadAccount, bucket: "alpha", key: "copy.bin",
            uploadID: "copy-upload", fileSize: 100, fileModified: nil,
            partSize: 8, parts: [], createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600)
        )
        let planned = MultipartOrphanPlanner.orphans(
            records: [activeRecord, orphanRecord, orphanCopyRecord],
            activeUploads: [activeUploadTask, pausedCopy],
            now: now,
            grace: 60
        )
        check(planned.contains { $0.uploadID == "orphan-upload" },
              "multipart orphan planner keeps active uploads")
        check(planned.contains { $0.key == "orphan.bin" },
              "multipart orphan planner finds stale upload state")
        check(planned.contains { $0.uploadID == "copy-upload" },
              "multipart orphan planner reclaims paused copy uploads")
        try? FileManager.default.removeItem(at: maintenanceDir)

        print("UITEST SUMMARY passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
