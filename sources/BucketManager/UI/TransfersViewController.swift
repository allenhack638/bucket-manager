import AppKit

final class TransferCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Font.small
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.Icon.status.size),
            icon.heightAnchor.constraint(equalToConstant: Theme.Icon.status.size),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(task: TransferTask, selected: Bool) {
        label.stringValue = task.title
        let name: String
        switch task.direction {
        case .upload: name = "arrow.up.circle.fill"
        case .download: name = "arrow.down.circle.fill"
        case .copy: name = "arrow.left.arrow.right.circle.fill"
        }
        icon.image = Theme.Icon.image(name, style: Theme.Icon.status)
        icon.contentTintColor = selected ? Theme.Colors.selectionText : Theme.Colors.accent
        label.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
    }
}

final class TransferProgressCell: NSTableCellView {
    let bar = ProgressBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class TransfersViewController: NSViewController {
    enum Filter: String {
        case all = "All"
        case running = "Running"
        case queued = "Queued"
        case stopped = "Stopped"
        case failed = "Failed"
    }

    struct TabDef {
        let id: String
        let title: String
    }

    private let model: BrowserModel
    private let tabs: [TabDef] = [
        .init(id: "tasks", title: "Tasks"),
        .init(id: "permissions", title: "Permissions"),
        .init(id: "headers", title: "Headers"),
        .init(id: "tags", title: "Tags"),
        .init(id: "properties", title: "Properties"),
        .init(id: "preview", title: "Preview"),
        .init(id: "versions", title: "Versions"),
        .init(id: "log", title: "Event Log")
    ]

    private let tabStrip = TabStripView()
    private let content = ThemedView()
    private let tasksContainer = NSView()
    private let tasksHeader = ColumnHeaderView()
    private let tasksTable = HoverTrackingTableView()
    private let tasksScroll = NSScrollView()
    private let footer = ThemedView()
    private let infoView = InfoTextView()
    private let previewImageView = NSImageView()
    let versionsPanel = VersionsPanel()

    private let sizeWidth: CGFloat = 78
    private let percentWidth: CGFloat = 56
    private let progressWidth: CGFloat = 90
    private let statusWidth: CGFloat = 96
    private let speedWidth: CGFloat = 72

    private var selectedTab = "tasks"
    private var filter: Filter = .all
    private var visibleTasks: [TransferTask] = []
    private var filterButtons: [FlatButton] = []
    private var filterMap: [Filter: FlatButton] = [:]
    private let summaryLabel = Labels.label("", font: Theme.Font.small, color: Theme.Colors.secondaryText)
    private let emptyTransfersView = EmptyStateView(
        iconName: "tray",
        title: "No transfers yet",
        subtitle: "Upload or download files to see the queue here."
    )
    private let logEmptyView = EmptyStateView(
        iconName: "list.bullet.rectangle",
        title: "No events yet",
        subtitle: "Bucket activity, transfers, and errors will appear here."
    )
    private let footerProgress = ProgressBarView()
    private var startButton: FlatButton?
    private var stopButton: FlatButton?
    private var cancelButton: FlatButton?
    private var filterStack: NSStackView?

    init(model: BrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedView()
        root.themeColor = Theme.Colors.chrome

        tabStrip.tabs = tabs.map { TabStripView.Tab(id: $0.id, title: $0.title) }
        tabStrip.selectedID = selectedTab
        tabStrip.onSelect = { [weak self] id in self?.selectTab(id) }
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

        content.themeColor = Theme.Colors.content
        content.translatesAutoresizingMaskIntoConstraints = false

        buildTasks()
        buildFooter()

        content.addSubview(tasksContainer)
        content.addSubview(infoView)
        content.addSubview(previewImageView)
        content.addSubview(logEmptyView)
        content.addSubview(versionsPanel)
        versionsPanel.translatesAutoresizingMaskIntoConstraints = false
        versionsPanel.pinEdges(to: content)
        versionsPanel.isHidden = true
        versionsPanel.onRestore = { [weak self] version in self?.confirmVersion(.restore, version) }
        versionsPanel.onDelete = { [weak self] version in self?.confirmVersion(.delete, version) }
        tasksContainer.translatesAutoresizingMaskIntoConstraints = false
        infoView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        logEmptyView.translatesAutoresizingMaskIntoConstraints = false
        tasksContainer.pinEdges(to: content)
        infoView.pinEdges(to: content)
        previewImageView.pinEdges(to: content)
        logEmptyView.pinEdges(to: content)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        previewImageView.setAccessibilityLabel("Image preview")
        previewImageView.isHidden = true
        logEmptyView.isHidden = true

        root.addSubview(tabStrip)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: Theme.Metrics.tabBarHeight),

            content.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root
        root.layoutSubtreeIfNeeded()
        selectTab(selectedTab)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWidths()
        updateFooterLayout()
        DispatchQueue.main.async { [weak self] in
            self?.updateWidths()
            self?.updateFooterLayout()
        }
    }

    private func buildTasks() {
        tasksHeader.translatesAutoresizingMaskIntoConstraints = false
        tasksHeader.sortColumn = nil

        addTaskColumn("task", width: 260)
        addTaskColumn("size", width: sizeWidth)
        addTaskColumn("percent", width: percentWidth)
        addTaskColumn("progress", width: progressWidth)
        addTaskColumn("status", width: statusWidth)
        addTaskColumn("speed", width: speedWidth)

        tasksTable.setAccessibilityLabel("Transfers")
        tasksTable.headerView = nil
        tasksTable.rowHeight = Theme.Metrics.transferRowHeight
        tasksTable.intercellSpacing = .zero
        tasksTable.backgroundColor = Theme.Colors.content
        tasksTable.usesAlternatingRowBackgroundColors = false
        tasksTable.allowsMultipleSelection = true
        tasksTable.selectionHighlightStyle = .regular
        tasksTable.focusRingType = .none
        tasksTable.style = .plain
        tasksTable.dataSource = self
        tasksTable.delegate = self
        tasksTable.target = self
        tasksTable.doubleAction = #selector(openTaskLocation)
        tasksTable.menu = taskMenu()

        tasksScroll.documentView = tasksTable
        tasksScroll.hasVerticalScroller = true
        tasksScroll.autohidesScrollers = true
        tasksScroll.borderType = .noBorder
        tasksScroll.drawsBackground = true
        tasksScroll.backgroundColor = Theme.Colors.content
        tasksScroll.translatesAutoresizingMaskIntoConstraints = false

        tasksContainer.addSubview(tasksHeader)
        tasksContainer.addSubview(tasksScroll)
        tasksContainer.addSubview(footer)
        tasksContainer.addSubview(emptyTransfersView)
        emptyTransfersView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyTransfersView.centerXAnchor.constraint(equalTo: tasksScroll.centerXAnchor),
            emptyTransfersView.centerYAnchor.constraint(equalTo: tasksScroll.centerYAnchor),
            emptyTransfersView.widthAnchor.constraint(lessThanOrEqualTo: tasksScroll.widthAnchor, constant: -24),
            emptyTransfersView.heightAnchor.constraint(lessThanOrEqualTo: tasksScroll.heightAnchor, constant: -8),
            emptyTransfersView.topAnchor.constraint(greaterThanOrEqualTo: tasksScroll.topAnchor, constant: 4),
            emptyTransfersView.bottomAnchor.constraint(lessThanOrEqualTo: tasksScroll.bottomAnchor, constant: -4)
        ])
        let emptyWidth = emptyTransfersView.widthAnchor.constraint(equalToConstant: 420)
        emptyWidth.priority = .defaultHigh
        let emptyHeight = emptyTransfersView.heightAnchor.constraint(equalToConstant: 120)
        emptyHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([emptyWidth, emptyHeight])

        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tasksHeader.topAnchor.constraint(equalTo: tasksContainer.topAnchor),
            tasksHeader.leadingAnchor.constraint(equalTo: tasksContainer.leadingAnchor),
            tasksHeader.trailingAnchor.constraint(equalTo: tasksContainer.trailingAnchor),
            tasksHeader.heightAnchor.constraint(equalToConstant: 22),

            tasksScroll.topAnchor.constraint(equalTo: tasksHeader.bottomAnchor),
            tasksScroll.leadingAnchor.constraint(equalTo: tasksContainer.leadingAnchor),
            tasksScroll.trailingAnchor.constraint(equalTo: tasksContainer.trailingAnchor),
            tasksScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: tasksContainer.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: tasksContainer.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: tasksContainer.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.Metrics.transferFooterHeight)
        ])
    }

    private func buildFooter() {
        footer.themeColor = Theme.Colors.chrome

        let topLine = SeparatorView(axis: .horizontal)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(topLine)

        let filters: [(Filter, String)] = [
            (.running, "Running"),
            (.queued, "Queued"),
            (.stopped, "Stopped"),
            (.failed, "Failed")
        ]
        let filterStack = NSStackView()
        self.filterStack = filterStack
        filterStack.orientation = .horizontal
        filterStack.spacing = 10
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        for (filter, title) in filters {
            let button = FlatButton(title, style: .link)
            button.fontSize = 11
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityTitle = "Show \(title.lowercased()) transfers"
            button.onClick = { [weak self] in self?.toggleFilter(filter) }
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            filterStack.addArrangedSubview(button)
            filterButtons.append(button)
            filterMap[filter] = button
        }
        filterStack.setContentHuggingPriority(.required, for: .horizontal)
        filterStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterStack.distribution = .fill
        footer.addSubview(filterStack)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.alignment = .center
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addSubview(summaryLabel)

        let start = FlatButton("Start All", icon: "play.fill", style: .link) { [weak self] in
            self?.model.transfers.startAll()
        }
        let stop = FlatButton("Stop All", icon: "stop.fill", style: .link) { [weak self] in
            self?.model.transfers.stopAll()
        }
        let cancel = FlatButton("Cancel All", icon: "xmark", style: .link) { [weak self] in
            self?.model.transfers.cancelAll()
        }
        for button in [start, stop, cancel] {
            button.fontSize = 11
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        start.accessibilityTitle = "Start all transfers"
        stop.accessibilityTitle = "Stop all transfers"
        cancel.accessibilityTitle = "Cancel all transfers"
        startButton = start
        stopButton = stop
        cancelButton = cancel
        let actionStack = NSStackView(views: [start, stop, cancel])
        actionStack.orientation = .horizontal
        actionStack.spacing = 10
        actionStack.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(actionStack)

        let actionDivider = SeparatorView(axis: .vertical)
        actionDivider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(actionDivider)

        footerProgress.translatesAutoresizingMaskIntoConstraints = false
        footerProgress.barColor = Theme.Colors.accent
        footerProgress.setAccessibilityLabel("Overall transfer progress")
        footer.addSubview(footerProgress)

        NSLayoutConstraint.activate([
            filterStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            filterStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: -1),

            actionStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            actionStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: -1),

            actionDivider.widthAnchor.constraint(equalToConstant: 1),
            actionDivider.heightAnchor.constraint(equalToConstant: 18),
            actionDivider.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: -1),
            actionDivider.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -12),

            summaryLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            summaryLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: -1),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: filterStack.trailingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionDivider.leadingAnchor, constant: -16),

            footerProgress.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerProgress.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerProgress.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            footerProgress.heightAnchor.constraint(equalToConstant: 6),

            topLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: footer.topAnchor)
        ])
    }

    private func addTaskColumn(_ id: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.width = width
        column.resizingMask = id == "task" ? .autoresizingMask : []
        tasksTable.addTableColumn(column)
    }

    private func updateWidths() {
        let fixed = sizeWidth + percentWidth + progressWidth + statusWidth + speedWidth
        let taskWidth = max(160, tasksScroll.bounds.width - fixed)
        tasksTable.tableColumn(withIdentifier: .init("task"))?.width = taskWidth
        tasksTable.tableColumn(withIdentifier: .init("size"))?.width = sizeWidth
        tasksTable.tableColumn(withIdentifier: .init("percent"))?.width = percentWidth
        tasksTable.tableColumn(withIdentifier: .init("progress"))?.width = progressWidth
        tasksTable.tableColumn(withIdentifier: .init("status"))?.width = statusWidth
        tasksTable.tableColumn(withIdentifier: .init("speed"))?.width = speedWidth

        tasksHeader.columns = [
            HeaderColumn(id: "task", title: "Task", width: taskWidth, alignment: .left),
            HeaderColumn(id: "size", title: "Size", width: sizeWidth, alignment: .left),
            HeaderColumn(id: "percent", title: "%", width: percentWidth, alignment: .right),
            HeaderColumn(id: "progress", title: "Progress", width: progressWidth, alignment: .left),
            HeaderColumn(id: "status", title: "Status", width: statusWidth, alignment: .left),
            HeaderColumn(id: "speed", title: "Speed", width: speedWidth, alignment: .right)
        ]
    }

    // MARK: - Public

    func reload() {
        applyFilter()
        tabStrip.setCount(model.transfers.tasks.count, for: "tasks")
        tabStrip.selectedID = selectedTab
        tasksTable.reloadData()
        emptyTransfersView.isHidden = !visibleTasks.isEmpty
        if visibleTasks.isEmpty {
            if filter == .all {
                emptyTransfersView.update(iconName: "tray", title: "No transfers yet", subtitle: "Upload or download files to see the queue here.")
            } else {
                emptyTransfersView.update(iconName: "line.3.horizontal.decrease", title: "No matching transfers", subtitle: "There are no \(filter.rawValue.lowercased()) transfers right now.")
            }
        }
        updateFooterCounts()
        updateFooterSummary()
        let totalBytes = model.transfers.totalBytes
        footerProgress.progress = totalBytes > 0 ? Double(model.transfers.doneBytes) / Double(totalBytes) : 0
        footer.layoutSubtreeIfNeeded()
        if selectedTab == "tasks" { updateInfo() }
    }

    private var pendingDetailLoad: Task<Void, Never>?

    func updateDetails() {
        if selectedTab != "tasks" { updateInfo() }
        scheduleActiveTabLoad()
    }

    private func scheduleActiveTabLoad() {
        pendingDetailLoad?.cancel()
        pendingDetailLoad = nil
        guard selectedTab != "tasks", selectedTab != "log" else { return }
        guard let item = model.selectedItem, item.kind == .object else { return }
        guard !model.inspectorLoaded(selectedTab, for: item) else { return }
        let tab = selectedTab
        pendingDetailLoad = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self,
                  self.selectedTab == tab,
                  self.model.selectedItem?.key == item.key else { return }
            self.loadTabData(tab, item: item)
        }
    }

    func updateLog() {
        if selectedTab == "log" { updateInfo() }
    }

    func selectTab(_ id: String) {
        selectTab(id, requireAuth: true)
    }

    func selectTabForSnapshot(_ id: String) {
        selectTab(id, requireAuth: false)
    }

    private func selectTab(_ id: String, requireAuth: Bool) {
        if requireAuth, id == "log", !AdminAuthSession.shared.isUnlocked {
            let previous = selectedTab
            guard AdminAuthPrompt.authorize(reason: "Unlock the event log") else {
                tabStrip.selectedID = previous
                return
            }
        }
        LogStore.shared.log(
            .debug, category: .ui, event: "ui.tab.changed",
            message: "Inspector tab changed", metadata: ["tab": id]
        )
        pendingDetailLoad?.cancel()
        pendingDetailLoad = nil
        selectedTab = id
        tabStrip.selectedID = id
        let tasksVisible = id == "tasks"
        tasksContainer.isHidden = !tasksVisible
        infoView.isHidden = tasksVisible
        versionsPanel.isHidden = true
        previewImageView.isHidden = true
        logEmptyView.isHidden = true
        filterButtons.forEach { $0.isHidden = !tasksVisible }

        if tasksVisible {
            reload()
        } else {
            updateInfo()
            loadTabData(id)
        }
        view.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        infoView.layoutSubtreeIfNeeded()
    }

    private func loadTabData(_ id: String, item selected: S3Item? = nil) {
        guard let item = selected ?? model.selectedItem, item.kind == .object else { return }
        guard !model.inspectorLoaded(id, for: item) else { return }
        switch id {
        case "properties", "headers":
            Task { await model.loadDetails(for: item) }
        case "tags":
            Task { await model.loadTags(for: item) }
        case "permissions":
            Task { await model.loadACL(for: item) }
        case "versions":
            Task { await model.loadVersions(for: item) }
        case "preview":
            Task { await model.loadPreview(for: item) }
        default:
            break
        }
    }

    // MARK: - Data

    private func applyFilter() {
        let all = model.transfers.tasks
        switch filter {
        case .all: visibleTasks = all
        case .running: visibleTasks = all.filter { $0.status == .running }
        case .queued: visibleTasks = all.filter { $0.status == .queued }
        case .stopped: visibleTasks = all.filter { $0.status == .paused }
        case .failed: visibleTasks = all.filter { $0.status == .failed }
        }
    }

    private func toggleFilter(_ value: Filter) {
        filter = (filter == value) ? .all : value
        reload()
    }

    private func updateFooterLayout() {
        updateFooterSummary()
        filterStack?.invalidateIntrinsicContentSize()
        summaryLabel.invalidateIntrinsicContentSize()
        footer.layoutSubtreeIfNeeded()
    }

    private func updateFooterSummary() {
        let width = footer.bounds.width
        summaryLabel.isHidden = width < 760
        summaryLabel.stringValue = width >= 900 ? model.summaryText : model.summaryCompactText
        summaryLabel.toolTip = model.summaryText
    }

    private func updateFooterCounts() {
        guard let filterStack else { return }
        let titles: [(Filter, String, Int, Bool)] = [
            (.running, "Running", model.transfers.runningCount, true),
            (.queued, "Queued", model.transfers.queuedCount, true),
            (.stopped, "Stopped", model.transfers.stoppedCount, false),
            (.failed, "Failed", model.transfers.failedCount, false)
        ]
        let labels = titles.map { $0.3 ? "\($0.1) (\($0.2))" : $0.1 }

        if labels == filterButtons.map({ $0.title }) {
            for button in filterButtons {
                if let match = titles.first(where: { button.title.hasPrefix($0.1) }) {
                    button.isSelectedState = filter == match.0
                }
            }
            return
        }

        for view in filterStack.arrangedSubviews {
            filterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        filterButtons.removeAll()
        filterMap.removeAll()

        for (index, item) in titles.enumerated() {
            let button = FlatButton(labels[index], style: .link)
            button.fontSize = 11
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isSelectedState = filter == item.0
            button.accessibilityTitle = "Show \(item.1.lowercased()) transfers"
            button.accessibilityHelpText = "\(item.2) \(item.1.lowercased())"
            button.onClick = { [weak self] in self?.toggleFilter(item.0) }
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            filterStack.addArrangedSubview(button)
            filterButtons.append(button)
            filterMap[item.0] = button
        }
    }

    private func updateInfo() {
        let tab = selectedTab
        let item = model.selectedItem
        previewImageView.isHidden = true
        versionsPanel.isHidden = true

        if tab == "tasks" {
            logEmptyView.isHidden = true
            infoView.isHidden = true
            return
        }

        if tab == "log" {
            let isEmpty = model.logs.isEmpty
            logEmptyView.isHidden = !isEmpty
            infoView.isHidden = isEmpty
            if isEmpty {
                logEmptyView.update(
                    iconName: "list.bullet.rectangle",
                    title: "No events yet",
                    subtitle: "Bucket activity, transfers, and errors will appear here."
                )
            } else {
                infoView.setText(model.logs.joined(separator: "\n"))
            }
            return
        }
        logEmptyView.isHidden = true
        infoView.isHidden = false

        guard let item else {
            infoView.setPlaceholder("Select a file to see its \(tabDisplayName(tab)).")
            return
        }
        if item.isDeleted, item.kind == .folder {
            infoView.setPlaceholder("This folder only holds deleted objects. Open it to undelete them.")
            return
        }
        guard item.kind == .object else {
            infoView.setPlaceholder("Folders do not have \(tabDisplayName(tab)).")
            return
        }
        if item.isDeleted, tab != "versions" {
            infoView.setPlaceholder("\(item.displayName) is deleted. Use Undelete, or restore a version from the Versions tab.")
            return
        }

        switch tab {
        case "properties":
            guard let d = model.details else {
                infoView.setPlaceholder(model.inspectorLoaded("properties", for: item)
                    ? "Could not load properties. See the status bar."
                    : "Loading properties…")
                return
            }
            var lines: [String] = []
            lines.append("Name:                \(item.key)")
            lines.append("Bucket:              \(model.selectedBucket ?? "")")
            lines.append("Size:                \(d.contentLength?.byteString ?? item.size?.byteString ?? "—")")
            lines.append("Content type:        \(d.contentType ?? item.typeDescription)")
            lines.append("Last modified:       \(d.lastModified?.s3ListString ?? "—")")
            lines.append("ETag:                \(d.eTag ?? item.eTag ?? "—")")
            lines.append("Storage class:       \(d.storageClass ?? item.storageClass ?? "STANDARD")")
            lines.append("Version ID:          \(d.versionID ?? "—")")
            lines.append("Encryption:          \(d.serverSideEncryption ?? "—")")
            if !d.metadata.isEmpty {
                lines.append("")
                lines.append("User metadata:")
                for key in d.metadata.keys.sorted() {
                    lines.append("  \(key): \(d.metadata[key] ?? "")")
                }
            }
            infoView.setText(lines.joined(separator: "\n"))

        case "headers":
            guard let d = model.details else {
                infoView.setPlaceholder(model.inspectorLoaded("properties", for: item)
                    ? "Could not load headers. See the status bar."
                    : "Loading headers…")
                return
            }
            var lines: [String] = []
            lines.append("Content-Type: \(d.contentType ?? "—")")
            lines.append("Content-Length: \(d.contentLength.map(String.init) ?? "—")")
            lines.append("ETag: \(d.eTag ?? "—")")
            lines.append("Last-Modified: \(d.lastModified?.s3ListString ?? "—")")
            lines.append("Cache-Control: \(d.cacheControl ?? "—")")
            lines.append("Content-Disposition: \(d.contentDisposition ?? "—")")
            lines.append("Content-Encoding: \(d.contentEncoding ?? "—")")
            lines.append("Content-Language: \(d.contentLanguage ?? "—")")
            lines.append("Expires: \(d.expires ?? "—")")
            lines.append("Accept-Ranges: \(d.acceptRanges ?? "—")")
            lines.append("x-amz-version-id: \(d.versionID ?? "—")")
            lines.append("x-amz-server-side-encryption: \(d.serverSideEncryption ?? "—")")
            for key in d.metadata.keys.sorted() {
                lines.append("x-amz-meta-\(key): \(d.metadata[key] ?? "")")
            }
            infoView.setText(lines.joined(separator: "\n"))

        case "tags":
            guard model.tagsKey == item.key else {
                infoView.setPlaceholder("Loading tags…")
                return
            }
            if model.tags.isEmpty {
                infoView.setPlaceholder("This object has no tags.")
            } else {
                infoView.setText(model.tags.keys.sorted().map { "\($0) = \(model.tags[$0] ?? "")" }.joined(separator: "\n"))
            }

        case "permissions":
            if !model.inspectorLoaded("permissions", for: item) {
                infoView.setPlaceholder("Loading permissions…")
            } else if model.acl.isEmpty {
                infoView.setPlaceholder("No ACL grants returned, or the bucket uses bucket-owner-enforced ownership.")
            } else {
                infoView.setText(model.acl.joined(separator: "\n"))
            }

        case "versions":
            if !model.inspectorLoaded("versions", for: item) {
                infoView.setPlaceholder("Loading versions…")
            } else if model.versions.isEmpty {
                infoView.setPlaceholder("No versions returned. Bucket versioning may be disabled.")
            } else {
                versionsPanel.update(model.versions)
                versionsPanel.isHidden = false
                infoView.isHidden = true
            }

        case "preview":
            if !model.inspectorLoaded("preview", for: item) {
                infoView.setPlaceholder("Loading preview…")
            } else if let image = model.previewImage {
                previewImageView.image = image
                previewImageView.setAccessibilityLabel("Preview of \(item.displayName)")
                previewImageView.isHidden = false
                infoView.isHidden = true
            } else {
                infoView.setText(model.previewText ?? "Preview is empty.")
            }

        default:
            infoView.setPlaceholder("")
        }
    }

    private func confirmVersion(_ action: BrowserModel.VersionAction, _ version: ObjectVersion) {
        guard let item = model.selectedItem, let window = view.window else { return }
        let alert = NSAlert()
        let when = version.lastModified?.s3ListString ?? version.versionID
        switch action {
        case .restore:
            alert.messageText = "Restore this version?"
            alert.informativeText = "\(item.displayName) from \(when) becomes the current version. "
                + "The version it replaces stays in the history."
            alert.addButton(withTitle: "Restore")
        case .delete:
            alert.alertStyle = .warning
            if version.isDeleteMarker {
                alert.messageText = "Remove this delete marker?"
                alert.informativeText = version.isLatest
                    ? "\(item.displayName) reappears with its most recent version."
                    : "This old marker is removed from the history."
            } else {
                alert.messageText = "Permanently delete this version?"
                alert.informativeText = "The \(when) version of \(item.displayName) is removed for good. "
                    + "This cannot be undone."
            }
            alert.addButton(withTitle: version.isDeleteMarker ? "Remove Marker" : "Delete Version")
            alert.buttons.first?.hasDestructiveAction = !version.isDeleteMarker
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.model.apply(action, to: version, of: item) }
        }
    }

    private func tabDisplayName(_ id: String) -> String {
        tabs.first(where: { $0.id == id })?.title.lowercased() ?? id
    }

    // MARK: - Task actions

    private var selectedTask: TransferTask? {
        selectedTasks.first
    }

    private var selectedTasks: [TransferTask] {
        tasksTable.selectedRowIndexes.compactMap { row in
            guard visibleTasks.indices.contains(row) else { return nil }
            return visibleTasks[row]
        }
    }

    @objc private func stopSelected() {
        for task in selectedTasks { model.transfers.stop(id: task.id) }
    }

    @objc private func cancelSelected() {
        for task in selectedTasks { model.transfers.cancel(id: task.id) }
    }

    @objc private func retrySelected() {
        guard let task = selectedTask else { return }
        model.transfers.retry(id: task.id)
    }

    @objc private func openTaskLocation() {
        guard let task = selectedTask else { return }
        guard task.direction != .copy else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([task.localURL])
    }

    @objc private func clearFinished() {
        model.transfers.clearFinished()
    }

    private func taskMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Stop Selected Task(s)", action: #selector(stopSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Cancel Selected Task(s)", action: #selector(cancelSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Retry Selected Task(s)", action: #selector(retrySelected), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Containing Folder…", action: #selector(openTaskLocation), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Finished", action: #selector(clearFinished), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}

extension TransfersViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleTasks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < visibleTasks.count else { return nil }
        let task = visibleTasks[row]
        let selected = tableView.selectedRowIndexes.contains(row)

        switch column.identifier.rawValue {
        case "task":
            let identifier = NSUserInterfaceItemIdentifier("taskcell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TransferCellView) ?? {
                let cell = TransferCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.configure(task: task, selected: selected)
            return cell

        case "size":
            let cell = textCell(tableView, id: "tasksize", alignment: .left)
            cell.textField?.stringValue = task.size.byteString
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
            return cell

        case "percent":
            let cell = textCell(tableView, id: "taskpercent", alignment: .right)
            cell.textField?.stringValue = String(format: "%.2f %%", task.progress * 100)
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : Theme.Colors.text
            return cell

        case "progress":
            let identifier = NSUserInterfaceItemIdentifier("taskprogress")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TransferProgressCell) ?? {
                let cell = TransferProgressCell()
                cell.identifier = identifier
                return cell
            }()
            cell.bar.progress = task.progress
            return cell

        case "status":
            let cell = textCell(tableView, id: "taskstatus")
            cell.textField?.stringValue = task.status.rawValue
            let color: NSColor
            switch task.status {
            case .failed: color = Theme.Colors.warning
            case .completed: color = Theme.Colors.success
            case .paused, .canceled: color = Theme.Colors.tertiaryText
            default: color = Theme.Colors.secondaryText
            }
            cell.textField?.textColor = selected ? Theme.Colors.selectionText : color
            return cell

        case "speed":
            let cell = textCell(tableView, id: "taskspeed", alignment: .right)
            cell.textField?.stringValue = task.status == .running ? task.speed.rateString : "—"
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
        field.font = Theme.Font.small
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
}
