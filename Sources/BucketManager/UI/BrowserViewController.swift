import AppKit

final class FileCellView: NSTableCellView {
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.Icon.row.size),
            icon.heightAnchor.constraint(equalToConstant: Theme.Icon.row.size),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: S3Item, selected: Bool) {
        label.stringValue = item.displayName
        icon.image = item.icon
        icon.contentTintColor = selected ? Theme.Colors.selectionText : item.iconTint
        label.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
    }

}

final class BrowserTableView: HoverTrackingTableView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class BrowserViewController: NSViewController {
    private let model: BrowserModel
    var onShowInspector: ((String) -> Void)?
    var onBookmark: (() -> Void)?

    private let pathBar = ThemedView()
    private let breadcrumb = BreadcrumbView()
    private let header = ColumnHeaderView()
    private let table = BrowserTableView()
    private let scroll = NSScrollView()
    private let actionBar = ThemedView()
    private let statusBar = ThemedView()
    private let statusLabel = Labels.label("Ready", font: Theme.Font.small, color: Theme.Colors.secondaryText)
    private let countLabel = Labels.label("", font: Theme.Font.small, color: Theme.Colors.secondaryText)
    private let loadMoreButton = FlatButton("Load more…", style: .link)
    private let spinner = NSProgressIndicator()
    private let emptyView: EmptyStateView
    private var objectActionButtons: [FlatButton] = []
    private var openButton: FlatButton?
    private var refreshButton: FlatButton?
    private var bookmarkButton: FlatButton?
    private var renameButton: FlatButton?
    private var filterButton: FlatButton?
    private let filterField = NSSearchField()
    private var filterWidthConstraint: NSLayoutConstraint!
    private var columnWidths: [String: CGFloat] = [:]

    private static let columnWidthsKey = "BucketManagerColumnWidths"

    private let checkWidth: CGFloat = 24
    private let sizeWidth: CGFloat = 90
    private let typeWidth: CGFloat = 135
    private let modifiedWidth: CGFloat = 168
    private let storageWidth: CGFloat = 130

    init(model: BrowserModel) {
        self.model = model
        if !model.isDemoData,
           let saved = UserDefaults.standard.dictionary(forKey: Self.columnWidthsKey) as? [String: Double] {
            columnWidths = saved.mapValues { CGFloat($0) }
        }
        let empty = EmptyStateView(
            iconName: "shippingbox",
            title: "Select a bucket",
            subtitle: "Choose a bucket in the sidebar to browse its objects.",
            actionTitle: "Upload files",
            action: nil
        )
        self.emptyView = empty
        super.init(nibName: nil, bundle: nil)
        empty.action = { [weak self] in self?.uploadFiles() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedView()
        root.themeColor = Theme.Colors.content

        buildPathBar()
        buildTable()
        buildActionBar()
        buildStatusBar()

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathBar)
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(statusBar)
        root.addSubview(actionBar)
        root.addSubview(emptyView)


        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.pathBarHeight),

            header.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Metrics.headerHeight),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.statusBarHeight),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: Theme.Metrics.actionBarHeight),

            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
            emptyView.heightAnchor.constraint(lessThanOrEqualTo: scroll.heightAnchor, constant: -8),
            emptyView.topAnchor.constraint(greaterThanOrEqualTo: scroll.topAnchor, constant: 4),
            emptyView.bottomAnchor.constraint(lessThanOrEqualTo: scroll.bottomAnchor, constant: -4)
        ])

        let preferredWidth = emptyView.widthAnchor.constraint(equalToConstant: 420)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = emptyView.heightAnchor.constraint(equalToConstant: 190)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([preferredWidth, preferredHeight])

        self.view = root
        updateChrome()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateColumnWidths()
        DispatchQueue.main.async { [weak self] in self?.updateColumnWidths() }
    }

    // MARK: - Build

    private func buildPathBar() {
        pathBar.identifier = NSUserInterfaceItemIdentifier("pathBar")
        pathBar.themeColor = Theme.Colors.content

        breadcrumb.onNavigate = { [weak self] prefix in
            Task { await self?.model.navigate(toPrefix: prefix) }
        }
        breadcrumb.translatesAutoresizingMaskIntoConstraints = false

        let bottomLine = SeparatorView(axis: .horizontal)
        bottomLine.translatesAutoresizingMaskIntoConstraints = false

        let star = FlatButton("", icon: "star", style: .action) { [weak self] in self?.onBookmark?() }
        let edit = FlatButton("", icon: "pencil", style: .action) { [weak self] in self?.renameSelected() }
        bookmarkButton = star
        renameButton = edit
        let filter = FlatButton("", icon: "line.3.horizontal.decrease", style: .action) { [weak self] in
            self?.toggleFilter()
        }
        filterButton = filter
        let refresh = FlatButton("", icon: "arrow.clockwise", style: .action) { [weak self] in self?.refresh() }
        star.toolTip = "Bookmark this location"
        edit.toolTip = "Rename selected object"
        filter.toolTip = "Filter objects (⌘F)"
        refresh.toolTip = "Refresh"
        star.accessibilityTitle = "Bookmark this location"
        edit.accessibilityTitle = "Rename selected object"
        filter.accessibilityTitle = "Filter objects"
        refresh.accessibilityTitle = "Refresh"

        filterField.placeholderString = "Filter objects"
        filterField.controlSize = .small
        filterField.font = Theme.Font.small
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.isHidden = true
        filterField.setAccessibilityLabel("Filter objects")
        filterField.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView(views: [star, edit, filter, refresh])
        tools.identifier = NSUserInterfaceItemIdentifier("pathTools")
        tools.orientation = .horizontal
        tools.spacing = 0
        tools.alignment = .centerY
        tools.setContentHuggingPriority(.required, for: .horizontal)
        tools.setContentCompressionResistancePriority(.required, for: .horizontal)
        tools.translatesAutoresizingMaskIntoConstraints = false
        for button in [star, edit, filter, refresh] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        pathBar.addSubview(breadcrumb)
        pathBar.addSubview(filterField)
        pathBar.addSubview(tools)
        pathBar.addSubview(bottomLine)

        filterWidthConstraint = filterField.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 10),
            breadcrumb.trailingAnchor.constraint(equalTo: filterField.leadingAnchor, constant: -8),
            breadcrumb.topAnchor.constraint(equalTo: pathBar.topAnchor),
            breadcrumb.bottomAnchor.constraint(equalTo: pathBar.bottomAnchor),

            filterField.trailingAnchor.constraint(equalTo: tools.leadingAnchor, constant: -8),
            filterField.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            filterField.heightAnchor.constraint(equalToConstant: 20),
            filterWidthConstraint,

            tools.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor, constant: -6),
            tools.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            tools.widthAnchor.constraint(equalToConstant: 96),

            bottomLine.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: pathBar.bottomAnchor)
        ])
    }

    private func buildTable() {
        header.identifier = NSUserInterfaceItemIdentifier("fileHeader")
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onSort = { [weak self] id in
            guard let self, let column = BrowserModel.SortColumn(rawValue: id) else { return }
            self.model.sort(by: column)
            self.reload()
        }
        header.onResize = { [weak self] id, width in
            guard let self else { return }
            self.columnWidths[id] = width
            self.table.tableColumn(withIdentifier: .init(id))?.width = width
            if !self.model.isDemoData {
                UserDefaults.standard.set(
                    self.columnWidths.mapValues { Double($0) },
                    forKey: Self.columnWidthsKey
                )
            }
        }

        addColumn(id: "check", title: "", width: checkWidth)
        addColumn(id: "name", title: "Name", width: 220)
        addColumn(id: "size", title: "Size", width: sizeWidth)
        addColumn(id: "type", title: "Type", width: typeWidth)
        addColumn(id: "modified", title: "Last Modified", width: modifiedWidth)
        addColumn(id: "storage", title: "Storage Class", width: storageWidth)

        table.setAccessibilityLabel("Files")
        table.headerView = nil
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = Theme.Metrics.fileRowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.Colors.content
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.registerForDraggedTypes([.fileURL])
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.menu = buildContextMenu()
        table.onHoverRow = { [weak self] row in
            guard let self else { return }
            for r in 0..<self.table.numberOfRows {
                (self.table.rowView(atRow: r, makeIfNecessary: false) as? DataRowView)?.isHovered = r == row
            }
        }
        table.onKeyDown = { [weak self] event in
            guard let self else { return false }
            switch event.keyCode {
            case 36, 76:
                self.openSelected()
                return true
            case 51, 117:
                self.deleteSelected()
                return true
            default:
                break
            }
            if event.keyCode == 0x78 {
                self.renameSelected()
                return true
            }
            return false
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.content
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildActionBar() {
        actionBar.identifier = NSUserInterfaceItemIdentifier("actionBar")
        actionBar.themeColor = Theme.Colors.chrome

        let topLine = SeparatorView(axis: .horizontal)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(topLine)

        let upload = FlatButton("Upload", icon: "arrow.up.circle", style: .action) { [weak self] in self?.uploadFiles() }
        upload.iconTint = NSColor(hex: 0x0F7B0F)
        let download = FlatButton("Download", icon: "arrow.down.circle", style: .action) { [weak self] in self?.downloadSelected() }
        download.iconTint = NSColor(hex: 0x0078D4)
        let open = FlatButton("Open", icon: "arrow.up.forward.square", style: .action) { [weak self] in self?.openSelected() }
        open.iconTint = NSColor(hex: 0x0078D4)
        let delete = FlatButton("Delete", icon: "trash", style: .action) { [weak self] in self?.deleteSelected() }
        delete.iconTint = NSColor(hex: 0xC42B1C)
        let folder = FlatButton("New Folder", icon: "folder.badge.plus", style: .action) { [weak self] in self?.newFolder() }
        folder.iconTint = NSColor(hex: 0xD18B00)
        let refresh = FlatButton("Refresh", icon: "arrow.clockwise", style: .action) { [weak self] in self?.refresh() }
        refresh.iconTint = NSColor(hex: 0x0F7B0F)
        objectActionButtons = [upload, download, delete, folder]
        openButton = open
        refreshButton = refresh

        let stack = NSStackView(views: [upload, download, open, delete, folder, refresh, spinner])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(stack)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: actionBar.trailingAnchor, constant: -6),
            topLine.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: actionBar.topAnchor)
        ])
        for button in [upload, download, open, delete, folder, refresh] {
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    private func buildStatusBar() {
        statusBar.identifier = NSUserInterfaceItemIdentifier("statusBar")
        statusBar.themeColor = Theme.Colors.chrome

        let topLine = SeparatorView(axis: .horizontal)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(topLine)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        loadMoreButton.onClick = { [weak self] in self?.loadMore() }

        statusBar.addSubview(statusLabel)
        statusBar.addSubview(loadMoreButton)
        statusBar.addSubview(countLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: loadMoreButton.leadingAnchor, constant: -8),

            loadMoreButton.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -12),
            loadMoreButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            topLine.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: statusBar.topAnchor)
        ])
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = id == "check" ? width : 60
        column.maxWidth = id == "check" ? width : 2000
        column.resizingMask = []
        table.addTableColumn(column)
    }

    private func updateColumnWidths() {
        let available = max(200, scroll.bounds.width)
        let showType = available >= 640
        let showStorage = available >= 720
        let showModified = available >= 480

        table.tableColumn(withIdentifier: .init("check"))?.isHidden = false
        table.tableColumn(withIdentifier: .init("name"))?.isHidden = false
        table.tableColumn(withIdentifier: .init("size"))?.isHidden = false
        table.tableColumn(withIdentifier: .init("type"))?.isHidden = !showType
        table.tableColumn(withIdentifier: .init("modified"))?.isHidden = !showModified
        table.tableColumn(withIdentifier: .init("storage"))?.isHidden = !showStorage

        func appliedWidth(_ id: String, default value: CGFloat, minimum: CGFloat) -> CGFloat {
            max(minimum, columnWidths[id] ?? value)
        }

        let sizeWidth = appliedWidth("size", default: self.sizeWidth, minimum: 60)
        let typeWidth = appliedWidth("type", default: self.typeWidth, minimum: 60)
        let modifiedWidth = appliedWidth("modified", default: self.modifiedWidth, minimum: 100)
        let storageWidth = appliedWidth("storage", default: self.storageWidth, minimum: 60)

        var fixed = checkWidth + sizeWidth
        if showType { fixed += typeWidth }
        if showModified { fixed += modifiedWidth }
        if showStorage { fixed += storageWidth }
        let defaultNameWidth = max(120, available - fixed)
        let nameWidth = appliedWidth("name", default: defaultNameWidth, minimum: 100)

        table.tableColumn(withIdentifier: .init("check"))?.width = checkWidth
        table.tableColumn(withIdentifier: .init("name"))?.width = nameWidth
        table.tableColumn(withIdentifier: .init("size"))?.width = sizeWidth
        table.tableColumn(withIdentifier: .init("type"))?.width = typeWidth
        table.tableColumn(withIdentifier: .init("modified"))?.width = modifiedWidth
        table.tableColumn(withIdentifier: .init("storage"))?.width = storageWidth

        var columns = [
            HeaderColumn(id: "check", title: "", width: checkWidth, alignment: .left),
            HeaderColumn(id: "name", title: "Name", width: nameWidth, alignment: .left),
            HeaderColumn(id: "size", title: "Size", width: sizeWidth, alignment: .left)
        ]
        if showType { columns.append(HeaderColumn(id: "type", title: "Type", width: typeWidth, alignment: .left)) }
        if showModified { columns.append(HeaderColumn(id: "modified", title: "Last Modified", width: modifiedWidth, alignment: .left)) }
        if showStorage { columns.append(HeaderColumn(id: "storage", title: "Storage Class", width: storageWidth, alignment: .left)) }
        header.columns = columns
    }

    func focusInitial() {
        view.window?.makeFirstResponder(table)
    }

    var isTableFirstResponder: Bool {
        view.window?.firstResponder === table
    }

    @objc func toggleFilter() {
        if filterField.isHidden {
            filterField.isHidden = false
            filterWidthConstraint.constant = 170
            filterButton?.isSelectedState = true
            view.window?.makeFirstResponder(filterField)
        } else {
            filterField.stringValue = ""
            filterField.isHidden = true
            filterWidthConstraint.constant = 0
            filterButton?.isSelectedState = false
            model.setFilter("")
            focusInitial()
        }
        view.needsLayout = true
    }

    @objc func focusFilter() {
        if filterField.isHidden {
            toggleFilter()
        } else {
            view.window?.makeFirstResponder(filterField)
            filterField.selectText(nil)
        }
    }

    func showFilterForSnapshot(_ text: String) {
        filterField.isHidden = false
        filterWidthConstraint.constant = 170
        filterField.stringValue = text
        model.setFilter(text)
        view.layoutSubtreeIfNeeded()
    }

    // MARK: - Reload / chrome

    func reload() {
        table.reloadData()
        let visible = model.visibleItems
        model.requestFolderStats(for: visible)
        table.menu = buildContextMenu()
        updateColumnWidths()
        header.sortColumn = model.currentSort.column.rawValue
        header.sortAscending = model.currentSort.ascending
        header.needsDisplay = true

        let rows = IndexSet(visible.enumerated().compactMap { model.selection.contains($0.element.key) ? $0.offset : nil })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        updateChrome()
        updateTextColors()
    }

    func updateChrome() {
        breadcrumb.setPath(bucket: model.selectedBucket, prefix: model.prefix)

        if let error = model.errorMessage {
            statusLabel.stringValue = "⚠︎ " + error.split(separator: "\n").first.map(String.init).orEmpty
            statusLabel.textColor = Theme.Colors.warning
        } else {
            statusLabel.stringValue = model.isBusy ? model.status : (model.currentPath.isEmpty ? "Ready" : model.status)
            statusLabel.textColor = Theme.Colors.secondaryText
        }

        countLabel.stringValue = model.selectedBucket == nil ? "" : model.statusText
        loadMoreButton.isHidden = !model.isTruncated
        if model.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        let hasBucket = model.selectedBucket != nil
        objectActionButtons.forEach { $0.isEnabled = hasBucket }
        openButton?.isEnabled = hasBucket && model.selectedItem != nil
        refreshButton?.isEnabled = model.selectedAccount != nil
        bookmarkButton?.isEnabled = hasBucket
        renameButton?.isEnabled = hasBucket && model.selectedItem != nil
        filterButton?.isEnabled = hasBucket
        filterButton?.isSelectedState = !filterField.isHidden
        filterButton?.iconTint = filterField.isHidden ? nil : Theme.Colors.accent
        if !filterField.isHidden, model.filterText.isEmpty, !filterField.stringValue.isEmpty {
            filterField.stringValue = ""
        }
        table.setAccessibilityLabel("Files")

        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasBucket = model.selectedBucket != nil
        let visible = model.visibleItems
        let empty = !hasBucket || visible.isEmpty
        emptyView.isHidden = !empty
        guard empty else { return }

        if !hasBucket {
            emptyView.action = nil
            emptyView.update(
                iconName: "shippingbox",
                title: model.hasAccounts ? "Select a bucket" : "No storage accounts",
                subtitle: model.hasAccounts
                    ? "Choose a bucket in the sidebar to browse its objects."
                    : "Add an account to browse S3 or compatible storage."
            )
            emptyView.setActionVisible(false)
            return
        }

        if model.isBusy, model.items.isEmpty, model.errorMessage == nil {
            emptyView.action = nil
            emptyView.update(
                iconName: "hourglass",
                title: "Loading \(model.selectedBucket ?? "bucket")…",
                subtitle: "Fetching the first page of objects."
            )
            emptyView.setActionVisible(false)
            return
        }

        if let error = model.errorMessage, model.items.isEmpty {
            let message = error.split(separator: "\n").first.map(String.init) ?? error
            emptyView.update(
                iconName: "exclamationmark.triangle",
                title: "Couldn't load this bucket",
                subtitle: message
            )
            emptyView.action = { [weak self] in self?.refresh() }
            emptyView.setActionVisible(true, title: "Retry")
            return
        }

        if model.isFiltering, !model.items.isEmpty {
            emptyView.update(
                iconName: "line.3.horizontal.decrease",
                title: "No matches",
                subtitle: "No objects match “\(model.filterText)”."
            )
            emptyView.action = { [weak self] in self?.toggleFilter() }
            emptyView.setActionVisible(true, title: "Clear filter")
            return
        }

        emptyView.action = { [weak self] in self?.uploadFiles() }
        emptyView.update(
            iconName: "folder",
            title: "This folder is empty",
            subtitle: "Upload files or create a folder here."
        )
        emptyView.setActionVisible(true, title: "Upload files")
    }

    private func updateTextColors() {
        let visible = model.visibleItems
        for row in 0..<table.numberOfRows {
            let selected = table.selectedRowIndexes.contains(row)
            let color = selected ? Theme.Colors.selectionText : Theme.Colors.text
            if let cell = table.view(atColumn: 1, row: row, makeIfNecessary: false) as? FileCellView,
               row < visible.count {
                cell.configure(item: visible[row], selected: selected)
            }
            for column in 2..<table.numberOfColumns {
                (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?
                    .textField?.textColor = color
            }
        }
    }

    // MARK: - Folder stats

    func refreshFolderStatsForListing() {
        model.requestFolderStats(for: model.visibleItems)
    }

    func updateFolderMetric(_ key: String) {
        guard let row = model.visibleItems.firstIndex(where: { $0.key == key }) else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
        )
    }

    // MARK: - Actions

    @objc func goUp() {
        Task { await model.up() }
    }

    @objc func refresh() {
        Task { await model.refresh() }
    }

    @objc func loadMore() {
        Task { await model.loadMore() }
    }

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        let visible = model.visibleItems
        guard row >= 0, row < visible.count else { return }
        let item = visible[row]
        if item.kind == .folder {
            Task { await model.open(item) }
        } else {
            openObject(item)
        }
    }

    private func openObject(_ item: S3Item) {
        model.openObject(item)
    }

    @objc func uploadFiles() {
        guard model.selectedBucket != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        model.upload(urls: panel.urls)
    }

    @objc func uploadFolder() {
        guard model.selectedBucket != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.uploadDirectory(url)
    }

    @objc func downloadSelected() {
        guard model.selectedItem != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await model.download(items: model.selectedItems, to: directory) }
    }

    @objc func deleteSelected() {
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        let hasFolders = items.contains { $0.kind == .folder }
        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? "Delete \(items[0].displayName)?"
            : "Delete \(items.count) selected items?"
        alert.informativeText = hasFolders
            ? "This removes the selected objects and everything inside selected folders from \(model.currentPath). This cannot be undone."
            : "This removes the object(s) from \(model.currentPath). This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.delete(items: items) }
    }

    @objc func newFolder() {
        guard model.selectedBucket != nil, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Create New Folder"
        alert.informativeText = "Enter a name for the new folder in \(model.currentPath)"
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

    @objc func renameSelected() {
        guard let item = model.selectedItem, item.kind == .object, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Object"
        alert.informativeText = "Rename \(item.displayName). S3 performs this as a copy followed by a delete."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = item.displayName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.model.rename(item, to: field.stringValue) }
        }
    }

    @objc func copySelected() {
        model.copySelectionToClipboard(cut: false)
    }

    @objc func cutSelected() {
        model.copySelectionToClipboard(cut: true)
    }

    @objc func pasteItems() {
        Task { await model.paste() }
    }

    @objc func selectAllItems() {
        model.setSelection(Set(model.visibleItems.map(\.key)))
        reload()
    }

    @objc func showProperties() {
        onShowInspector?("properties")
        if let item = model.selectedItem {
            Task { await model.loadDetails(for: item) }
        }
    }

    @objc func showVersions() {
        onShowInspector?("versions")
        if let item = model.selectedItem {
            Task { await model.loadVersions(for: item) }
        }
    }

    @objc func copyTo() {
        presentCopyDialog(move: false)
    }

    @objc func moveTo() {
        presentCopyDialog(move: true)
    }

    private func presentCopyDialog(move: Bool) {
        guard let window = view.window, !model.selectedItems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = move ? "Move to…" : "Copy to…"
        alert.informativeText = "Choose the destination bucket and optional folder prefix."
        alert.addButton(withTitle: move ? "Move" : "Copy")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 340, height: 24), pullsDown: false)
        popup.addItems(withTitles: model.buckets.map(\.name))
        if let current = model.selectedBucket, let index = model.buckets.firstIndex(where: { $0.name == current }) {
            popup.selectItem(at: index)
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "Destination prefix (optional), e.g. archive/2026/"
        field.stringValue = model.prefix
        accessory.addSubview(popup)
        accessory.addSubview(field)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let bucket = popup.titleOfSelectedItem else { return }
            var prefix = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
            Task {
                await self.model.copy(items: self.model.selectedItems, toBucket: bucket, toPrefix: prefix, move: move)
            }
        }
    }

    // MARK: - Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Download…", action: #selector(downloadSelected), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(cutSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copySelected), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(pasteItems), keyEquivalent: "")
        menu.addItem(withTitle: "Copy to…", action: #selector(copyTo), keyEquivalent: "")
        menu.addItem(withTitle: "Move to…", action: #selector(moveTo), keyEquivalent: "")
        menu.addItem(withTitle: "Rename…", action: #selector(renameSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Folder…", action: #selector(newFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Upload file(s)…", action: #selector(uploadFiles), keyEquivalent: "")
        menu.addItem(withTitle: "Upload folder(s)…", action: #selector(uploadFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Properties", action: #selector(showProperties), keyEquivalent: "")
        menu.addItem(withTitle: "Versions", action: #selector(showVersions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard model.selectedBucket != nil,
              !fileURLs(from: info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard model.selectedBucket != nil else { return false }
        let urls = fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        var files: [URL] = []
        var directories: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                directories.append(url)
            } else {
                files.append(url)
            }
        }
        if !files.isEmpty { model.upload(urls: files) }
        for directory in directories { model.uploadDirectory(directory) }
        return !files.isEmpty || !directories.isEmpty
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { ($0 as? NSURL) as URL? }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let visible = model.visibleItems
        guard let column = tableColumn, row < visible.count else { return nil }
        let item = visible[row]
        let selected = tableView.selectedRowIndexes.contains(row)

        switch column.identifier.rawValue {
        case "check":
            let identifier = NSUserInterfaceItemIdentifier("checkcell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                let checkbox = CheckboxView()
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    checkbox.widthAnchor.constraint(equalToConstant: 18),
                    checkbox.heightAnchor.constraint(equalToConstant: 18)
                ])
                cell.identifier = identifier
                return cell
            }()
            if let checkbox = cell.subviews.first as? CheckboxView {
                checkbox.tag = row
                checkbox.isChecked = model.checked.contains(item.key)
                checkbox.accessibilityTitle = "Select \(item.displayName)"
                checkbox.onToggle = { [weak self] in self?.model.toggleChecked(item.key) }
            }
            return cell

        case "name":
            let identifier = NSUserInterfaceItemIdentifier("namecell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView) ?? {
                let cell = FileCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.configure(item: item, selected: selected)
            return cell

        case "size":
            let cell = textCell(tableView, id: "sizecell", alignment: .left)
            cell.textField?.stringValue = model.sizeText(for: item)
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
            cell.toolTip = model.folderTooltip(for: item)
            return cell

        case "type":
            let cell = textCell(tableView, id: "typecell")
            cell.textField?.stringValue = item.kind == .folder ? "Folder" : item.typeDescription
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.secondaryText
            return cell

        case "modified":
            let cell = textCell(tableView, id: "modifiedcell")
            cell.textField?.stringValue = model.modifiedText(for: item)
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
            cell.toolTip = model.folderTooltip(for: item)
            return cell

        case "storage":
            let cell = textCell(tableView, id: "storagecell")
            cell.textField?.stringValue = item.storageClass ?? (item.kind == .folder ? "" : "STANDARD")
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.secondaryText
            return cell

        default:
            return nil
        }
    }

    private func textCell(_ table: NSTableView, id: String, alignment: NSTextAlignment = .left) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.alignment = alignment
            return cell
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: "")
        field.font = Theme.Font.body
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        cell.identifier = identifier
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DataRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let visible = model.visibleItems
        let keys = Set(table.selectedRowIndexes.compactMap {
            $0 < visible.count ? visible[$0].key : nil
        })
        model.setSelection(keys)
        updateTextColors()
        updateChrome()
    }
}

extension BrowserViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === filterField else { return }
        model.setFilter(filterField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === filterField,
              commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        toggleFilter()
        return true
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
