import AppKit

// MARK: - Layout helpers

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

extension NSColor {
    func blended(with other: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * fraction
        )
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        guard isTemplate else { return self }
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - Labels

@MainActor
enum Labels {
    static func label(_ text: String, font: NSFont = Theme.Font.body, color: NSColor = Theme.Colors.text) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func wrapping(_ text: String, font: NSFont = Theme.Font.small, color: NSColor = Theme.Colors.secondaryText) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        return field
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Background views

final class ColorView: NSView {
    var color: NSColor { didSet { layer?.backgroundColor = color.cgColor } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class SeparatorView: NSView {
    enum Axis { case horizontal, vertical }

    private let axis: Axis
    private let color: NSColor

    init(axis: Axis, color: NSColor = Theme.Colors.border) {
        self.axis = axis
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        switch axis {
        case .horizontal:
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        case .vertical:
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override var intrinsicContentSize: NSSize {
        axis == .horizontal ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
                            : NSSize(width: 1, height: NSView.noIntrinsicMetric)
    }
}

// MARK: - Flat button

final class FlatButton: NSControl {
    enum Style {
        case menu
        case toolbar
        case tab
        case action
        case primary
        case link
    }

    var title: String = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var iconName: String? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var fontSize: CGFloat? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var iconTint: NSColor? { didSet { needsDisplay = true } }
    var accessibilityTitle: String? { didSet { needsDisplay = true } }
    var accessibilityHelpText: String?
    var isIconOnly = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var style: Style = .toolbar {
        didSet {
            needsDisplay = true
            focusRingType = (style == .tab || style == .menu) ? .none : .exterior
        }
    }
    var isSelectedState = false { didSet { needsDisplay = true } }
    var badge: String? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var horizontalPadding: CGFloat = 10
    var iconStyle: Theme.Icon.Style?

    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        isEnabled = true
        focusRingType = .exterior
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] { [.press] }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == .press else { return }
        MainActor.assumeIsolated { _ = accessibilityPerformPress() }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    required init?(coder: NSCoder) { fatalError() }

    convenience init(_ title: String, icon: String? = nil, style: Style = .toolbar, action: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.iconName = icon
        self.style = style
        self.onClick = action
        if style == .menu { horizontalPadding = 9 }
    }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        var textColor = Theme.Colors.text
        var fill: NSColor?
        if !isEnabled { textColor = Theme.Colors.disabledText }

        switch style {
        case .menu:
            if isSelectedState { fill = Theme.Colors.hover }
            else if hovering { fill = Theme.Colors.hover }
        case .toolbar:
            if pressed { fill = Theme.Colors.pressed } else if hovering { fill = Theme.Colors.hover }
        case .tab:
            fill = isSelectedState ? Theme.Colors.content : (hovering ? Theme.Colors.hover : nil)
        case .action:
            if pressed { fill = Theme.Colors.pressed } else if hovering { fill = Theme.Colors.hover }
        case .primary:
            fill = pressed ? Theme.Colors.accentPressed : (hovering ? Theme.Colors.accentHover : Theme.Colors.accent)
            textColor = .white
        case .link:
            textColor = isSelectedState ? Theme.Colors.accent : Theme.Colors.link
            if isSelectedState { fill = Theme.Colors.hover }
        }

        if let fill {
            fill.setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: style == .tab ? 0 : 2, dy: style == .tab ? 0 : 2),
                                    xRadius: style == .primary || style == .action ? 4 : 3,
                                    yRadius: style == .primary || style == .action ? 4 : 3)
            path.fill()
        }

        if style == .tab && isSelectedState {
            Theme.Colors.accent.setFill()
            NSRect(x: rect.minX + 6, y: rect.minY, width: max(0, rect.width - 12), height: 2).fill()
        }

        let font = fontSize.map { NSFont.systemFont(ofSize: $0, weight: .regular) }
            ?? (style == .menu ? Theme.Font.menu : Theme.Font.body)
        let resolvedIconStyle = iconStyle ?? style.iconStyle
        let iconSize = resolvedIconStyle.size
        let image = iconName.flatMap { Theme.Icon.image($0, style: resolvedIconStyle) }
        let tinted = image?.tinted(iconTint ?? (isEnabled ? textColor : Theme.Colors.disabledText))

        let titleSize = (title as NSString).size(withAttributes: [.font: font])
        let imageWidth = tinted == nil ? 0 : (iconSize + (title.isEmpty ? 0 : 6))
        let totalWidth = imageWidth + titleSize.width
        var x = (rect.width - totalWidth) / 2
        if style == .link {
            x = 2
        } else if style == .menu || style == .toolbar || style == .action {
            x = horizontalPadding
        }

        if let tinted {
            let y = (rect.height - iconSize) / 2
            tinted.draw(in: NSRect(x: x, y: y, width: iconSize, height: iconSize))
            x += imageWidth
        }

        if !title.isEmpty && !isIconOnly {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(
                at: NSPoint(x: x, y: (rect.height - size.height) / 2),
                withAttributes: attrs
            )
        }

        if let badge {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.Font.tiny,
                .foregroundColor: textColor
            ]
            let size = (badge as NSString).size(withAttributes: attrs)
            (badge as NSString).draw(
                at: NSPoint(x: rect.maxX - size.width - 8, y: (rect.height - size.height) / 2),
                withAttributes: attrs
            )
        }
    }

    override var intrinsicContentSize: NSSize {
        let font = fontSize.map { NSFont.systemFont(ofSize: $0, weight: .regular) }
            ?? (style == .menu ? Theme.Font.menu : Theme.Font.body)
        let iconSize = (iconStyle ?? style.iconStyle).size
        let titleSize = (title as NSString).size(withAttributes: [.font: font])
        let iconPart = iconName == nil ? 0 : iconSize + (title.isEmpty ? 0 : 6)
        if isIconOnly {
            return NSSize(width: iconSize + 12, height: 24)
        }
        switch style {
        case .menu:
            return NSSize(width: titleSize.width + horizontalPadding * 2 + iconPart, height: 20)
        case .toolbar:
            return NSSize(width: titleSize.width + horizontalPadding * 2 + iconPart, height: 24)
        case .tab:
            return NSSize(width: titleSize.width + 14, height: 28)
        case .action:
            return NSSize(width: titleSize.width + horizontalPadding * 2 + iconPart, height: 24)
        case .primary:
            return NSSize(width: titleSize.width + 28, height: 28)
        case .link:
            let iconPart = iconName == nil ? 0 : iconSize + 6
            return NSSize(width: titleSize.width + iconPart + 8, height: 18)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch style {
        case .tab: return .radioButton
        default: return .button
        }
    }
    override func accessibilityLabel() -> String? {
        accessibilityTitle ?? (title.isEmpty ? iconName : title)
    }
    override func accessibilityHelp() -> String? { accessibilityHelpText }
    override func accessibilityValue() -> Any? { isSelectedState ? 1 : 0 }
}

// MARK: - Checkbox

final class CheckboxView: NSControl {
    var isChecked = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?
    var accessibilityTitle: String?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            isChecked.toggle()
            needsDisplay = true
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { accessibilityTitle ?? "Checkbox" }
    override func accessibilityValue() -> Any? { isChecked ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        isChecked.toggle()
        needsDisplay = true
        onToggle?()
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 3, yRadius: 3).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        isChecked.toggle()
        needsDisplay = true
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: (bounds.width - 13) / 2, y: (bounds.height - 13) / 2, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
        if isChecked {
            Theme.Colors.accent.setFill()
            path.fill()
            let check = NSBezierPath()
            check.lineWidth = Theme.Icon.strokeWidth
            check.lineCapStyle = .round
            check.move(to: NSPoint(x: box.minX + 3, y: box.midY + 0.5))
            check.line(to: NSPoint(x: box.minX + 5.5, y: box.midY - 2))
            check.line(to: NSPoint(x: box.maxX - 3, y: box.midY + 3))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            (hovering ? Theme.Colors.secondaryText : Theme.Colors.tertiaryText).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Progress bar

final class ProgressBarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = Theme.Colors.progress { didSet { needsDisplay = true } }

    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? { "Progress" }
    override func accessibilityValue() -> Any? { Int(progress * 100) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: max(2, (bounds.height - 10) / 2))
        let track = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        Theme.Colors.progressTrack.setFill()
        track.fill()

        let clamped = min(1, max(0, progress))
        guard clamped > 0 else { return }
        let filled = NSRect(x: rect.minX, y: rect.minY, width: max(2, rect.width * clamped), height: rect.height)
        barColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}

// MARK: - Row view

final class DataRowView: NSTableRowView {
    var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            Theme.Colors.selection.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.Colors.hover.setFill()
            bounds.fill()
        } else {
            Theme.Colors.content.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            Theme.Colors.selection.setFill()
            bounds.fill()
        }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

class HoverTrackingTableView: NSTableView {
    var onHoverRow: ((Int?) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHoverRow?(row(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverRow?(nil)
    }
}

// MARK: - Column header

struct HeaderColumn {
    let id: String
    let title: String
    var width: CGFloat?
    let alignment: NSTextAlignment
}

private final class HeaderActionBox: @unchecked Sendable {
    @MainActor var action: (() -> Void)?

    nonisolated init() {}
}

private final class ColumnHeaderAXElement: NSAccessibilityElement {
    let actionBox = HeaderActionBox()

    override func accessibilityPerformPress() -> Bool {
        let box = actionBox
        MainActor.assumeIsolated { box.action?() }
        return true
    }
}

final class ColumnHeaderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Columns" }

    var columns: [HeaderColumn] = [] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }
    var sortColumn: String?
    var sortAscending = true
    var onSort: ((String) -> Void)?
    var onResize: ((String, CGFloat) -> Void)?
    private var axChildren: [ColumnHeaderAXElement] = []
    private var resizeColumnID: String?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.header.setFill()
        bounds.fill()

        var x: CGFloat = 0
        for column in columns {
            let width = column.width ?? (bounds.width - x - fixedWidthAfter(column: column, startX: x))
            let cell = NSRect(x: x, y: 0, width: width, height: bounds.height)
            if x > 0 {
                Theme.Colors.border.setFill()
                NSRect(x: x, y: 4, width: 1, height: bounds.height - 8).fill()
            }

            let selected = sortColumn == column.id
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.Font.small,
                .foregroundColor: selected ? Theme.Colors.text : Theme.Colors.secondaryText
            ]
            let label = column.title as NSString
            let size = label.size(withAttributes: attrs)
            var textX = cell.minX + 6
            if column.alignment == .right { textX = cell.maxX - size.width - 8 }
            label.draw(at: NSPoint(x: textX, y: (bounds.height - size.height) / 2), withAttributes: attrs)

            if selected {
                let chevron = sortAscending ? "chevron.up" : "chevron.down"
                if let image = Theme.Icon.image(chevron, style: Theme.Icon.sortIndicator)?
                    .tinted(Theme.Colors.secondaryText) {
                    let imageX = column.alignment == .right ? textX - 10 : textX + size.width + 4
                    image.draw(in: NSRect(x: imageX, y: (bounds.height - 8) / 2, width: 8, height: 8))
                }
            }
            x += width
        }

        Theme.Colors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private func fixedWidthAfter(column: HeaderColumn, startX: CGFloat) -> CGFloat {
        guard let index = columns.firstIndex(where: { $0.id == column.id }) else { return 0 }
        return columns[(index + 1)...].compactMap(\.width).reduce(0, +)
    }

    private func columnRects() -> [(column: HeaderColumn, rect: NSRect)] {
        var x: CGFloat = 0
        return columns.map { column in
            let width = column.width ?? (bounds.width - x - fixedWidthAfter(column: column, startX: x))
            defer { x += width }
            return (column, NSRect(x: x, y: 0, width: width, height: bounds.height))
        }
    }

    private func canResize(_ column: HeaderColumn) -> Bool {
        column.id != "check" && column.width != nil
    }

    private func minimumWidth(for id: String) -> CGFloat {
        switch id {
        case "name": return 100
        case "modified": return 100
        default: return 60
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (column, rect) in columnRects() where canResize(column) {
            addCursorRect(
                NSRect(x: rect.maxX - 3, y: 0, width: 6, height: bounds.height),
                cursor: .resizeLeftRight
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rects = columnRects()
        for (column, rect) in rects where canResize(column) {
            if abs(point.x - rect.maxX) <= 3 {
                resizeColumnID = column.id
                resizeStartX = point.x
                resizeStartWidth = rect.width
                return
            }
        }
        for (column, rect) in rects where rect.contains(point) {
            onSort?(column.id)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resizeColumnID,
              let index = columns.firstIndex(where: { $0.id == resizeColumnID }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let width = max(minimumWidth(for: resizeColumnID), resizeStartWidth + point.x - resizeStartX)
        columns[index].width = width
        needsDisplay = true
        onResize?(resizeColumnID, width)
    }

    override func mouseUp(with event: NSEvent) {
        resizeColumnID = nil
    }

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return nil }
        var x: CGFloat = 0
        axChildren.removeAll(keepingCapacity: true)
        for column in columns {
            let width = column.width ?? (bounds.width - x - fixedWidthAfter(column: column, startX: x))
            let rect = NSRect(x: x, y: 0, width: width, height: bounds.height)
            let element = ColumnHeaderAXElement()
            element.actionBox.action = { [weak self] in self?.onSort?(column.id) }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Sort by \(column.title)")
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            axChildren.append(element)
            x += width
        }
        return axChildren
    }

}

// MARK: - Tab strip

final class TabStripView: NSView {
    struct Tab {
        let id: String
        var title: String
    }

    var tabs: [Tab] = [] { didSet { rebuild() } }
    var selectedID: String? { didSet { updateSelection() } }
    var onSelect: ((String) -> Void)?

    private var buttons: [FlatButton] = []
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.chrome.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Inspector tabs")
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .height
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = tabs.map { tab in
            let button = FlatButton(tab.title, style: .tab)
            button.identifier = NSUserInterfaceItemIdentifier(tab.id)
            button.fontSize = 11
            button.accessibilityTitle = tab.title
            button.accessibilityHelpText = "Show \(tab.title)"
            button.onClick = { [weak self] in self?.onSelect?(tab.id) }
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: Theme.Metrics.tabBarHeight).isActive = true
            stack.addArrangedSubview(button)
            return button
        }
        updateSelection()
    }

    private func updateSelection() {
        for button in buttons {
            button.isSelectedState = button.identifier?.rawValue == selectedID
        }
    }

    func setCount(_ count: Int, for id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = "\(tabs[index].title.components(separatedBy: " (").first ?? tabs[index].title) (\(count))"
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.Colors.chrome.resolved(for: self).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.chrome.setFill()
        bounds.fill()
        Theme.Colors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Info text view

final class InfoTextView: NSView {
    private let scroll = NSScrollView()
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.content.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Theme.Font.mono
        textView.textColor = Theme.Colors.text
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.setAccessibilityLabel("Inspector details")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        textView.defaultParagraphStyle = paragraph
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pinEdges(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.Colors.content.resolved(for: self).cgColor
        textView.textColor = Theme.Colors.text
        needsDisplay = true
    }

    var string: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func setText(_ text: String) {
        textView.textColor = Theme.Colors.text
        textView.string = text
    }

    func setPlaceholder(_ text: String) {
        textView.string = text
        textView.textColor = Theme.Colors.secondaryText
    }
}

// MARK: - Empty state

final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let iconName: String
    private let titleLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = Theme.Font.section
        field.textColor = Theme.Colors.text
        field.alignment = .center
        field.maximumNumberOfLines = 0
        return field
    }()
    private let subtitleLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = Theme.Font.body
        field.textColor = Theme.Colors.secondaryText
        field.alignment = .center
        field.maximumNumberOfLines = 0
        return field
    }()
    var action: (() -> Void)?
    private var actionButton: FlatButton?
    private var actionStack: NSStackView?

    init(iconName: String, title: String, subtitle: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.iconName = iconName
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.content.cgColor
        icon.image = Theme.Icon.image(iconName, style: Theme.Icon.emptyState)?
            .tinted(Theme.Colors.secondaryText)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let stack = NSStackView(views: [icon, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        actionStack = stack
        let center = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        center.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            center,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            icon.widthAnchor.constraint(equalToConstant: Theme.Icon.emptyState.size),
            icon.heightAnchor.constraint(equalToConstant: Theme.Icon.emptyState.size),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            subtitleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14)
        ])

        if let actionTitle {
            let button = FlatButton(actionTitle, style: .primary) { [weak self] in self?.action?() }
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.heightAnchor.constraint(equalToConstant: 28),
                button.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
            ])
            actionButton = button
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.Colors.content.resolved(for: self).cgColor
        icon.image = Theme.Icon.image(iconName, style: Theme.Icon.emptyState)?
            .tinted(Theme.Colors.secondaryText)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = max(80, bounds.width - 16)
        titleLabel.preferredMaxLayoutWidth = width
        subtitleLabel.preferredMaxLayoutWidth = width
        titleLabel.invalidateIntrinsicContentSize()
        subtitleLabel.invalidateIntrinsicContentSize()
    }

    func update(iconName: String, title: String, subtitle: String) {
        icon.image = Theme.Icon.image(iconName, style: Theme.Icon.emptyState)?
            .tinted(Theme.Colors.secondaryText)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }

    func setActionVisible(_ visible: Bool, title: String? = nil) {
        actionButton?.isHidden = !visible
        if let title, let actionButton { actionButton.title = title }
    }
}

// MARK: - Toast

final class ToastView: NSView {
    private let label = Labels.label("", font: Theme.Font.body, color: Theme.Colors.text)

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.toastBackground.resolved(for: self).cgColor
        layer?.borderColor = Theme.Colors.borderStrong.resolved(for: self).cgColor
        needsDisplay = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 3
        label.stringValue = message
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension FlatButton.Style {
    var iconStyle: Theme.Icon.Style {
        switch self {
        case .tab, .link:
            return Theme.Icon.tab
        case .action:
            return Theme.Icon.action
        case .menu, .toolbar, .primary:
            return Theme.Icon.toolbar
        }
    }
}
