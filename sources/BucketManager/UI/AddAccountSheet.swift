import AppKit

@MainActor
final class AddAccountWindowController: NSWindowController, NSWindowDelegate {
    /// The same width everywhere; the height fits the fields shown for the
    /// chosen account type, so nothing is ever hidden below the fold.
    static let contentSize = NSSize(width: 620, height: 580)
    private static let chromeHeight: CGFloat = 72 + 8 + 8 + 16 + 8 + 30 + 16
    private static let minimumHeight: CGFloat = 420

    private let existing: Account?
    private let existingSecret: String?
    private let onSave: (Account, String?) -> Void
    private let onCancel: () -> Void
    private weak var parentWindow: NSWindow?

    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let accessField = NSTextField()
    private let secretField = NSSecureTextField()
    private let regionField = NSTextField(string: "us-east-1")
    private let endpointField = NSTextField()
    private let bucketField = NSTextField()
    private let sslCheck = NSButton(checkboxWithTitle: "Use secure transfer (SSL/TLS)", target: nil, action: nil)
    private let pathStyleCheck = NSButton(checkboxWithTitle: "Use path-style addressing", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let testLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private let formStack = NSStackView()
    private var formScroll: NSScrollView?
    private var endpointRow: NSView?
    private var endpointHelpRow: NSView?
    private var bucketRow: NSView?
    private var bucketHelpRow: NSView?
    private var pathStyleRow: NSView?
    private var keyMonitor: Any?

    private let labelWidth: CGFloat = 130
    private let formInset: CGFloat = 24

    init(
        account: Account?,
        secret: String?,
        onSave: @escaping (Account, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = account
        self.existingSecret = secret
        self.onSave = onSave
        self.onCancel = onCancel
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = account == nil ? "Add New Account" : "Edit Account"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        populate()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        parentWindow = parent
        guard let window else { return }
        fitToContent(animate: false, parent: parent)
        parent.beginSheet(window)
        window.makeKey()
        window.makeFirstResponder(existing == nil ? nameField : accessField)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if window.firstResponder is NSTextView { return event }
                self.save()
                return nil
            }
            return event
        }
    }

    private func build() {
        guard let window else { return }
        let root = ThemedView()
        root.themeColor = Theme.Colors.content

        let header = buildHeader()
        let scroll = buildScroll()
        let buttons = buildButtons()

        errorLabel.font = Theme.Font.small
        errorLabel.textColor = Theme.Colors.warning
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.lineBreakMode = .byTruncatingTail

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(errorLabel)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 72),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: formInset),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -formInset),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),

            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: formInset),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -formInset),
            errorLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            errorLabel.heightAnchor.constraint(equalToConstant: 16),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: formInset),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -formInset),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])

        window.contentView = root
        typePopup.target = self
        typePopup.action = #selector(typeChanged)
        updateVisibility()
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = Labels.label(existing == nil ? "Add New Account" : "Edit Account", font: .systemFont(ofSize: 20, weight: .semibold))
        let subtitle = Labels.label(
            "Enter the account details and click \(existing == nil ? "Add new account" : "Save changes").",
            font: Theme.Font.body,
            color: Theme.Colors.secondaryText
        )
        let headerText = NSStackView(views: [title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        headerText.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(icon)
        header.addSubview(headerText)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: formInset),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.Metrics.brandIconSize),
            icon.heightAnchor.constraint(equalToConstant: Theme.Metrics.brandIconSize),
            headerText.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            headerText.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -formInset)
        ])
        return header
    }

    private func buildScroll() -> NSScrollView {
        configureFields()

        let scroll = NSScrollView()
        formScroll = scroll
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 8
        formStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(formStack)

        let rows: [(NSView, String?)] = [
            (formRow("Display name:", nameField), "Assign any name to your account."),
            (formRow("Account type:", typePopup), "Choose the storage you want to work with. Default is Amazon S3 Storage."),
            (formRow("Access Key ID:", accessField), "Required to sign the requests you send to your storage."),
            (formRow("Secret Access Key:", secretField), existing == nil
                ? "Stored in the macOS Keychain, never in the app's JSON file."
                : "Leave blank to keep the current secret in the Keychain."),
            (formRow("Region:", regionField), "For example us-east-1. Must match the bucket's region.")
        ]
        for (row, help) in rows {
            addRow(row, help: help)
        }

        let endpoint = formRow("Custom endpoint:", endpointField)
        let endpointHelp = helpRow("For MinIO, Wasabi, Cloudflare R2, Backblaze B2 and other S3-compatible services. HTTPS is required for remote hosts; plain HTTP is limited to local/private networks.")
        endpointRow = endpoint
        endpointHelpRow = endpointHelp
        addRow(endpoint, help: nil)
        addRawRow(endpointHelp)

        let bucket = formRow("Bucket (optional):", bucketField)
        let bucketHelp = helpRow("Required for bucket-scoped keys, such as Backblaze B2 keys that cannot list all buckets.")
        bucketRow = bucket
        bucketHelpRow = bucketHelp
        addRow(bucket, help: nil)
        addRawRow(bucketHelp)

        let pathStyle = formRow("Addressing:", pathStyleCheck)
        pathStyleRow = pathStyle
        addRow(pathStyle, help: nil)
        addRow(formRow("", sslCheck), help: nil)

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            formStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            formStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            formStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        return scroll
    }

    private func addRow(_ row: NSView, help: String?) {
        formStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        formStack.setCustomSpacing(2, after: row)
        if let help {
            addRawRow(helpRow(help))
        } else {
            formStack.setCustomSpacing(10, after: row)
        }
    }

    private func addRawRow(_ row: NSView) {
        formStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        formStack.setCustomSpacing(10, after: row)
    }

    private func buildButtons() -> NSView {
        let buttons = NSView()
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let test = FlatButton("Test connection", style: .link) { [weak self] in self?.testConnection() }
        test.fontSize = 11
        test.accessibilityTitle = "Test connection"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        testLabel.font = Theme.Font.small
        testLabel.textColor = Theme.Colors.secondaryText
        testLabel.lineBreakMode = .byTruncatingTail
        testLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        testLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = FlatButton("Cancel", style: .action) { [weak self] in self?.cancel() }
        cancel.fontSize = 13
        cancel.accessibilityTitle = "Cancel"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let save = FlatButton(existing == nil ? "Add new account" : "Save changes", style: .primary) { [weak self] in self?.save() }
        save.fontSize = 13
        save.accessibilityTitle = existing == nil ? "Add new account" : "Save changes"
        save.translatesAutoresizingMaskIntoConstraints = false
        save.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let spacer = NSView()
        let row = NSStackView(views: [test, spinner, testLabel, spacer, cancel, save])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        buttons.addSubview(row)
        row.pinEdges(to: buttons)
        return buttons
    }

    private func configureFields() {
        for field in [nameField, accessField, regionField, endpointField, bucketField] {
            style(field)
        }
        style(secretField)

        nameField.placeholderString = "New Account"
        accessField.placeholderString = "Access Key ID"
        secretField.placeholderString = existing == nil ? "Secret access key" : "Leave blank to keep existing"
        endpointField.placeholderString = "https://s3.example.com"
        bucketField.placeholderString = "bucket-name (optional)"

        typePopup.addItems(withTitles: Account.Kind.allCases.map(\.displayName))
        typePopup.font = Theme.Font.field
        typePopup.translatesAutoresizingMaskIntoConstraints = false
        typePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        typePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        typePopup.setAccessibilityLabel("Account type")

        sslCheck.state = .on
        pathStyleCheck.state = .off
        sslCheck.font = Theme.Font.field
        pathStyleCheck.font = Theme.Font.field

        nameField.setAccessibilityLabel("Display name")
        accessField.setAccessibilityLabel("Access Key ID")
        secretField.setAccessibilityLabel("Secret Access Key")
        regionField.setAccessibilityLabel("Region")
        endpointField.setAccessibilityLabel("Custom endpoint")
        bucketField.setAccessibilityLabel("Bucket name")
        sslCheck.setAccessibilityLabel("Use secure transfer SSL TLS")
        pathStyleCheck.setAccessibilityLabel("Use path-style addressing")

        for field in [nameField, accessField, regionField, endpointField, bucketField, secretField] as [NSTextField] {
            field.target = self
            field.action = #selector(returnKey)
            // Only Return saves. Without this, clicking from one field to
            // another "ends editing" and saved the half-edited account.
            field.cell?.sendsActionOnEndEditing = false
        }

        // Keys, regions and URLs are not prose: no spelling, autocorrect,
        // completion or prediction popups, which can cover the next field.
        for field in Self.literalFields(of: self) {
            field.isAutomaticTextCompletionEnabled = false
        }
        // There is no supported way to remove the "Passwords…" AutoFill
        // button from a secure field; marking it as a one-time code stops
        // macOS treating Access Key + Secret as a website login.
        secretField.contentType = .oneTimeCode
    }

    private static func literalFields(of controller: AddAccountWindowController) -> [NSTextField] {
        [controller.nameField, controller.accessField, controller.secretField, controller.regionField,
         controller.endpointField, controller.bucketField]
    }

    /// Plain fields edit through a field editor with every automatic text
    /// feature off from the moment they take focus. The secret field keeps
    /// AppKit's own secure editor, which never offers suggestions.
    private lazy var literalEditor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        Self.makeLiteral(editor)
        return editor
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, !(field is NSSecureTextField),
              Self.literalFields(of: self).contains(where: { $0 === field }) else { return nil }
        return literalEditor
    }

    /// Turns off every automatic text feature that could change or pop up
    /// over a credential.
    static func makeLiteral(_ editor: NSTextView) {
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.inlinePredictionType = .no
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
    }

    private func style(_ field: NSTextField) {
        field.font = Theme.Font.field
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func formRow(_ label: String, _ control: NSView) -> NSStackView {
        let fieldLabel = Labels.label(label, font: Theme.Font.body, color: Theme.Colors.text)
        fieldLabel.alignment = .right
        fieldLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [fieldLabel, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    private func helpRow(_ text: String) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let label = Labels.wrapping(text, font: Theme.Font.small, color: Theme.Colors.secondaryText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let row = NSStackView(views: [spacer, label])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func populate() {
        guard let account = existing else { return }
        nameField.stringValue = account.displayName
        accessField.stringValue = account.accessKeyID
        regionField.stringValue = account.region
        endpointField.stringValue = account.endpoint ?? ""
        bucketField.stringValue = account.bucket ?? ""
        sslCheck.state = account.useSSL ? .on : .off
        pathStyleCheck.state = account.usePathStyle ? .on : .off
        if let index = Account.Kind.allCases.firstIndex(of: account.kind) {
            typePopup.selectItem(at: index)
        }
        updateVisibility()
    }

    @objc private func typeChanged() {
        updateVisibility()
        fitToContent(animate: window?.isVisible == true, parent: parentWindow)
    }

    /// Height of the window when every visible field shows without scrolling,
    /// capped so the sheet, hanging from the parent's title bar, never runs
    /// past the bottom of the screen and hides Save.
    func fittingContentHeight(parent: NSWindow?) -> CGFloat {
        guard let window, let document = formScroll?.documentView else { return Self.contentSize.height }
        window.setContentSize(NSSize(width: Self.contentSize.width, height: window.contentLayoutRect.height))
        window.contentView?.layoutSubtreeIfNeeded()
        let wanted = (Self.chromeHeight + document.fittingSize.height).rounded(.up)
        var available: CGFloat = 900
        if let parent, let screen = parent.screen ?? NSScreen.main {
            let sheetTop = min(parent.frame.maxY, screen.visibleFrame.maxY) - (parent.frame.height - parent.contentLayoutRect.height)
            available = sheetTop - screen.visibleFrame.minY - 12
        } else if let screen = NSScreen.main {
            available = screen.visibleFrame.height - 80
        }
        return max(Self.minimumHeight, min(wanted, available))
    }

    private func fitToContent(animate: Bool, parent: NSWindow?) {
        guard let window else { return }
        let height = fittingContentHeight(parent: parent)
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.contentSize.width, height: height)))
        // Keep the top edge where it is, as sheets hang from the title bar.
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: animate)
        // When the screen is too short for every field, show that the form scrolls.
        formScroll?.flashScrollers()
    }

    @objc private func returnKey() {
        save()
    }

    private func updateVisibility() {
        let compatible = selectedKind == .compatible
        endpointRow?.isHidden = !compatible
        endpointHelpRow?.isHidden = !compatible
        bucketRow?.isHidden = !compatible
        bucketHelpRow?.isHidden = !compatible
        pathStyleRow?.isHidden = !compatible
        formStack.needsLayout = true
    }

    private var selectedKind: Account.Kind {
        let index = typePopup.indexOfSelectedItem
        guard index >= 0, index < Account.Kind.allCases.count else { return .amazonS3 }
        return Account.Kind.allCases[index]
    }

    private func validate(requireSecret: Bool) -> Bool {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = accessField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return fail("Display name is required.") }
        if access.isEmpty { return fail("Access Key ID is required.") }
        if requireSecret && secret.isEmpty { return fail("Secret Access Key is required.") }
        if selectedKind == .compatible {
            let endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try EndpointValidator.normalized(endpoint, useSSL: sslCheck.state == .on)
            } catch {
                return fail(error.localizedDescription)
            }
            let bucket = bucketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if bucket.contains("/") {
                return fail("Bucket name must not contain /.")
            }
        }
        errorLabel.stringValue = ""
        return true
    }

    private func fail(_ message: String) -> Bool {
        errorLabel.stringValue = message
        return false
    }

    private func buildAccount() -> Account {
        let endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var account = existing ?? Account(displayName: "", accessKeyID: "")
        account.displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        account.accessKeyID = accessField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        account.kind = selectedKind
        account.region = regionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        account.endpoint = selectedKind == .compatible ? endpoint : nil
        let bucket = bucketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        account.bucket = selectedKind == .compatible && !bucket.isEmpty ? bucket : nil
        account.useSSL = sslCheck.state == .on
        account.usePathStyle = pathStyleCheck.state == .on
        return account
    }

    private func testConnection() {
        guard validate(requireSecret: existing == nil) else { return }
        let account = buildAccount()
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let testSecret = secret.isEmpty ? (existingSecret ?? "") : secret
        guard !testSecret.isEmpty else {
            _ = fail("Enter the secret access key to test the connection.")
            return
        }

        spinner.startAnimation(nil)
        testLabel.stringValue = "Testing connection…"
        testLabel.textColor = Theme.Colors.secondaryText

        Task {
            do {
                if let bucket = account.bucket?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bucket.isEmpty {
                    let page = try await S3Service.shared.list(
                        account: account, secret: testSecret, bucket: bucket,
                        prefix: "", useCache: false
                    )
                    spinner.stopAnimation(nil)
                    testLabel.stringValue = "Connected — bucket \(bucket) visible (\(page.items.count) items)."
                } else {
                    let buckets = try await S3Service.shared.listBuckets(
                        account: account, secret: testSecret, useCache: false
                    )
                    spinner.stopAnimation(nil)
                    testLabel.stringValue = "Connected — \(buckets.count) bucket\(buckets.count == 1 ? "" : "s") visible."
                }
                testLabel.textColor = Theme.Colors.success
            } catch {
                spinner.stopAnimation(nil)
                testLabel.stringValue = S3ErrorPresenter.message(for: error)
                testLabel.textColor = Theme.Colors.warning
            }
        }
    }

    private func save() {
        guard validate(requireSecret: existing == nil) else { return }
        let account = buildAccount()
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(account, secret.isEmpty ? nil : secret)
        dismiss()
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    #if DEBUG
    func testFill(
        name: String,
        access: String,
        secret: String,
        region: String,
        endpoint: String,
        kind: Account.Kind,
        bucket: String = ""
    ) {
        nameField.stringValue = name
        accessField.stringValue = access
        secretField.stringValue = secret
        regionField.stringValue = region
        endpointField.stringValue = endpoint
        bucketField.stringValue = bucket
        if let index = Account.Kind.allCases.firstIndex(of: kind) {
            typePopup.selectItem(at: index)
        }
        updateVisibility()
    }

    func testSave() { save() }
    func testField(_ index: Int) -> NSTextField { [nameField, accessField, regionField, secretField][index] }
    func testSelectKind(_ kind: Account.Kind) {
        if let index = Account.Kind.allCases.firstIndex(of: kind) { typePopup.selectItem(at: index) }
        typeChanged()
    }
    /// Whether every visible field fits in the window without scrolling.
    var testFormFitsWithoutScrolling: Bool {
        guard let scroll = formScroll, let document = scroll.documentView else { return false }
        window?.contentView?.layoutSubtreeIfNeeded()
        return document.fittingSize.height <= scroll.contentView.bounds.height + 0.5
    }
    var testLiteralFieldsHaveNoTextHelpers: Bool {
        guard let window else { return false }
        let plainFields = Self.literalFields(of: self).filter { !($0 is NSSecureTextField) }
        return Self.literalFields(of: self).allSatisfy { !$0.isAutomaticTextCompletionEnabled }
            && plainFields.allSatisfy { (windowWillReturnFieldEditor(window, to: $0) as? NSTextView) === literalEditor }
            && windowWillReturnFieldEditor(window, to: secretField) == nil
            && !literalEditor.isContinuousSpellCheckingEnabled && literalEditor.inlinePredictionType == .no
            && secretField.contentType == .oneTimeCode
    }
    func testCancel() { cancel() }
    var testErrorText: String { errorLabel.stringValue }
    var testEndpointControlsVisible: Bool {
        endpointRow?.isHidden == false
            && endpointHelpRow?.isHidden == false
            && pathStyleRow?.isHidden == false
    }
    var testBucketControlVisible: Bool {
        bucketRow?.isHidden == false && bucketHelpRow?.isHidden == false
    }
    #endif

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard let window else { return }
        if let parentWindow {
            parentWindow.endSheet(window)
        } else {
            window.close()
        }
        window.orderOut(nil)
    }
}

@MainActor
final class StorageAccountsWindowController: NSWindowController, NSWindowDelegate {
    private let accounts: AccountStore
    private let model: BrowserModel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = Labels.label("No accounts yet. Click Add to create one.", font: Theme.Font.body, color: Theme.Colors.secondaryText)
    private var nameColumn: NSTableColumn?
    private var typeColumn: NSTableColumn?
    private weak var parentWindow: NSWindow?
    /// Add and Edit open the same account sheet as the sidebar, on the main
    /// window, so it looks and behaves the same from everywhere. The main
    /// window closes this sheet first and reopens it afterwards.
    var onEditAccount: ((Account?) -> Void)?
    private var editButton: FlatButton?
    private var deleteButton: FlatButton?

    init(accounts: AccountStore, model: BrowserModel) {
        self.accounts = accounts
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Storage Accounts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        parentWindow = parent
        guard let window else { return }
        let parentRect = parent.contentLayoutRect
        let width = min(760, max(560, parentRect.width - 40))
        let height = min(460, max(340, parentRect.height - 60))
        window.setContentSize(NSSize(width: width, height: height))
        parent.beginSheet(window)
        window.contentView?.layoutSubtreeIfNeeded()
        reload()
    }

    private func build() {
        guard let window else { return }
        let root = ThemedView()
        root.themeColor = Theme.Colors.content

        let header = buildHeader()
        let footer = buildFooter()

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Account Name"
        nameColumn.width = 300
        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Account Type"
        typeColumn.width = 400
        table.addTableColumn(nameColumn)
        table.addTableColumn(typeColumn)
        self.nameColumn = nameColumn
        self.typeColumn = typeColumn
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.Colors.content
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editAccount)
        table.setAccessibilityLabel("Storage accounts")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.content
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 72),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 34)
        ])

        window.contentView = root
    }

    private func buildHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = Labels.label("Storage Accounts", font: .systemFont(ofSize: 20, weight: .semibold))
        let subtitle = Labels.label("View, add, edit and delete your storage accounts.", font: Theme.Font.body, color: Theme.Colors.secondaryText)
        let headerText = NSStackView(views: [title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        headerText.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(icon)
        header.addSubview(headerText)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Theme.Metrics.brandIconSize),
            icon.heightAnchor.constraint(equalToConstant: Theme.Metrics.brandIconSize),
            headerText.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            headerText.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -24)
        ])
        return header
    }

    private func buildFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let add = FlatButton("Add", icon: "plus", style: .action) { [weak self] in self?.addAccount() }
        let edit = FlatButton("Edit", style: .action) { [weak self] in self?.editAccount() }
        let delete = FlatButton("Delete", icon: "trash", style: .action) { [weak self] in self?.deleteAccount() }
        let more = FlatButton("More…", style: .action) { [weak self] in self?.showMore() }
        for button in [add, edit, delete, more] {
            button.fontSize = 12
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.accessibilityTitle = button.title
        }
        editButton = edit
        deleteButton = delete
        let left = NSStackView(views: [add, edit, delete, more])
        left.orientation = .horizontal
        left.spacing = 4

        let cancel = FlatButton("Cancel", style: .action) { [weak self] in self?.closeSheet() }
        let save = FlatButton("Save changes", style: .primary) { [weak self] in self?.closeSheet() }
        cancel.fontSize = 12
        save.fontSize = 12
        cancel.accessibilityTitle = "Cancel"
        save.accessibilityTitle = "Save changes"
        cancel.heightAnchor.constraint(equalToConstant: 30).isActive = true
        save.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let right = NSStackView(views: [cancel, save])
        right.orientation = .horizontal
        right.spacing = 8

        let row = NSStackView(views: [left, NSView(), right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)
        row.pinEdges(to: footer)
        return footer
    }

    func windowDidResize(_ notification: Notification) {
        updateStorageColumns()
    }

    private func updateStorageColumns() {
        guard let nameColumn, let typeColumn else { return }
        let available = max(300, scroll.bounds.width - 8)
        nameColumn.width = max(150, available * 0.38)
        typeColumn.width = max(180, available - nameColumn.width)
    }

    func reload() {
        table.reloadData()
        emptyLabel.isHidden = !accounts.accounts.isEmpty
        updateStorageColumns()
        updateActions()
    }

    #if DEBUG
    func testRowCount() -> Int { table.numberOfRows }
    func testAdd() { addAccount() }
    func testEdit(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        editAccount()
    }
    var testSelectedRow: Int { table.selectedRow }
    #endif

    private func updateActions() {
        let hasSelection = table.selectedRow >= 0
        editButton?.isEnabled = hasSelection
        deleteButton?.isEnabled = hasSelection
    }

    private var selectedAccount: Account? {
        guard table.selectedRow >= 0, table.selectedRow < accounts.accounts.count else { return nil }
        return accounts.accounts[table.selectedRow]
    }

    @objc private func addAccount() {
        onEditAccount?(nil)
    }

    @objc private func editAccount() {
        guard let account = selectedAccount else { return }
        onEditAccount?(account)
    }

    var selectedAccountID: UUID? { selectedAccount?.id }

    /// Selects an account's row, e.g. the one just added or edited.
    func select(accountID: UUID) {
        guard let row = accounts.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateActions()
    }

    @objc private func deleteAccount() {
        guard let account = selectedAccount, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove account \(account.displayName)?"
        alert.informativeText = "The account metadata and its secret in the Keychain will be removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let wasSelected = self.model.selectedAccount?.id == account.id
            self.accounts.remove(account)
            self.model.reloadAccounts()
            if wasSelected, let selected = self.model.selectedAccount {
                self.model.selectAccount(selected)
            }
            self.reload()
        }
    }

    private func showMore() {
        guard let account = selectedAccount, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Account details"
        alert.informativeText = """
        \(account.displayName)
        Type: \(account.kind.displayName)
        Region: \(account.region)
        Endpoint: \(account.endpoint ?? "Amazon S3")
        Bucket: \(account.bucket ?? "all buckets")
        Path-style addressing: \(account.usePathStyle ? "yes" : "no")
        """
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func closeSheet() {
        guard let window else { return }
        if let parentWindow {
            parentWindow.endSheet(window)
        } else {
            window.close()
        }
        window.orderOut(nil)
    }
}

extension StorageAccountsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { accounts.accounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < accounts.accounts.count else { return nil }
        let account = accounts.accounts[row]
        let identifier = NSUserInterfaceItemIdentifier("accountcell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: "")
            field.font = Theme.Font.field
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            cell.identifier = identifier
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        if tableColumn?.identifier.rawValue == "name" {
            cell.textField?.stringValue = account.displayName
        } else {
            cell.textField?.stringValue = account.kind.displayName
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
    }
}
