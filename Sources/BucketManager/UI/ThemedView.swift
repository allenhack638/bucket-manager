import AppKit

/// A plain view whose layer background follows the active appearance.
final class ThemedView: NSView {
    var themeColor: NSColor? {
        didSet { applyThemeColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColor()
    }

    private func applyThemeColor() {
        layer?.backgroundColor = themeColor?.resolved(for: self).cgColor
    }
}
