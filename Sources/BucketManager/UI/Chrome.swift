import AppKit

final class TitleBarView: NSView {
    var title: String = "" { didSet { titleLabel.stringValue = title } }

    private let iconView = NSImageView()
    private let titleLabel = Labels.label("", font: Theme.Font.title, color: Theme.Colors.text)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        needsDisplay = true

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.trafficLightInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titleBar.setFill()
        bounds.fill()
        Theme.Colors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}

final class AppMenuBarView: NSView {
    private var buttons: [FlatButton] = []
    private var menuTitles: [(String, NSMenu)] = []
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menuBar)
        setAccessibilityLabel("Application menu")
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMenus(_ menus: [(String, NSMenu)]) {
        menuTitles = menus
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons = menus.map { title, menu in
            let button = FlatButton(title, style: .menu)
            button.accessibilityTitle = title
            button.accessibilityHelpText = "Open \(title) menu"
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                button.isSelectedState = true
                menu.popUp(positioning: nil, at: NSPoint(x: button.frame.minX, y: 0), in: self)
                button.isSelectedState = false
            }
            stack.addArrangedSubview(button)
            return button
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.menuBar.setFill()
        bounds.fill()
        Theme.Colors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
