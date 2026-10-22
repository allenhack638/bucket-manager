import AppKit

final class LogsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let logs: LogStore
    private let metrics: RequestMetricsStore
    private let segments = NSSegmentedControl(labels: ["Logs", "Statistics", "Settings"], trackingMode: .selectOne, target: nil, action: nil)
    private let container = NSView()

    private let logsView = NSView()
    private let statsView = NSView()
    private let settingsView = NSView()

    private let searchField = NSSearchField()
    private let levelPopup = NSPopUpButton()
    private let categoryPopup = NSPopUpButton()
    private let accountPopup = NSPopUpButton()
    private let liveSwitch = NSButton(checkboxWithTitle: "Live", target: nil, action: nil)
    private let logsTable = NSTableView()
    private let logsCountLabel = NSTextField(labelWithString: "")
    private let logDetail = InfoTextView()

    private let statsAccountPopup = NSPopUpButton()
    private let statsRangePopup = NSPopUpButton()
    private let statsTable = NSTableView()
    private let statsSummaryLabel = NSTextField(labelWithString: "")

    private let diagnosticsSwitch = NSButton(checkboxWithTitle: "Enable diagnostic request and UI logging", target: nil, action: nil)
    private let settingsLevelPopup = NSPopUpButton()
    private let diagnosticRetentionPopup = NSPopUpButton()
    private let auditRetentionPopup = NSPopUpButton()
    private let includeKeysSwitch = NSButton(checkboxWithTitle: "Include object keys in logs", target: nil, action: nil)
    private let includePathsSwitch = NSButton(checkboxWithTitle: "Include full local paths", target: nil, action: nil)
    private let settingsStatusLabel = NSTextField(labelWithString: "")
    private var categorySwitches: [(LogCategory, NSButton)] = []

    private var loadedLogs: [LogRecord] = []
    private var visibleLogs: [LogRecord] = []
    private var allMetricRows: [RequestMetric] = []
    private var metricRows: [RequestMetric] = []
    private var refreshTimer: Timer?
    private var logColumnsBuilt = false
    private var statsColumnsBuilt = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    init(
        logStore: LogStore = .shared,
        metricsStore: RequestMetricsStore = .shared
    ) {
        self.logs = logStore
        self.metrics = metricsStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Logs & Statistics"
        window.minSize = NSSize(width: 820, height: 480)
        super.init(window: window)
        build()
        reloadLogs()
        reloadStats()
        loadSettings()
        startTimer()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let content = window.contentView as? ThemedView ?? ThemedView(frame: .zero)
        window.contentView = content
        content.themeColor = Theme.Colors.window

        segments.target = self
        segments.action = #selector(tabChanged)
        segments.selectedSegment = 0
        segments.translatesAutoresizingMaskIntoConstraints = false
        segments.setAccessibilityLabel("Logs sections")
        content.addSubview(segments)

        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)

        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            segments.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            segments.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            container.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        buildLogsView()
        buildStatsView()
        buildSettingsView()
        for view in [logsView, statsView, settingsView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            view.pinEdges(to: container)
        }
        statsView.isHidden = true
        settingsView.isHidden = true
    }

    // MARK: - Logs

    private func buildLogsView() {
        let filterBar = NSStackView()
        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.alignment = .centerY
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search logs"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        searchField.setAccessibilityLabel("Search logs")

        levelPopup.addItem(withTitle: "All levels")
        levelPopup.addItem(withTitle: "Trace+")
        levelPopup.addItem(withTitle: "Debug+")
        levelPopup.addItem(withTitle: "Info+")
        levelPopup.addItem(withTitle: "Warning+")
        levelPopup.addItem(withTitle: "Error+")
        levelPopup.target = self
        levelPopup.action = #selector(filtersChanged)
        levelPopup.setAccessibilityLabel("Minimum log level")

        categoryPopup.addItem(withTitle: "All categories")
        categoryPopup.addItem(withTitle: "Audit only")
        categoryPopup.lastItem?.representedObject = "audit"
        for category in LogCategory.allCases where category != .audit {
            categoryPopup.addItem(withTitle: category.title)
            categoryPopup.lastItem?.representedObject = category.rawValue
        }
        categoryPopup.target = self
        categoryPopup.action = #selector(filtersChanged)
        categoryPopup.setAccessibilityLabel("Log category")

        accountPopup.addItem(withTitle: "All accounts")
        accountPopup.target = self
        accountPopup.action = #selector(filtersChanged)
        accountPopup.setAccessibilityLabel("Log account")

        liveSwitch.state = .on
        liveSwitch.target = self
        liveSwitch.action = #selector(liveChanged)
        liveSwitch.setAccessibilityLabel("Live log refresh")

        let refresh = FlatButton("Refresh", icon: "arrow.clockwise", style: .action)
        refresh.onClick = { [weak self] in self?.reloadLogs() }
        refresh.setAccessibilityLabel("Refresh logs")

        for view in [searchField, levelPopup, categoryPopup, accountPopup, liveSwitch, refresh] {
            filterBar.addArrangedSubview(view)
        }
        filterBar.setHuggingPriority(.defaultLow, for: .horizontal)
        logsView.addSubview(filterBar)

        configureLogTable()
        let scroll = NSScrollView()
        scroll.documentView = logsTable
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Log records")
        logsView.addSubview(scroll)

        let detailTitle = NSTextField(labelWithString: "Details")
        detailTitle.font = Theme.Font.section
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        logsView.addSubview(detailTitle)
        logDetail.translatesAutoresizingMaskIntoConstraints = false
        logDetail.setPlaceholder("Select a log record to inspect it.")
        logsView.addSubview(logDetail)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        logsCountLabel.font = Theme.Font.small
        logsCountLabel.textColor = Theme.Colors.secondaryText
        logsCountLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(logsCountLabel)
        let reveal = FlatButton("Reveal", icon: "folder", style: .action)
        reveal.onClick = { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting([self?.logs.directory() ?? LogStore.defaultDirectoryURL])
        }
        let clear = FlatButton("Clear Diagnostics", icon: "trash", style: .action)
        clear.onClick = { [weak self] in self?.clearLogs() }
        let export = FlatButton("Export", icon: "square.and.arrow.up", style: .action)
        export.onClick = { [weak self] in self?.exportLogs() }
        footer.addArrangedSubview(reveal)
        footer.addArrangedSubview(clear)
        footer.addArrangedSubview(export)
        logsView.addSubview(footer)

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: logsView.topAnchor, constant: 6),
            filterBar.leadingAnchor.constraint(equalTo: logsView.leadingAnchor, constant: 14),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: logsView.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: logsView.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: logsView.trailingAnchor, constant: -14),
            detailTitle.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            detailTitle.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            logDetail.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 4),
            logDetail.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            logDetail.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            logDetail.heightAnchor.constraint(equalToConstant: 120),
            footer.topAnchor.constraint(equalTo: logDetail.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: logsView.bottomAnchor, constant: -8)
        ])
    }

    private func configureLogTable() {
        guard !logColumnsBuilt else { return }
        logColumnsBuilt = true
        let columns: [(String, String, CGFloat)] = [
            ("time", "Time", 106),
            ("level", "Level", 58),
            ("category", "Category", 78),
            ("account", "Account", 105),
            ("operation", "Operation", 110),
            ("location", "Bucket / Key", 190),
            ("outcome", "Status", 64),
            ("message", "Message", 300)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 40
            logsTable.addTableColumn(column)
        }
        logsTable.headerView = NSTableHeaderView()
        logsTable.rowHeight = 20
        logsTable.usesAlternatingRowBackgroundColors = true
        logsTable.delegate = self
        logsTable.dataSource = self
        logsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        logsTable.setAccessibilityLabel("Log records")
    }

    @objc private func filtersChanged() {
        applyLogFilters()
    }

    @objc private func liveChanged() {
        if liveSwitch.state == .on { reloadLogs() }
    }

    private func reloadLogs() {
        loadedLogs = logs.recent(limit: 20_000)
        rebuildAccountPopup()
        applyLogFilters()
    }

    private func rebuildAccountPopup() {
        let selected = accountPopup.selectedItem?.representedObject as? String
        var seen: [String: UUID] = [:]
        for record in loadedLogs {
            guard let id = record.accountID, let name = record.accountName else { continue }
            seen[name] = id
        }
        accountPopup.removeAllItems()
        accountPopup.addItem(withTitle: "All accounts")
        for name in seen.keys.sorted() {
            accountPopup.addItem(withTitle: name)
            accountPopup.lastItem?.representedObject = seen[name]?.uuidString
        }
        if let selected,
           let index = accountPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            accountPopup.selectItem(at: index)
        }
    }

    private func applyLogFilters() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minimumLevel = logLevelFilter()
        let category = categoryPopup.selectedItem?.representedObject as? String
        let account = accountPopup.selectedItem?.representedObject as? String
        visibleLogs = loadedLogs.filter { record in
            if let minimumLevel, record.level < minimumLevel { return false }
            if category == "audit", record.category != .audit { return false }
            if let category, category != "audit", record.category.rawValue != category { return false }
            if let account, record.accountID?.uuidString != account { return false }
            guard !query.isEmpty else { return true }
            let haystack = [
                record.message, record.event, record.operation ?? "", record.bucket ?? "",
                record.key ?? "", record.accountName ?? "", record.category.title
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
        logsTable.reloadData()
        logsCountLabel.stringValue = "\(visibleLogs.count) of \(loadedLogs.count) records"
        if visibleLogs.isEmpty {
            logDetail.setPlaceholder("No log records match the current filters.")
        }
    }

    private func logLevelFilter() -> LogLevel? {
        switch levelPopup.indexOfSelectedItem {
        case 1: return .trace
        case 2: return .debug
        case 3: return .info
        case 4: return .warning
        case 5: return .error
        default: return nil
        }
    }

    private func clearLogs() {
        let alert = NSAlert()
        alert.messageText = "Clear diagnostic logs?"
        alert.informativeText = "Audit records are retained. This action is itself audited."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            logs.clearDiagnostics()
            logs.audit(event: "logs.cleared", message: "Diagnostic logs cleared from the UI")
            reloadLogs()
        }
    }

    private func exportLogs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bucket-manager-logs.jsonl"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = self.visibleLogs.compactMap { try? encoder.encode($0) }
                .reduce(into: Data()) { result, line in
                    result.append(line)
                    result.append(0x0A)
                }
            try? data.write(to: url, options: .atomic)
            self.logs.audit(
                event: "logs.exported",
                message: "Log records exported",
                outcome: "success",
                metadata: ["records": String(self.visibleLogs.count)]
            )
        }
    }

    // MARK: - Statistics

    private func buildStatsView() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false

        statsAccountPopup.addItem(withTitle: "All accounts")
        statsAccountPopup.target = self
        statsAccountPopup.action = #selector(statsFiltersChanged)
        statsAccountPopup.setAccessibilityLabel("Statistics account")

        statsRangePopup.addItem(withTitle: "Session")
        statsRangePopup.addItem(withTitle: "All time")
        statsRangePopup.target = self
        statsRangePopup.action = #selector(statsFiltersChanged)
        statsRangePopup.setAccessibilityLabel("Statistics time range")

        let refresh = FlatButton("Refresh", icon: "arrow.clockwise", style: .action)
        refresh.onClick = { [weak self] in self?.reloadStats() }
        let clear = FlatButton("Clear Statistics", icon: "trash", style: .action)
        clear.onClick = { [weak self] in self?.clearStats() }
        for view in [statsAccountPopup, statsRangePopup, refresh, clear] {
            bar.addArrangedSubview(view)
        }
        statsView.addSubview(bar)

        configureStatsTable()
        let scroll = NSScrollView()
        scroll.documentView = statsTable
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Request statistics")
        statsView.addSubview(scroll)

        statsSummaryLabel.font = Theme.Font.small
        statsSummaryLabel.textColor = Theme.Colors.secondaryText
        statsSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        statsView.addSubview(statsSummaryLabel)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: statsView.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: statsView.leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: statsView.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: statsView.trailingAnchor, constant: -14),
            statsSummaryLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statsSummaryLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statsSummaryLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statsSummaryLabel.bottomAnchor.constraint(equalTo: statsView.bottomAnchor, constant: -8)
        ])
    }

    private func configureStatsTable() {
        guard !statsColumnsBuilt else { return }
        statsColumnsBuilt = true
        let columns: [(String, String, CGFloat)] = [
            ("account", "Account", 150),
            ("bucket", "Bucket", 180),
            ("operation", "Operation", 180),
            ("requests", "Requests", 90),
            ("errors", "Errors", 70),
            ("average", "Avg ms", 80),
            ("bytes", "Bytes", 100),
            ("last", "Last Used", 130)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 50
            statsTable.addTableColumn(column)
        }
        statsTable.headerView = NSTableHeaderView()
        statsTable.rowHeight = 20
        statsTable.usesAlternatingRowBackgroundColors = true
        statsTable.delegate = self
        statsTable.dataSource = self
        statsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        statsTable.setAccessibilityLabel("Request statistics")
    }

    private func reloadStats() {
        allMetricRows = metrics.snapshot()
        let selectedAccount = statsAccountPopup.selectedItem?.representedObject as? String
        var names: [String: UUID] = [:]
        for metric in allMetricRows { names[metric.accountName] = metric.accountID }
        statsAccountPopup.removeAllItems()
        statsAccountPopup.addItem(withTitle: "All accounts")
        for name in names.keys.sorted() {
            statsAccountPopup.addItem(withTitle: name)
            statsAccountPopup.lastItem?.representedObject = names[name]?.uuidString
        }
        if let selectedAccount,
           let index = statsAccountPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedAccount }) {
            statsAccountPopup.selectItem(at: index)
        }
        applyStatsFilters()
    }

    @objc private func statsFiltersChanged() {
        applyStatsFilters()
    }

    private func applyStatsFilters() {
        let account = statsAccountPopup.selectedItem?.representedObject as? String
        let sessionOnly = statsRangePopup.indexOfSelectedItem == 0
        let filtered = allMetricRows.filter { metric in
            if let account, metric.accountID.uuidString != account { return false }
            return !sessionOnly || metric.sessionCount > 0
        }
        metricRows = filtered
        statsTable.reloadData()
        let total = filtered.reduce(0) { $0 + ($1.sessionCount > 0 ? $1.sessionCount : $1.count) }
        let list = filtered.filter { $0.operation == "ListObjectsV2" }
            .reduce(0) { $0 + ($1.sessionCount > 0 ? $1.sessionCount : $1.count) }
        let errors = filtered.reduce(0) { $0 + $1.failures }
        let bytes = filtered.reduce(0) { $0 + $1.bytes }
        statsSummaryLabel.stringValue =
            "\(total) requests · \(list) list requests · \(errors) errors · \(bytes.byteString) transferred"
    }

    private func clearStats() {
        let alert = NSAlert()
        alert.messageText = "Clear request statistics?"
        alert.informativeText = "This resets the counters. Audit records are retained."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            metrics.clear()
            LogStore.shared.audit(event: "metrics.cleared", message: "Request statistics cleared")
            reloadStats()
        }
    }

    // MARK: - Settings

    private func buildSettingsView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsView.addSubview(stack)

        let heading = NSTextField(labelWithString: "Logging")
        heading.font = Theme.Font.section
        stack.addArrangedSubview(heading)
        diagnosticsSwitch.target = self
        diagnosticsSwitch.action = #selector(settingsEdited)
        stack.addArrangedSubview(diagnosticsSwitch)

        let levelRow = row("Minimum level:", settingsLevelPopup)
        for level in LogLevel.allCases {
            settingsLevelPopup.addItem(withTitle: level.title)
            settingsLevelPopup.lastItem?.representedObject = level.rawValue
        }
        stack.addArrangedSubview(levelRow)

        let categoriesTitle = NSTextField(labelWithString: "Diagnostic categories")
        categoriesTitle.font = Theme.Font.bodyMedium
        stack.addArrangedSubview(categoriesTitle)
        for category in LogCategory.allCases where category != .audit {
            let button = NSButton(checkboxWithTitle: category.title, target: self, action: #selector(settingsEdited))
            categorySwitches.append((category, button))
            stack.addArrangedSubview(button)
        }

        let retentionRow = NSStackView()
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 10
        retentionRow.addArrangedSubview(NSTextField(labelWithString: "Diagnostics:"))
        for days in [7, 14, 30, 60] {
            diagnosticRetentionPopup.addItem(withTitle: "\(days) days")
            diagnosticRetentionPopup.lastItem?.representedObject = days
        }
        retentionRow.addArrangedSubview(diagnosticRetentionPopup)
        retentionRow.addArrangedSubview(NSTextField(labelWithString: "Audit:"))
        for days in [30, 90, 180, 365] {
            auditRetentionPopup.addItem(withTitle: "\(days) days")
            auditRetentionPopup.lastItem?.representedObject = days
        }
        retentionRow.addArrangedSubview(auditRetentionPopup)
        stack.addArrangedSubview(retentionRow)

        includeKeysSwitch.target = self
        includeKeysSwitch.action = #selector(settingsEdited)
        stack.addArrangedSubview(includeKeysSwitch)
        includePathsSwitch.target = self
        includePathsSwitch.action = #selector(settingsEdited)
        stack.addArrangedSubview(includePathsSwitch)

        let note = NSTextField(wrappingLabelWithString: "Audit logging is always on. Credentials, authorization headers, and signatures are never logged. Diagnostic logging is off by default.")
        note.font = Theme.Font.small
        note.textColor = Theme.Colors.secondaryText
        note.maximumNumberOfLines = 0
        stack.addArrangedSubview(note)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let save = FlatButton("Save Logging Settings", style: .primary)
        save.onClick = { [weak self] in self?.saveSettings() }
        let reveal = FlatButton("Reveal Logs", icon: "folder", style: .action)
        reveal.onClick = { NSWorkspace.shared.activateFileViewerSelecting([LogStore.defaultDirectoryURL]) }
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(reveal)
        stack.addArrangedSubview(buttons)

        settingsStatusLabel.font = Theme.Font.small
        settingsStatusLabel.textColor = Theme.Colors.secondaryText
        stack.addArrangedSubview(settingsStatusLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: settingsView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: settingsView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: settingsView.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: settingsView.bottomAnchor, constant: -14)
        ])
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Font.body
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func loadSettings() {
        let settings = logs.currentSettings()
        diagnosticsSwitch.state = settings.diagnosticsEnabled ? .on : .off
        if let index = settingsLevelPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == settings.minimumLevel.rawValue
        }) {
            settingsLevelPopup.selectItem(at: index)
        }
        for (category, button) in categorySwitches {
            button.state = settings.enabledCategories.contains(category) ? .on : .off
        }
        if let index = diagnosticRetentionPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == settings.diagnosticRetentionDays
        }) {
            diagnosticRetentionPopup.selectItem(at: index)
        }
        if let index = auditRetentionPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? Int) == settings.auditRetentionDays
        }) {
            auditRetentionPopup.selectItem(at: index)
        }
        includeKeysSwitch.state = settings.includeObjectKeys ? .on : .off
        includePathsSwitch.state = settings.includeLocalPaths ? .on : .off
    }

    private func saveSettings() {
        var settings = logs.currentSettings()
        settings.diagnosticsEnabled = diagnosticsSwitch.state == .on
        if let raw = settingsLevelPopup.selectedItem?.representedObject as? Int,
           let level = LogLevel(rawValue: raw) {
            settings.minimumLevel = level
        }
        settings.enabledCategories = Set(categorySwitches.compactMap {
            $0.1.state == .on ? $0.0 : nil
        })
        if let days = diagnosticRetentionPopup.selectedItem?.representedObject as? Int {
            settings.diagnosticRetentionDays = days
        }
        if let days = auditRetentionPopup.selectedItem?.representedObject as? Int {
            settings.auditRetentionDays = days
        }
        settings.auditEnabled = true
        settings.includeObjectKeys = includeKeysSwitch.state == .on
        settings.includeLocalPaths = includePathsSwitch.state == .on
        logs.updateSettings(settings)
        settingsStatusLabel.stringValue = "Saved. Audit logging remains enabled."
    }

    @objc private func settingsEdited() {
        settingsStatusLabel.stringValue = "Unsaved changes."
    }

    // MARK: - Tabs and refresh

    @objc private func tabChanged() {
        let index = segments.selectedSegment
        logsView.isHidden = index != 0
        statsView.isHidden = index != 1
        settingsView.isHidden = index != 2
        if index == 0 { reloadLogs() }
        if index == 1 { reloadStats() }
        if index == 2 { loadSettings() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startTimer()
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTick() }
        }
    }

    private func refreshTick() {
        guard window?.isVisible == true else { return }
        if !logsView.isHidden, liveSwitch.state == .on { reloadLogs() }
        if !statsView.isHidden { reloadStats() }
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === logsTable ? visibleLogs.count : metricRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === logsTable {
            guard row < visibleLogs.count else { return nil }
            let record = visibleLogs[row]
            let value: String
            switch tableColumn.identifier.rawValue {
            case "time": value = Self.timeFormatter.string(from: record.timestamp)
            case "level": value = record.level.title
            case "category": value = record.category.title
            case "account": value = record.accountName ?? "—"
            case "operation": value = record.operation ?? record.event
            case "location": value = [record.bucket, record.key].compactMap { $0 }.joined(separator: " / ")
            case "outcome": value = record.outcome ?? "—"
            default: value = record.message
            }
            let cell = cellView(tableView, identifier: "logcell", value: value)
            cell.textField?.textColor = color(for: record.level)
            return cell
        }
        guard row < metricRows.count else { return nil }
        let metric = metricRows[row]
        let sessionOnly = statsRangePopup.indexOfSelectedItem == 0
        let count = sessionOnly ? metric.sessionCount : metric.count
        let value: String
        switch tableColumn.identifier.rawValue {
        case "account": value = metric.accountName
        case "bucket": value = metric.bucket.isEmpty ? "—" : metric.bucket
        case "operation": value = metric.operation
        case "requests": value = "\(count)"
        case "errors": value = "\(metric.failures)"
        case "average": value = String(format: "%.1f", metric.averageDurationMs)
        case "bytes": value = metric.bytes.byteString
        default: value = Self.timeFormatter.string(from: metric.lastAt)
        }
        return cellView(tableView, identifier: "statcell", value: value)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === logsTable else { return }
        let row = logsTable.selectedRow
        guard row >= 0, row < visibleLogs.count else {
            logDetail.setPlaceholder("Select a log record to inspect it.")
            return
        }
        let record = visibleLogs[row]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record),
           let text = String(data: data, encoding: .utf8) {
            logDetail.setText(text)
        }
    }

    private func cellView(_ tableView: NSTableView, identifier: String, value: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView,
           let field = cell.textField {
            field.stringValue = value
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: value)
        field.font = Theme.Font.tiny
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func color(for level: LogLevel) -> NSColor {
        switch level {
        case .error, .critical: return Theme.Colors.warning
        case .warning: return NSColor.systemOrange
        case .notice: return Theme.Colors.accent
        case .debug, .trace: return Theme.Colors.secondaryText
        default: return Theme.Colors.text
        }
    }

    // MARK: - Test hooks

    func reloadForTesting() {
        reloadLogs()
        reloadStats()
    }

    func selectTabForTesting(_ index: Int) {
        segments.selectedSegment = index
        tabChanged()
    }

    func testSetSearch(_ text: String) {
        searchField.stringValue = text
        applyLogFilters()
    }

    var testVisibleLogCount: Int { visibleLogs.count }
    var testMetricRowCount: Int { metricRows.count }
}

extension LogsWindowController {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        applyLogFilters()
    }
}

extension LogsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
