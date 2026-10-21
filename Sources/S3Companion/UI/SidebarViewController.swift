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
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
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
    private let toolbar = NSView()
    private let emptyView: EmptyStateView
    private var externalButton: FlatButton?
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
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.Colors.sidebar.cgColor

        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = Theme.Colors.sidebar.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let addBucket = FlatButton("New bucket", icon: "plus", style: .action) { [weak self] in self?.newBucket() }
        addBucket.iconTint = NSColor(hex: 0x0F7B0F)
        let external = FlatButton("Add external bucket", icon: "plus", style: .action) { [weak self] in self?.onAddAccount?() }
        externalButton = external
        let refresh = FlatButton("", icon: "arrow.clockwise", style: .action) { [weak self] in self?.refreshBuckets() }
        refresh.toolTip = "Refresh buckets list (F5)"
        refresh.accessibilityTitle = "Refresh buckets list"
        for button in [addBucket, external, refresh] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            toolbar.addSubview(button)
        }
        if let refreshButton = toolbar.subviews.last {
            refreshButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }

        NSLayoutConstraint.activate([
            addBucket.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            addBucket.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            external.leadingAnchor.constraint(equalTo: addBucket.trailingAnchor, constant: 2),
            external.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            refresh.leadingAnchor.constraint(equalTo: external.trailingAnchor, constant: 2),
            refresh.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.width = 360
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setAccessibilityLabel("Accounts and buckets")
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
        outline.doubleAction = #selector(doubleClicked)
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

    override func viewDidLayout() {
        super.viewDidLayout()
        externalButton?.isHidden = view.bounds.width < 340
    }

    func updateEmptyState() {
        let empty = !model.hasAccounts
        emptyView.isHidden = !empty
        scroll.isHidden = empty
    }

    func reload() {
        let selectedID = (outline.item(atRow: outline.selectedRow) as? BrowserNode)?.id
        let expandedIDs = expandedNodeIDs()

        isReloading = true
        outline.reloadData()

        for root in model.roots { expandLoaded(root, expandedIDs: expandedIDs) }

        if let selectedID, let node = findNode(id: selectedID) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        isReloading = false
        updateEmptyState()
        outline.needsDisplay = true
    }

    func selectAccount(withID accountID: UUID) {
        guard let node = model.roots.first(where: { $0.accountID == accountID }) else { return }
        let row = outline.row(forItem: node)
        if row >= 0 {
            isReloading = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isReloading = false
            outline.expandItem(node)
        }
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
            await model.refresh()
        }
    }

    @objc func deleteBucketAction() {
        guard let bucket = clickedBucketName() ?? model.selectedBucket,
              let account = model.selectedAccount else { return }
        let alert = NSAlert()
        alert.messageText = "Delete bucket \(bucket)?"
        alert.informativeText = "The bucket must be empty before S3 will delete it. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await model.deleteBucket(bucket)
            _ = account
        }
    }

    @objc func removeAccountAction() {
        guard let row = clickedOrSelectedRow(), row >= 0,
              let node = outline.item(atRow: row) as? BrowserNode,
              node.kind == .account,
              let id = node.accountID,
              let account = model.accounts.account(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove account \(account.displayName)?"
        alert.informativeText = "The account metadata and its secret in the macOS Keychain will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.accounts.remove(account)
        model.invalidateFolderStats(accountID: account.id)
        model.reloadAccounts()
    }

    @objc private func refreshCurrent() {
        Task {
            await model.refreshBuckets()
            await model.refresh()
        }
    }

    @objc func openSelected() {
        guard outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? BrowserNode else { return }
        switch node.kind {
        case .account, .bucket:
            outline.expandItem(node)
        case .folder:
            open(node)
        }
    }

    @objc func newFolderAction() {
        guard let row = clickedOrSelectedRow(),
              let node = outline.item(atRow: row) as? BrowserNode,
              let bucket = node.bucket else { return }
        let prefix = node.kind == .folder ? (node.prefix ?? "") : ""
        open(node, bucket: bucket, prefix: prefix)
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Create new folder"
        alert.informativeText = "Enter a name for the folder in /\(bucket)/\(prefix)"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "New folder"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            Task { await self.model.createFolder(named: name) }
        }
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? BrowserNode else { return }
        switch node.kind {
        case .account, .bucket:
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        case .folder:
            open(node)
        }
    }

    // MARK: - Helpers

    private func open(_ node: BrowserNode, bucket: String? = nil, prefix: String? = nil) {
        guard let accountID = node.accountID ?? model.selectedAccount?.id,
              let targetBucket = bucket ?? node.bucket else { return }
        model.openLocation(
            accountID: accountID,
            bucket: targetBucket,
            prefix: prefix ?? node.prefix ?? ""
        )
    }

    private func expandedNodeIDs() -> Set<String> {
        var ids: Set<String> = []
        func visit(_ node: BrowserNode) {
            if outline.isItemExpanded(node) { ids.insert(node.id) }
            node.children.forEach(visit)
        }
        model.roots.forEach(visit)
        return ids
    }

    private func expandLoaded(_ node: BrowserNode, expandedIDs: Set<String>) {
        if node.kind == .account && node.didLoad { outline.expandItem(node) }
        if expandedIDs.contains(node.id), node.didLoad {
            outline.expandItem(node)
        }
        node.children.forEach { expandLoaded($0, expandedIDs: expandedIDs) }
    }

    private func findNode(id: String) -> BrowserNode? {
        func visit(_ node: BrowserNode) -> BrowserNode? {
            if node.id == id { return node }
            for child in node.children {
                if let found = visit(child) { return found }
            }
            return nil
        }
        for root in model.roots {
            if let found = visit(root) { return found }
        }
        return nil
    }

    private func clickedOrSelectedRow() -> Int? {
        outline.clickedRow >= 0 ? outline.clickedRow : (outline.selectedRow >= 0 ? outline.selectedRow : nil)
    }

    private func clickedBucketName() -> String? {
        guard let row = clickedOrSelectedRow(), let node = outline.item(atRow: row) as? BrowserNode else { return nil }
        return node.bucket
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
        menu.addItem(withTitle: "New Folder…", action: #selector(newFolderAction), keyEquivalent: "")
        menu.addItem(withTitle: "New Bucket…", action: #selector(newBucket), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Bucket…", action: #selector(deleteBucketAction), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh", action: #selector(refreshCurrent), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add New Account…", action: #selector(addAccount), keyEquivalent: "")
        menu.addItem(withTitle: "Manage Accounts…", action: #selector(manageAccounts), keyEquivalent: "")
        menu.addItem(withTitle: "Remove Account…", action: #selector(removeAccountAction), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? BrowserNode else { return model.roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? BrowserNode else { return model.roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? BrowserNode else { return false }
        switch node.kind {
        case .account, .bucket: return true
        case .folder: return !node.children.isEmpty || !node.didLoad
        }
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
        guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? BrowserNode else { return }

        switch node.kind {
        case .account:
            guard let id = node.accountID, let account = model.accounts.account(id: id) else { return }
            model.selectAccount(account)
            outline.expandItem(node)
        case .bucket:
            open(node)
            outline.expandItem(node)
        case .folder:
            open(node)
        }

        refreshRowColors()
    }

    private func refreshRowColors() {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? BrowserNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCellView else { continue }
            cell.configure(node: node, selected: outline.selectedRowIndexes.contains(row))
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        if !node.didLoad {
            Task { await model.loadChildren(of: node) }
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {}
}

extension SidebarViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = row >= 0 ? outline.item(atRow: row) as? BrowserNode : nil else {
            return menuItem.action == #selector(addAccount)
                || menuItem.action == #selector(manageAccounts)
                || menuItem.action == #selector(newBucket)
        }
        switch menuItem.action {
        case #selector(deleteBucketAction), #selector(newFolderAction):
            return node.bucket != nil
        case #selector(removeAccountAction):
            return node.kind == .account
        default:
            return true
        }
    }
}
