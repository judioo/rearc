import AppKit
import SwiftUI
import SidebarModel

/// A menu command shared by the WebKit path (SwiftUI `Commands`) and the
/// Chromium path (`NSMenu` built by `ChromiumShell`), so both menu bars offer
/// the same items and shortcuts.
struct ShellMenuItem: Identifiable {
    enum Key {
        case character(Character)
        case leftArrow
        case rightArrow
    }

    let title: String
    let key: Key?
    let modifiers: NSEvent.ModifierFlags
    let action: () -> Void

    var id: String { title }

    init(_ title: String, _ key: Key? = nil, _ modifiers: NSEvent.ModifierFlags = .command, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    init(_ title: String, _ character: Character, _ modifiers: NSEvent.ModifierFlags = .command, action: @escaping () -> Void) {
        self.init(title, .character(character), modifiers, action: action)
    }

    /// `NSMenuItem.keyEquivalent`.
    var menuKeyEquivalent: String {
        switch key {
        case .character(let character): return String(character)
        case .leftArrow: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightArrow: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case nil: return ""
        }
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case .character(let character): return KeyEquivalent(character)
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case nil: return nil
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Wave 17 menu groups (dividers between groups). Arc's evidenced commands
/// (SIDEBAR-SPEC §6) with the audit's default shortcuts.
enum ShellMenus {
    /// View menu: page navigation (Arc keeps these in the sidebar, not a toolbar).
    static func navigation(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Back", "[") { model.goBack() },
            ShellMenuItem("Forward", "]") { model.goForward() },
            ShellMenuItem("Reload Page", "r") { model.reload() },
            ShellMenuItem("Reload Ignoring Cache", "r", [.command, .shift]) { model.reload(ignoringCache: true) },
            ShellMenuItem("Stop Loading", ".") { model.stopLoading() },
        ]]
    }

    /// View menu, Chromium with `webui_daily_pages` only: Chromium's own
    /// history, downloads, passwords and extensions pages (Arc's View and
    /// Extensions menus). Shortcuts follow Chrome on macOS.
    static func browserPages(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("History", "y") { model.openBrowserPage(.history) },
            ShellMenuItem("Downloads", "l", [.command, .option]) { model.openBrowserPage(.downloads) },
            ShellMenuItem("Passwords") { model.openBrowserPage(.passwords) },
            ShellMenuItem("Extensions") { model.openBrowserPage(.extensions) },
        ]]
    }

    /// Spaces menu: Ctrl+1…9, next/previous, and space management.
    static func spaces(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [
            [
                ShellMenuItem("Next Space", .rightArrow, [.command, .option]) { model.cycleSpace(forward: true) },
                ShellMenuItem("Previous Space", .leftArrow, [.command, .option]) { model.cycleSpace(forward: false) },
            ],
            (1 ... 9).map { number in
                ShellMenuItem("Space \(number)", Character("\(number)"), .control) { model.selectSpace(atIndex: number - 1) }
            },
            [
                ShellMenuItem("New Space") { model.addSpace() },
                ShellMenuItem("Rename Space…") { model.beginRename(.space(model.store.activeSpaceID)) },
                ShellMenuItem("Edit Theme and Icon…") { model.spaceEditorID = model.store.activeSpaceID },
                ShellMenuItem("Delete Space…") {
                    guard model.canDeleteSpaces else { return }
                    model.pendingDeletion = .space(model.store.activeSpaceID)
                },
            ],
        ]
    }

    /// Tabs menu additions: pin/favorite, item commands, folders, archive.
    static func sidebarItems(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [
            [
                ShellMenuItem("Pin/Unpin Tab", "d") { model.togglePin() },
                ShellMenuItem("Add to Favorites") { model.addToFavorites() },
                ShellMenuItem("Rename Tab…") {
                    if let id = model.store.selectedTabID { model.beginRename(.tab(id)) }
                },
                ShellMenuItem("Duplicate Tab") { model.duplicateTab() },
                ShellMenuItem("Copy URL", "c", [.command, .shift]) { model.copyURL() },
                ShellMenuItem("Archive Tab") { model.archiveTab() },
            ],
            [
                ShellMenuItem("New Folder") { model.newFolder() },
                ShellMenuItem("Expand All Folders") { model.store.setAllFoldersExpanded(true) },
                ShellMenuItem("Collapse All Folders") { model.store.setAllFoldersExpanded(false) },
            ],
            [
                ShellMenuItem("View Archive") { model.isArchivePresented = true },
            ],
        ]
    }
}

/// Renders menu groups as SwiftUI menu buttons (WebKit path).
struct ShellMenuButtons: View {
    let groups: [[ShellMenuItem]]

    var body: some View {
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index]) { item in
                if let key = item.keyEquivalent {
                    Button(item.title, action: item.action)
                        .keyboardShortcut(key, modifiers: item.eventModifiers)
                } else {
                    Button(item.title, action: item.action)
                }
            }
        }
    }
}
