import AppKit

/// A clickable path trail, matching the reference: `/ bucket/ folder/ current/`
/// with the current segment drawn in a thin box. Leading segments collapse into
/// an ellipsis menu when the pane is narrow.
@MainActor
final class BreadcrumbView: NSView {
    struct Segment {
        let title: String
        let prefix: String
        let isCurrent: Bool
        let accessibilityLabel: String
    }

    var onNavigate: ((String) -> Void)?

    private var bucket: String?
    private var prefix: String = ""
    private var segments: [Segment] = []
    private var hiddenSegments: [Segment] = []
    private var segmentButtons: [BreadcrumbSegmentButton] = []
    private let segmentHeight: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPath(bucket: String?, prefix: String) {
        if self.bucket == bucket && self.prefix == prefix { return }
        self.bucket = bucket
        self.prefix = prefix

        var built: [Segment] = []
        if let bucket {
            let bucketCurrent = prefix.isEmpty
            built.append(Segment(
                title: "\(bucket)/",
                prefix: "",
                isCurrent: bucketCurrent,
                accessibilityLabel: bucketCurrent ? "Current bucket \(bucket)" : "Open bucket \(bucket)"
            ))
            var cumulative = ""
            let components = prefix.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                cumulative += component + "/"
                let current = index == components.count - 1
                built.append(Segment(
                    title: "\(component)/",
                    prefix: cumulative,
                    isCurrent: current,
                    accessibilityLabel: current ? "Current folder \(component)" : "Open folder \(component)"
                ))
            }
        }
        segments = built

        if bucket != nil {
            setAccessibilityLabel("Path: /" + built.map(\.title).joined())
        } else {
            setAccessibilityLabel("Path: No bucket selected")
        }
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text = bucket == nil ? "No bucket selected" : "/"
        let color = bucket == nil ? Theme.Colors.secondaryText : Theme.Colors.text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.body,
            .foregroundColor: color
        ]
        let height = ceil((text as NSString).size(withAttributes: attributes).height)
        (text as NSString).draw(
            at: NSPoint(x: 0, y: floor((bounds.height - height) / 2)),
            withAttributes: attributes
        )
    }

    override func layout() {
        super.layout()
        layoutSegments()
    }

    private func layoutSegments() {
        segmentButtons.forEach { $0.removeFromSuperview() }
        segmentButtons.removeAll()
        hiddenSegments = []

        guard bucket != nil, !segments.isEmpty else { return }

        let rootWidth = ceil(("/" as NSString).size(withAttributes: [.font: Theme.Font.body]).width)
        var x = rootWidth + 6
        let available = max(0, bounds.width - x - 2)
        guard available > 20 else { return }

        let widths = segments.map { segmentWidth($0) }
        let ellipsisWidth: CGFloat = 20

        func totalWidth(from start: Int) -> CGFloat {
            let visible = widths[start...].reduce(0, +)
            let gaps = CGFloat(segments.count - start) * 2
            let leading = (start > 0 ? ellipsisWidth + 2 : 0)
            return visible + gaps + leading
        }

        var start = 0
        while totalWidth(from: start) > available && start < segments.count - 1 {
            start += 1
        }
        hiddenSegments = Array(segments[0..<start])

        var visibleWidths = Array(widths[start...])
        if start > 0 {
            let overflow = totalWidth(from: start) - available
            if overflow > 0, let last = visibleWidths.indices.last {
                visibleWidths[last] = max(24, visibleWidths[last] - overflow)
            }
            let ellipsis = BreadcrumbSegmentButton(
                title: "…",
                isCurrent: false,
                accessibilityLabel: "Show hidden path segments"
            )
            ellipsis.onPress = { [weak self] in self?.showHiddenMenu(anchor: ellipsis) }
            ellipsis.frame = NSRect(x: x, y: (bounds.height - segmentHeight) / 2, width: ellipsisWidth, height: segmentHeight)
            addSubview(ellipsis)
            segmentButtons.append(ellipsis)
            x += ellipsisWidth + 2
        }

        for (offset, segment) in segments[start...].enumerated() {
            let width = visibleWidths[offset]
            let button = BreadcrumbSegmentButton(
                title: segment.title,
                isCurrent: segment.isCurrent,
                accessibilityLabel: segment.accessibilityLabel
            )
            button.onPress = { [weak self] in self?.onNavigate?(segment.prefix) }
            button.frame = NSRect(x: x, y: (bounds.height - segmentHeight) / 2, width: width, height: segmentHeight)
            addSubview(button)
            segmentButtons.append(button)
            x += width + 2
        }
    }

    private func segmentWidth(_ segment: Segment) -> CGFloat {
        let font = segment.isCurrent ? Theme.Font.bodyMedium : Theme.Font.body
        let text = ceil((segment.title as NSString).size(withAttributes: [.font: font]).width)
        return text + (segment.isCurrent ? 12 : 10)
    }

    private func showHiddenMenu(anchor: NSView) {
        guard !hiddenSegments.isEmpty else { return }
        let menu = NSMenu()
        for segment in hiddenSegments {
            let item = NSMenuItem(title: segment.title, action: #selector(menuNavigate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = segment.prefix
            item.toolTip = segment.accessibilityLabel
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
    }

    @objc private func menuNavigate(_ sender: NSMenuItem) {
        guard let prefix = sender.representedObject as? String else { return }
        onNavigate?(prefix)
    }
}

@MainActor
private final class BreadcrumbSegmentButton: NSButton {
    var onPress: (() -> Void)?
    private let isCurrent: Bool
    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, isCurrent: Bool, accessibilityLabel: String) {
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .left
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(press)
        toolTip = accessibilityLabel
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
            Theme.Colors.borderStrong.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            border.lineWidth = 1
            border.stroke()
        } else if hovered {
            Theme.Colors.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        }

        let font = isCurrent ? Theme.Font.bodyMedium : Theme.Font.body
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.Colors.text,
            .paragraphStyle: paragraph
        ]
        let textHeight = ceil((title as NSString).size(withAttributes: [.font: font]).height)
        let inset: CGFloat = isCurrent ? 6 : 5
        let rect = NSRect(
            x: inset,
            y: floor((bounds.height - textHeight) / 2),
            width: max(0, bounds.width - inset * 2),
            height: textHeight
        )
        (title as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isCurrent else { return }
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isCurrent ? .arrow : .pointingHand)
    }

    @objc private func press() {
        guard !isCurrent else { return }
        onPress?()
    }
}
