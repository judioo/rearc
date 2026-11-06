import AppKit
import SidebarModel
import SwiftUI

/// Settings › Shortcuts on the Chromium menu bar: every item's key equivalent
/// goes through `ShortcutOverrides.effectiveChord(forDefault:)`. The keys an
/// item was built with are Arc's defaults; they are remembered the first time
/// and every later pass starts from them, so a reset puts them back. Keys no
/// Arc binding has (Chrome's ⌥⌘L Downloads, ⇧⌘⌫) are left alone.
final class MenuKeyEquivalents {
    private final class Built {
        let key: String
        let mask: NSEvent.ModifierFlags
        init(key: String, mask: NSEvent.ModifierFlags) {
            self.key = key
            self.mask = mask
        }
    }

    private let built = NSMapTable<NSMenuItem, Built>.weakToStrongObjects()

    func apply(_ overrides: ShortcutOverrides, to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { apply(overrides, to: submenu) }
            let original = built.object(forKey: item) ?? {
                let entry = Built(key: item.keyEquivalent, mask: item.keyEquivalentModifierMask)
                built.setObject(entry, forKey: item)
                return entry
            }()
            guard !original.key.isEmpty else { continue }
            guard let chord = Self.chord(key: original.key, mask: original.mask) else {
                set(item, original.key, original.mask)
                continue
            }
            if let effective = overrides.effectiveChord(forDefault: chord) {
                let equivalent = Self.keyEquivalent(for: effective)
                set(item, equivalent.key, equivalent.mask)
            } else {
                set(item, "", [])
            }
        }
    }

    private func set(_ item: NSMenuItem, _ key: String, _ mask: NSEvent.ModifierFlags) {
        if item.keyEquivalent != key { item.keyEquivalent = key }
        if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
    }

    // MARK: Key equivalent ↔ chord

    /// US-layout shifted characters back to their keys ("+" is ⇧=).
    private static let unshifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// The chord an `NSMenuItem` key equivalent stands for (the inverse of
    /// `ShellMenuItem.appKitKeyEquivalent`); nil for keys Arc's table cannot name.
    static func chord(key: String, mask: NSEvent.ModifierFlags) -> ShortcutChord? {
        guard key.count == 1, let character = key.first, let scalar = key.unicodeScalars.first else { return nil }
        var modifiers = ShortcutRouter.modifiers(of: mask)
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return ShortcutChord(.leftArrow, modifiers)
        case NSRightArrowFunctionKey: return ShortcutChord(.rightArrow, modifiers)
        case NSUpArrowFunctionKey: return ShortcutChord(.upArrow, modifiers)
        case NSDownArrowFunctionKey: return ShortcutChord(.downArrow, modifiers)
        case NSF1FunctionKey ... NSF35FunctionKey: return ShortcutChord(.function(Int(scalar.value) - NSF1FunctionKey + 1), modifiers)
        case 0x09: return ShortcutChord(.tab, modifiers)
        case 0x1B: return ShortcutChord(.escape, modifiers)
        case 0x20: return ShortcutChord(.space, modifiers)
        default: break
        }
        guard scalar.value >= 0x21, scalar.value < 0x7F else { return nil }
        if character.isLetter, character.isUppercase {
            modifiers.insert(.shift)
            return ShortcutChord(.character(Character(character.lowercased())), modifiers)
        }
        if let base = unshifted[character] {
            modifiers.insert(.shift)
            return ShortcutChord(.character(base), modifiers)
        }
        return ShortcutChord(.character(character), modifiers)
    }

    /// The key and mask an `NSMenuItem` needs for `chord`.
    static func keyEquivalent(for chord: ShortcutChord) -> (key: String, mask: NSEvent.ModifierFlags) {
        ShellMenuItem.appKitKeyEquivalent(characters(for: chord.key), flags(of: chord.modifiers))
    }

    static func characters(for key: ShortcutKey) -> String {
        func function(_ value: Int) -> String { String(Character(UnicodeScalar(value)!)) }
        switch key {
        case .character(let character): return String(character)
        case .leftArrow: return function(NSLeftArrowFunctionKey)
        case .rightArrow: return function(NSRightArrowFunctionKey)
        case .upArrow: return function(NSUpArrowFunctionKey)
        case .downArrow: return function(NSDownArrowFunctionKey)
        case .tab: return "\t"
        case .escape: return "\u{1B}"
        case .space: return " "
        case .function(let number): return function(NSF1FunctionKey + number - 1)
        }
    }

    static func flags(of modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}

extension ShellMenuItem {
    /// The SwiftUI shortcut with the user's overrides (WebKit path); nil when unbound.
    func keyboardShortcut(with overrides: ShortcutOverrides) -> KeyboardShortcut? {
        guard let shortcutKey, let key = keyEquivalent else { return nil }
        let chord = ShortcutChord(shortcutKey, ShortcutRouter.modifiers(of: modifiers))
        guard let effective = overrides.effectiveChord(forDefault: chord) else { return nil }
        guard effective != chord else { return KeyboardShortcut(key, modifiers: eventModifiers) }
        var modifiers: EventModifiers = []
        if effective.modifiers.contains(.command) { modifiers.insert(.command) }
        if effective.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if effective.modifiers.contains(.option) { modifiers.insert(.option) }
        if effective.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(MenuKeyEquivalents.characters(for: effective.key))), modifiers: modifiers)
    }
}
