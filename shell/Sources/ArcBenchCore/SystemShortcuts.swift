import Foundation

/// A key something other than the measured app takes before the app sees it:
/// macOS's own shortcuts (System Settings › Keyboard › Keyboard Shortcuts; with
/// Mission Control's "Switch to Desktop n" on, ⌃1…⌃9 change the macOS desktop)
/// or another app's global hot key (Arc's ⌥⌘N opens a Little Arc in Arc).
public struct ReservedShortcut: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// Who takes it, as a phrase: "macOS's Mission Control › Switch to Desktop 2".
    public var name: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, name: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.name = name
    }

    public func matches(_ chord: KeyChord) -> Bool { chord.keyCode == keyCode && chord.modifiers == modifiers }
}

public enum SystemShortcuts {
    /// The preferences domain (`~/Library/Preferences/com.apple.symbolichotkeys.plist`).
    public static let domain = "com.apple.symbolichotkeys"

    /// The enabled shortcuts in a symbolichotkeys plist. Each entry of
    /// `AppleSymbolicHotKeys` is `{enabled, value: {parameters: [character,
    /// key code, modifier flags]}}`; the flags are NSEvent's (⇧ 1<<17, ⌃ 1<<18,
    /// ⌥ 1<<19, ⌘ 1<<20; the fn and keypad bits on arrows are ignored).
    public static func reserved(fromPlist data: Data) -> [ReservedShortcut] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let keys = root["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        return reserved(hotKeys: keys)
    }

    /// The same from the `AppleSymbolicHotKeys` dictionary itself (as CFPreferences returns it).
    public static func reserved(hotKeys keys: [String: Any]) -> [ReservedShortcut] {
        keys.compactMap { number, entry -> ReservedShortcut? in
            guard let entry = entry as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return nil }
            let code = parameters[1].intValue
            guard (0 ..< 0xFFFF).contains(code) else { return nil }
            let flags = parameters[2].intValue
            var modifiers: KeyModifiers = []
            if flags & (1 << 17) != 0 { modifiers.insert(.shift) }
            if flags & (1 << 18) != 0 { modifiers.insert(.control) }
            if flags & (1 << 19) != 0 { modifiers.insert(.option) }
            if flags & (1 << 20) != 0 { modifiers.insert(.command) }
            return ReservedShortcut(keyCode: UInt16(code), modifiers: modifiers, name: "macOS's " + name(Int(number) ?? -1))
        }.sorted { ($0.keyCode, $0.modifiers.rawValue) < ($1.keyCode, $1.modifiers.rawValue) }
    }

    /// Arc's ⌥⌘N is a global hot key while Arc runs: it opens a Little Arc in
    /// Arc whichever app is frontmost, so it never reaches ReArc.
    public static let arcLittleArc = ReservedShortcut(keyCode: KeyChord.optionCommandN.keyCode, modifiers: KeyChord.optionCommandN.modifiers,
                                                      name: "Arc's global New Little Arc shortcut while Arc runs")

    static func name(_ number: Int) -> String {
        switch number {
        case 118 ... 126: return "Mission Control › Switch to Desktop \(number - 117)"
        case 79, 80: return "Mission Control › Move left a space"
        case 81, 82: return "Mission Control › Move right a space"
        case 32, 34: return "Mission Control"
        case 33, 35: return "Application windows"
        case 36, 37: return "Show Desktop"
        default: return "symbolic hot key \(number)"
        }
    }
}
