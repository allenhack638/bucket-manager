import AppKit

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "BucketManagerAppearance"

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppAppearance {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = AppAppearance(rawValue: raw) else { return .system }
        return mode
    }

    @MainActor
    static func apply(_ mode: AppAppearance) {
        NSApp.appearance = mode.appearance
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        LogStore.shared.audit(
            event: "settings.appearance.changed",
            message: "Appearance setting changed",
            outcome: "success",
            metadata: ["mode": mode.rawValue]
        )
    }
}
