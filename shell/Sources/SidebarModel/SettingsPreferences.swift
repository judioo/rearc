import Foundation

/// The Settings window's toolbar items, in Arc's order (ARC-RECORDING-2026-11-06
/// §6.1). Arc's Max pane is its AI features and is left out.
public enum SettingsPane: String, CaseIterable, Sendable {
    case account, general, profiles, links, shortcuts, icon, advanced

    public static let defaultsKey = "rearc.settingsPane"

    public var title: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .profiles: return "Profiles"
        case .links: return "Links"
        case .shortcuts: return "Shortcuts"
        case .icon: return "Icon"
        case .advanced: return "Advanced"
        }
    }

    public var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .profiles: return "person.2"
        case .links: return "link"
        case .shortcuts: return "command"
        case .icon: return "app.badge"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The window opens on the pane shown last.
    public static func load(from defaults: UserDefaults) -> SettingsPane {
        defaults.string(forKey: defaultsKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Settings › General › Warn before quitting: ⌘Q with browser windows open
/// asks first. Off by default, as in Arc and Chrome.
public enum QuitWarning {
    public static let defaultsKey = "rearc.warnBeforeQuitting"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func shouldAsk(enabled: Bool, browserWindows: Int) -> Bool {
        enabled && browserWindows > 0
    }

    public static let title = "Quit ReArc?"

    public static func message(browserWindows: Int) -> String {
        browserWindows == 1
            ? "You have 1 window open."
            : "You have \(browserWindows) windows open."
    }
}

/// Settings › Advanced › restore windows from previous session (docs/WINDOW-RESTORE.md).
/// Off: a launch opens one window, where the last key window was.
public enum WindowRestorePreference {
    public static let defaultsKey = "rearc.restoreWindows"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Settings › General: keep Arc's dots available alongside ReArc's circles.
public enum SpaceIconStyle: String, CaseIterable, Sendable {
    case colouredCircles, arcDots

    public static let defaultsKey = "rearc.spaceIconStyle"

    public var title: String {
        switch self {
        case .colouredCircles: return "Coloured circles (default)"
        case .arcDots: return "Dots, as in Arc"
        }
    }

    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .colouredCircles
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
