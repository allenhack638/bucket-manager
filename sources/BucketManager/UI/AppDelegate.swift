import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accounts = AccountStore()
    lazy var model = BrowserModel(accounts: accounts)
    private var mainWindow: MainWindowController!
    private var appearanceMode: AppAppearance = .system
    private var appearanceMenuItems: [AppAppearance: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceMode = .saved
        NSApp.appearance = appearanceMode.appearance
        AppLog.shared.log("Launched Bucket Manager; \(accounts.accounts.count) saved account(s); logDir=\(AppLog.path)")
        LogStore.shared.audit(
            event: "app.launched",
            message: "Bucket Manager launched",
            outcome: "success",
            metadata: ["accounts": String(accounts.accounts.count)]
        )
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        mainWindow = MainWindowController(accounts: accounts, model: model)
        buildMainMenu()
        mainWindow.show()
        Task {
            await TransferMaintenance.cleanOrphans(queue: model.transfers, accounts: accounts)
        }

        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            model.loadDemoData()
            AppLog.shared.log("Demo data loaded for UI automation")
        }
        #endif

        if accounts.accounts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.mainWindow.presentAddAccount()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushTransfers()
        model.flushFolderStats()
        LogStore.shared.flush()
        RequestMetricsStore.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Bucket Manager")
        let about = NSMenuItem(title: "About Bucket Manager", action: #selector(MainWindowController.aboutAction), keyEquivalent: "")
        about.target = mainWindow
        appMenu.addItem(about)
        let options = NSMenuItem(title: "Options…", action: #selector(MainWindowController.showOptionsAction), keyEquivalent: ",")
        options.target = mainWindow
        appMenu.addItem(options)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Bucket Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Bucket Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let refresh = NSMenuItem(title: "Refresh", action: #selector(MainWindowController.refreshAction), keyEquivalent: "r")
        refresh.target = mainWindow
        viewMenu.addItem(refresh)
        let logs = NSMenuItem(title: "Logs & Statistics…", action: #selector(MainWindowController.showLogsAction), keyEquivalent: "l")
        logs.keyEquivalentModifierMask = [.command, .option]
        logs.target = mainWindow
        viewMenu.addItem(logs)
        let eventLog = NSMenuItem(title: "Show Event Log", action: #selector(MainWindowController.showEventLogAction), keyEquivalent: "l")
        eventLog.keyEquivalentModifierMask = [.command, .shift]
        eventLog.target = mainWindow
        viewMenu.addItem(eventLog)

        viewMenu.addItem(.separator())
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for mode in AppAppearance.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == appearanceMode ? .on : .off
            appearanceMenu.addItem(item)
            appearanceMenuItems[mode] = item
        }
        appearanceItem.submenu = appearanceMenu
        viewMenu.addItem(appearanceItem)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(MainWindowController.shortcutsAction), keyEquivalent: "")
        shortcuts.target = mainWindow
        helpMenu.addItem(shortcuts)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppAppearance(rawValue: raw) else { return }
        appearanceMode = mode
        AppAppearance.apply(mode)
        for (itemMode, item) in appearanceMenuItems {
            item.state = itemMode == mode ? .on : .off
        }
        mainWindow.window?.contentView?.needsDisplay = true
    }
}
