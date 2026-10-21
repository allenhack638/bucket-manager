import AppKit

enum Theme {
    enum Metrics {
        static let windowWidth: CGFloat = 1120
        static let windowHeight: CGFloat = 650

        static let titleBarHeight: CGFloat = 30
        static let menuBarHeight: CGFloat = 20
        static let trafficLightInset: CGFloat = 82

        static let sidebarWidth: CGFloat = 321
        static let dividerWidth: CGFloat = 2

        static let treeRowHeight: CGFloat = 16
        static let treeIndent: CGFloat = 14

        static let pathBarHeight: CGFloat = 24
        static let headerHeight: CGFloat = 24
        static let fileRowHeight: CGFloat = 18
        static let actionBarHeight: CGFloat = 30
        static let statusBarHeight: CGFloat = 22

        static let tabBarHeight: CGFloat = 28
        static let transferRowHeight: CGFloat = 18
        static let transferFooterHeight: CGFloat = 32

        static let initialBrowserHeight: CGFloat = 335
    }

    enum Colors {
        static let titleBar = NSColor(hex: 0xF3F3F3)
        static let window = NSColor(hex: 0xF3F3F3)
        static let menuBar = NSColor(hex: 0xF0F0F0)
        static let chrome = NSColor(hex: 0xF0F0F0)
        static let sidebar = NSColor(hex: 0xFDFDFD)
        static let content = NSColor.white
        static let header = NSColor(hex: 0xFAFAFA)
        static let divider = NSColor(hex: 0x8C8C8C)
        static let border = NSColor(hex: 0xE5E5E5)
        static let borderStrong = NSColor(hex: 0xC0C0C0)

        static let accent = NSColor(hex: 0x0078D4)
        static let accentHover = NSColor(hex: 0x106EBE)
        static let accentPressed = NSColor(hex: 0x005A9E)
        static let selection = NSColor(hex: 0x0078D4)
        static let hover = NSColor(hex: 0xF2F2F2)
        static let pressed = NSColor(hex: 0xE5E5E5)

        static let text = NSColor(hex: 0x000000)
        static let secondaryText = NSColor(hex: 0x605E5C)
        static let tertiaryText = NSColor(hex: 0x8A8886)
        static let disabledText = NSColor(hex: 0xB0B0B0)
        static let selectionText = NSColor.white

        static let progress = NSColor(hex: 0x0F7B0F)
        static let progressTrack = NSColor(hex: 0xE6E6E6)
        static let warning = NSColor(hex: 0xA4262C)
        static let success = NSColor(hex: 0x0F7B0F)
        static let link = NSColor(hex: 0x0067C0)
        static let errorBackground = NSColor(hex: 0xFDE7E9)
        static let toastBackground = NSColor(hex: 0xFFFFB6)
    }

    enum Icon {
        struct Style {
            let size: CGFloat
            let weight: NSFont.Weight
            let scale: NSImage.SymbolScale
        }

        static let toolbar = Style(size: 14, weight: .regular, scale: .medium)
        static let action = Style(size: 14, weight: .regular, scale: .medium)
        static let tab = Style(size: 12, weight: .regular, scale: .medium)
        static let link = Style(size: 12, weight: .regular, scale: .medium)
        static let sortIndicator = Style(size: 8, weight: .semibold, scale: .small)
        static let emptyState = Style(size: 34, weight: .light, scale: .medium)
        static let row = Style(size: 16, weight: .regular, scale: .medium)
        static let header = Style(size: 28, weight: .regular, scale: .medium)
        static let status = Style(size: 12, weight: .regular, scale: .medium)
        static let strokeWidth: CGFloat = 1.5

        static func image(_ name: String, style: Style) -> NSImage? {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            let configured = image.withSymbolConfiguration(
                .init(pointSize: style.size, weight: style.weight, scale: style.scale)
            )
            configured?.isTemplate = true
            return configured
        }
    }

    enum Font {
        nonisolated(unsafe) static let title = NSFont.systemFont(ofSize: 12, weight: .regular)
        nonisolated(unsafe) static let menu = NSFont.systemFont(ofSize: 12, weight: .regular)
        nonisolated(unsafe) static let body = NSFont.systemFont(ofSize: 12, weight: .regular)
        nonisolated(unsafe) static let bodyMedium = NSFont.systemFont(ofSize: 12, weight: .medium)
        nonisolated(unsafe) static let bodyBold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nonisolated(unsafe) static let small = NSFont.systemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        nonisolated(unsafe) static let tiny = NSFont.systemFont(ofSize: 10, weight: .regular)
        nonisolated(unsafe) static let tab = NSFont.systemFont(ofSize: 12, weight: .regular)
        nonisolated(unsafe) static let section = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nonisolated(unsafe) static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let field = NSFont.systemFont(ofSize: 13, weight: .regular)
    }

    static let cornerRadius: CGFloat = 4
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension String {
    func leftTruncated(_ maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return "…" + suffix(maxLength - 1)
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Date {
    var s3ListString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f.string(from: self)
    }
}
