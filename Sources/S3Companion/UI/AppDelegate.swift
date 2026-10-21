import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accounts = AccountStore()
    lazy var model = BrowserModel(accounts: accounts)
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        AppLog.shared.log("Launched S3 Companion; \(accounts.accounts.count) saved account(s); log=\(AppLog.path)")
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        mainWindow = MainWindowController(accounts: accounts, model: model)
        buildMainMenu()
        mainWindow.show()

        if CommandLine.arguments.contains("--demo") {
            model.loadDemoData()
            AppLog.shared.log("Demo data loaded for UI automation")
        }

        if accounts.accounts.isEmpty && !CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.mainWindow.presentAddAccount()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "S3 Browser for Mac")
        let about = NSMenuItem(title: "About S3 Browser for Mac", action: #selector(MainWindowController.aboutAction), keyEquivalent: "")
        about.target = mainWindow
        appMenu.addItem(about)
        let options = NSMenuItem(title: "Options…", action: #selector(MainWindowController.showOptionsAction), keyEquivalent: ",")
        options.target = mainWindow
        appMenu.addItem(options)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide S3 Browser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit S3 Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let eventLog = NSMenuItem(title: "Show Event Log", action: #selector(MainWindowController.showEventLogAction), keyEquivalent: "l")
        eventLog.keyEquivalentModifierMask = [.command, .shift]
        eventLog.target = mainWindow
        viewMenu.addItem(eventLog)
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
        let online = NSMenuItem(title: "S3 Browser Online Help", action: #selector(MainWindowController.openOnlineHelp), keyEquivalent: "?")
        online.target = mainWindow
        helpMenu.addItem(online)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
