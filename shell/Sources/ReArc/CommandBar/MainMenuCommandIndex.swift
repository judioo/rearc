import AppKit
import SidebarModel

@MainActor
enum MainMenuCommandIndex {
    static func commands(in menu: NSMenu? = nil) -> [MenuCommand] {
        guard let menu = menu ?? NSApp?.mainMenu else { return [] }
        return items(in: menu).map { id, item, path in
            MenuCommand(id: id, title: item.title, path: path, keyEquivalent: shortcut(item),
                        isEnabled: item.isEnabled, hasAction: item.action != nil,
                        requiresExactQuery: item.action == #selector(NSApplication.hide(_:))
                            || item.action == #selector(NSApplication.terminate(_:))
                            || (path.hasPrefix("ReArc › ") && item.title == "Quit ReArc"))
        }
    }

    @discardableResult
    static func perform(_ id: String, in menu: NSMenu? = nil) -> Bool {
        guard let menu = menu ?? NSApp?.mainMenu, let (_, item, _) = items(in: menu).first(where: { $0.0 == id }),
              item.isEnabled, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func items(in menu: NSMenu, indices: [Int] = [], titles: [String] = []) -> [(String, NSMenuItem, String)] {
        menu.update()
        return menu.items.enumerated().flatMap { index, item -> [(String, NSMenuItem, String)] in
            guard !item.isSeparatorItem, !item.isHidden, item.isEnabled else { return [] }
            let indices = indices + [index], titles = titles + [item.title]
            if let submenu = item.submenu { return items(in: submenu, indices: indices, titles: titles) }
            guard item.action != nil else { return [] }
            // Include the path in the ID so a rebuilt dynamic menu cannot run a different row.
            let path = titles.joined(separator: " › ")
            return [(indices.map(String.init).joined(separator: "/") + ":" + path, item, path)]
        }
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        if let chord = MenuKeyEquivalents.chord(key: item.keyEquivalent, mask: flags) { return chord.display }
        let key = ["\u{7F}": "⌫", "\r": "↩", "\u{03}": "⌤"][item.keyEquivalent] ?? item.keyEquivalent.uppercased()
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            + key
    }
}

extension BrowserViewModel {
    var commandBarMenuCommands: [MenuCommand] {
        MainActor.assumeIsolated { MainMenuCommandIndex.commands() }
    }
}
