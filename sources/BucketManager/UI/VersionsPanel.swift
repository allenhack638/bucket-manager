import AppKit

/// Version history for the selected object, with restore and delete actions.
@MainActor
final class VersionsPanel: NSView {
    var onRestore: ((ObjectVersion) -> Void)?
    var onDelete: ((ObjectVersion) -> Void)?

    private(set) var versions: [ObjectVersion] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = ThemedView()
    private let hint = Labels.label("", font: Theme.Font.small, color: Theme.Colors.secondaryText)
    private(set) var restoreButton: FlatButton!
    private(set) var deleteButton: FlatButton!

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("state", "State", 110),
        ("modified", "Modified", 150),
        ("size", "Size", 80),
        ("version", "Version ID", 260)
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedVersion: ObjectVersion? {
        let row = table.selectedRow
        return versions.indices.contains(row) ? versions[row] : nil
    }

    func update(_ versions: [ObjectVersion]) {
        let previous = selectedVersion?.id
        self.versions = versions
        table.reloadData()
        if let previous, let row = versions.firstIndex(where: { $0.id == previous }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateActions()
    }

    func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateActions()
    }

    private func build() {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.setAccessibilityLabel("Object versions")
        table.rowHeight = Theme.Metrics.transferRowHeight
        table.backgroundColor = Theme.Colors.content
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.content
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer.themeColor = Theme.Colors.chrome
        footer.translatesAutoresizingMaskIntoConstraints = false
        let topLine = SeparatorView(axis: .horizontal)
        topLine.translatesAutoresizingMaskIntoConstraints = false

        let restore = FlatButton("Restore", icon: "arrow.uturn.backward", style: .link) { [weak self] in
            guard let version = self?.selectedVersion else { return }
            self?.onRestore?(version)
        }
        restore.accessibilityTitle = "Restore selected version"
        let delete = FlatButton("Delete Version…", icon: "trash", style: .link) { [weak self] in
            guard let version = self?.selectedVersion else { return }
            self?.onDelete?(version)
        }
        delete.accessibilityTitle = "Permanently delete selected version"
        restoreButton = restore
        deleteButton = delete

        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [restore, delete, hint])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for button in [restore, delete] {
            button.fontSize = 11
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        footer.addSubview(topLine)
        footer.addSubview(stack)
        addSubview(scroll)
        addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.Metrics.transferFooterHeight),

            topLine.topAnchor.constraint(equalTo: footer.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        updateActions()
    }

    private func updateActions() {
        let version = selectedVersion
        restoreButton.isEnabled = version.map { !$0.isLatest && !$0.isDeleteMarker } ?? false
        deleteButton.isEnabled = version != nil
        switch version {
        case nil:
            hint.stringValue = "Select a version to restore or delete it."
        case let v? where v.isDeleteMarker:
            hint.stringValue = v.isLatest
                ? "Deleting this marker brings the object back."
                : "An old delete marker; removing it changes nothing visible."
        case let v? where v.isLatest:
            hint.stringValue = "This is the current version."
        default:
            hint.stringValue = "Restore copies this version over the current one."
        }
    }

    static func stateTitle(_ version: ObjectVersion) -> String {
        if version.isDeleteMarker { return version.isLatest ? "Deleted (marker)" : "Delete marker" }
        return version.isLatest ? "Current" : "Previous"
    }
}

extension VersionsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, versions.indices.contains(row) else { return nil }
        let version = versions[row]
        let text: String
        switch id {
        case "state": text = Self.stateTitle(version)
        case "modified": text = version.lastModified?.s3ListString ?? "—"
        case "size": text = version.size?.byteString ?? "—"
        default: text = version.versionID
        }
        let field = Labels.label(text, font: id == "version" ? Theme.Font.mono : Theme.Font.small)
        field.lineBreakMode = id == "version" ? .byTruncatingMiddle : .byTruncatingTail
        if version.isDeleteMarker { field.textColor = Theme.Colors.secondaryText }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
    }
}
