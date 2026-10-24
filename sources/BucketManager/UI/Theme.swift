import AppKit

enum Theme {
    enum Metrics {
        static let windowWidth: CGFloat = 1120
        static let windowHeight: CGFloat = 650

        static let titleBarHeight: CGFloat = 30
        static let menuBarHeight: CGFloat = 20
        static let trafficLightInset: CGFloat = 82

        static let sidebarWidth: CGFloat = 321

        static let treeRowHeight: CGFloat = 16
        static let treeIndent: CGFloat = 14

        static let pathBarHeight: CGFloat = 24
        static let headerHeight: CGFloat = 24
        static let fileRowHeight: CGFloat = 18
        static let actionBarHeight: CGFloat = 30
        static let statusBarHeight: CGFloat = 22

        static let tabBarHeight: CGFloat = 28
        static let transferRowHeight: CGFloat = 18
        static let transferFooterHeight: CGFloat = 40

        static let initialBrowserHeight: CGFloat = 335
        static let brandIconSize: CGFloat = 38
    }

    enum Colors {
        private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                return NSColor(hex: match == .darkAqua ? dark : light)
            }
        }

        static let titleBar = adaptive(0xF3F3F3, 0x2B2B2D)
        static let window = adaptive(0xF3F3F3, 0x1F1F21)
        static let menuBar = adaptive(0xF0F0F0, 0x262628)
        static let chrome = adaptive(0xF0F0F0, 0x262628)
        static let sidebar = adaptive(0xFDFDFD, 0x1C1C1E)
        static let content = adaptive(0xFFFFFF, 0x18181A)
        static let header = adaptive(0xFAFAFA, 0x222224)
        static let border = adaptive(0xE5E5E5, 0x3A3A3C)
        static let borderStrong = adaptive(0xC0C0C0, 0x4A4A4E)

        static let accent = adaptive(0x0078D4, 0x0A84FF)
        static let accentHover = adaptive(0x106EBE, 0x409CFF)
        static let accentPressed = adaptive(0x005A9E, 0x0060DF)
        static let selection = adaptive(0x0078D4, 0x0A84FF)
        static let hover = adaptive(0xF2F2F2, 0x2C2C2E)
        static let pressed = adaptive(0xE5E5E5, 0x3A3A3C)

        static let text = NSColor.labelColor
        static let secondaryText = NSColor.secondaryLabelColor
        static let tertiaryText = NSColor.tertiaryLabelColor
        static let disabledText = NSColor.disabledControlTextColor
        static let selectionText = NSColor.white

        static let progress = adaptive(0x0F7B0F, 0x30D158)
        static let progressTrack = adaptive(0xE6E6E6, 0x3A3A3C)
        static let warning = adaptive(0xA4262C, 0xFF453A)
        static let success = adaptive(0x0F7B0F, 0x30D158)
        static let link = adaptive(0x0067C0, 0x64D2FF)
    }

    enum Icon {
        struct Style {
            let size: CGFloat
            let weight: NSFont.Weight
            let scale: NSImage.SymbolScale
        }

        static let toolbar = Style(size: 16, weight: .regular, scale: .medium)
        static let action = Style(size: 14, weight: .regular, scale: .medium)
        static let tab = Style(size: 12, weight: .regular, scale: .medium)
        static let sortIndicator = Style(size: 8, weight: .semibold, scale: .small)
        static let emptyState = Style(size: 32, weight: .light, scale: .medium)
        static let row = Style(size: 16, weight: .regular, scale: .medium)
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
        nonisolated(unsafe) static let small = NSFont.systemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let tiny = NSFont.systemFont(ofSize: 10, weight: .regular)
        nonisolated(unsafe) static let section = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nonisolated(unsafe) static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        nonisolated(unsafe) static let field = NSFont.systemFont(ofSize: 13, weight: .regular)
    }
}

extension NSColor {
    @MainActor
    func resolved(for view: NSView) -> NSColor {
        var result = self
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Date {
    private static let s3ListFormatterLock = NSLock()
    private static let s3ListFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        return formatter
    }()

    var s3ListString: String {
        Self.s3ListFormatterLock.lock()
        defer { Self.s3ListFormatterLock.unlock() }
        return Self.s3ListFormatter.string(from: self)
    }
}
