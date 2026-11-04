import Foundation

/// Little Arc's compact toolbar and entry points (PEEK-LITTLE-BROWSER §2,
/// §2.1, §2.2): the address placeholder, ⌥⌘-click and the global hotkey.
public enum LittleArcChrome {
    /// What the collapsed address shows: the host for web pages (Arc's
    /// command-bar placeholder), the whole URL otherwise, nothing for a blank page.
    public static func addressText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }

    /// What the address field starts with when it is edited: the full URL.
    public static func editingText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    /// ⌥⌘-click on a link opens it in Little Arc
    /// (`optionCommandClickLittleArcEntryPointEnabled`); ⌘-click alone stays a background tab.
    public static func clickOpensLittleArc(command: Bool, option: Bool, shift: Bool, control: Bool) -> Bool {
        command && option && !shift && !control
    }
}

/// The system-wide Little Arc shortcut (`globalLittleBrowserHotkeyEnabled`).
/// Arc's default combination is not in the spec (§6.6); ReArc uses ⌥⌘N,
/// its New Little Arc Window shortcut, and leaves it off until it is turned on.
public struct LittleArcHotkeyPreference: Equatable {
    public static let defaultsKey = "ReArcLittleArcGlobalHotkey"
    /// kVK_ANSI_N.
    public static let keyCode: UInt32 = 45
    public static let display = "⌥⌘N"

    public var isEnabled: Bool

    public init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    public static func load(from defaults: UserDefaults) -> LittleArcHotkeyPreference {
        LittleArcHotkeyPreference(isEnabled: defaults.bool(forKey: defaultsKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.defaultsKey)
    }
}

extension SidebarStore {
    /// Change Profile in Little Arc (`changeProfileInLittleBrowser`): the window
    /// keeps its page and now loads it with the other profile's storage.
    @discardableResult
    public func setLittleArcProfile(_ id: LittleArcWindow.ID, to profileID: Profile.ID) -> Bool {
        guard profile(withID: profileID) != nil,
              let index = littleArcWindows.firstIndex(where: { $0.id == id }),
              littleArcWindows[index].profileID != profileID else { return false }
        littleArcWindows[index].profileID = profileID
        notifyMutation()
        return true
    }
}
