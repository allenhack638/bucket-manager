import AppKit

final class TreeCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Font.body
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.Icon.row.size),
            icon.heightAnchor.constraint(equalToConstant: Theme.Icon.row.size),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(node: BrowserNode, selected: Bool) {
        label.stringValue = node.title
        label.font = node.kind == .account ? Theme.Font.bodyBold : Theme.Font.body
        icon.image = node.icon
        let tint: NSColor
        switch node.kind {
        case .account: tint = Theme.Colors.accent
        case .bucket: tint = NSColor(hex: 0xD18B00)
        case .folder: tint = NSColor(hex: 0xE0A800)
        }
        label.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
        icon.contentTintColor = selected ? Theme.Colors.selectionText : tint
    }
}

@MainActor
final class SidebarViewController: NSViewController {
    private let model: BrowserModel
    var onAddAccount: (() -> Void)?
    var onManageAccounts: (() -> Void)?
    var onError: ((String, String) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let toolbar = ThemedView()
    private let emptyView: EmptyStateView
    private let accountPopup = NSPopUpButton()
    private var bucketNodes: [BrowserNode] = []
    private var isReloading = false

    init(model: BrowserModel) {
        self.model = model
        let empty = EmptyStateView(
            iconName: "cloud.fill",
            title: "No storage accounts yet",
            subtitle: "Add an S3 account to start browsing buckets.",
            actionTitle: "Add new account"
        )
        self.emptyView = empty
        super.init(nibName: nil, bundle: nil)
        empty.action = { [weak self] in self?.onAddAccount?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedView()
        root.themeColor = Theme.Colors.sidebar

        toolbar.themeColor = Theme.Colors.sidebar
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        accountPopup.controlSize = .small
        accountPopup.font = Theme.Font.body
        accountPopup.translatesAutoresizingMaskIntoConstraints = false
        accountPopup.setAccessibilityLabel("Active account")
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged)
        toolbar.addSubview(accountPopup)

        let addBucket = FlatButton("New bucket", icon: "plus", style: .action) { [weak self] in self?.newBucket() }
        addBucket.iconTint = NSColor(hex: 0x0F7B0F)
        addBucket.toolTip = "Create a bucket in the active account"
        let refresh = FlatButton("", icon: "arrow.clockwise", style: .action) { [weak self] in self?.refreshBuckets() }
        refresh.toolTip = "Refresh buckets list (F5)"
        refresh.accessibilityTitle = "Refresh buckets list"
        for button in [addBucket, refresh] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            toolbar.addSubview(button)
        }
        refresh.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let popupWidth = accountPopup.widthAnchor.constraint(equalToConstant: 130)
        popupWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            accountPopup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            accountPopup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            popupWidth,
            accountPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            accountPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 170),

            addBucket.leadingAnchor.constraint(equalTo: accountPopup.trailingAnchor, constant: 4),
            addBucket.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            refresh.leadingAnchor.constraint(equalTo: addBucket.trailingAnchor, constant: 2),
            refresh.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.width = 360
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setAccessibilityLabel("Buckets")
        outline.headerView = nil
        outline.backgroundColor = Theme.Colors.sidebar
        outline.rowHeight = Theme.Metrics.treeRowHeight
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = Theme.Metrics.treeIndent
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.focusRingType = .none
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.menu = contextMenu()

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.sidebar
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(scroll)
        root.addSubview(emptyView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            emptyView.heightAnchor.constraint(equalToConstant: 200)
        ])

        self.view = root
        updateEmptyState()
    }

    func updateEmptyState() {
        if !model.hasAccounts {
            emptyView.action = { [weak self] in self?.onAddAccount?() }
            emptyView.update(
                iconName: "cloud.fill",
                title: "No storage accounts yet",
                subtitle: "Add an S3 account to start browsing buckets."
            )
            emptyView.setActionVisible(true, title: "Add new account")
            emptyView.isHidden = false
            scroll.isHidden = true
            return
        }

        if model.buckets.isEmpty {
            emptyView.isHidden = false
            scroll.isHidden = true
            if model.isBusy {
                emptyView.action = nil
                emptyView.update(
                    iconName: "hourglass",
                    title: "Loading buckets…",
                    subtitle: "Fetching buckets for \(model.selectedAccount?.displayName ?? "this account")."
                )
                emptyView.setActionVisible(false)
            } else if let error = model.errorMessage {
                emptyView.action = { [weak self] in self?.refreshBuckets() }
                emptyView.update(
                    iconName: "exclamationmark.triangle",
                    title: "Couldn't load buckets",
                    subtitle: error.split(separator: "\n").first.map(String.init) ?? error
                )
                emptyView.setActionVisible(true, title: "Retry")
            } else {
                emptyView.action = { [weak self] in self?.newBucket() }
                emptyView.update(
                    iconName: "shippingbox",
                    title: "No buckets",
                    subtitle: "Create a bucket in this account to get started."
                )
                emptyView.setActionVisible(true, title: "New bucket")
            }
            return
        }

        emptyView.isHidden = true
        scroll.isHidden = false
    }

    func reload() {
        bucketNodes = model.buckets.map {
            BrowserNode(
                kind: .bucket,
                title: $0.name,
                accountID: model.selectedAccount?.id,
                bucket: $0.name
            )
        }
        updateAccountPopup()

        isReloading = true
        outline.reloadData()

        if let selectedBucket = model.selectedBucket,
           let index = bucketNodes.firstIndex(where: { $0.bucket == selectedBucket }) {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        isReloading = false
        updateEmptyState()
        outline.needsDisplay = true
    }

    private func updateAccountPopup() {
        let accounts = model.accounts.accounts
        accountPopup.removeAllItems()
        for account in accounts {
            accountPopup.addItem(withTitle: account.displayName)
            accountPopup.lastItem?.representedObject = account.id.uuidString
        }
        accountPopup.isEnabled = !accounts.isEmpty
        if let id = model.selectedAccount?.id,
           let index = accounts.firstIndex(where: { $0.id == id }) {
            accountPopup.selectItem(at: index)
        } else if !accounts.isEmpty {
            accountPopup.selectItem(at: 0)
        }
    }

    @objc private func accountChanged() {
        guard let raw = accountPopup.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: raw),
              let account = model.accounts.account(id: id) else { return }
        model.selectAccount(account)
    }

    // MARK: - Actions

    @objc func addAccount() { onAddAccount?() }
    @objc func manageAccounts() { onManageAccounts?() }

    @objc func newBucket() {
        guard let account = model.selectedAccount else {
            onAddAccount?()
            return
        }
        prompt(title: "New bucket",
               message: "Create a bucket in \(account.displayName).",
               placeholder: "bucket-name",
               actionTitle: "Create") { [weak self] name in
            guard let self else { return }
            Task { await self.model.createBucket(named: name) }
        }
    }

    @objc func refreshBuckets() {
        Task {
            await model.refreshBuckets()
            if model.selectedBucket != nil {
                await model.refresh()
            }
        }
    }

    @objc func deleteBucketAction() {
        guard let bucket = model.selectedBucket else { return }
        let alert = NSAlert()
        alert.messageText = "Delete bucket \(bucket)?"
        alert.informativeText = "The bucket must be empty before S3 will delete it. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.deleteBucket(bucket) }
    }

    @objc private func refreshCurrent() {
        refreshBuckets()
    }

    private func prompt(
        title: String,
        message: String,
        placeholder: String,
        actionTitle: String,
        completion: @escaping (String) -> Void
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            completion(value)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Bucket…", action: #selector(deleteBucketAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Bucket…", action: #selector(newBucket), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh Buckets", action: #selector(refreshCurrent), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add New Account…", action: #selector(addAccount), keyEquivalent: "")
        menu.addItem(withTitle: "Manage Accounts…", action: #selector(manageAccounts), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func openSelected() {
        guard outline.selectedRow >= 0, outline.selectedRow < bucketNodes.count else { return }
        model.selectBucket(bucketNodes[outline.selectedRow].bucket ?? "")
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? bucketNodes.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        bucketNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BrowserNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("treecell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? TreeCellView) ?? {
            let view = TreeCellView()
            view.identifier = identifier
            return view
        }()
        let selected = outlineView.selectedRowIndexes.contains(outlineView.row(forItem: item))
        cell.configure(node: node, selected: selected)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        DataRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        guard outline.selectedRow >= 0,
              outline.selectedRow < bucketNodes.count,
              let bucket = bucketNodes[outline.selectedRow].bucket,
              bucket != model.selectedBucket else { return }
        model.selectBucket(bucket)
        refreshRowColors()
    }

    private func refreshRowColors() {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? BrowserNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCellView else { continue }
            cell.configure(node: node, selected: outline.selectedRowIndexes.contains(row))
        }
    }

}

extension SidebarViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(deleteBucketAction):
            return model.selectedBucket != nil
        case #selector(newBucket), #selector(refreshCurrent), #selector(refreshBuckets):
            return model.selectedAccount != nil
        default:
            return true
        }
    }
}
