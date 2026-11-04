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
        case upArrow
        case downArrow
        case function(Int)
    }

    let title: String
    let key: Key?
    let modifiers: NSEvent.ModifierFlags
    /// An alternate key for the item above it, as in Arc's nib (⌘← for Back,
    /// F12 for Developer Tools): hidden, its key still works (Chromium path).
    let isAlternate: Bool
    /// The title as the app's state has it now, nil to hide the item (Arc's
    /// Spaces menu names its spaces; Show/Hide Sidebar flips). `title` is the fallback.
    var liveTitle: (() -> String?)?
    let action: () -> Void

    var id: String { isAlternate ? "\(title) (alternate)" : title }

    init(_ title: String, _ key: Key? = nil, _ modifiers: NSEvent.ModifierFlags = .command, alternate: Bool = false,
         liveTitle: (() -> String?)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.isAlternate = alternate
        self.liveTitle = liveTitle
        self.action = action
    }

    init(_ title: String, _ character: Character, _ modifiers: NSEvent.ModifierFlags = .command, alternate: Bool = false,
         liveTitle: (() -> String?)? = nil, action: @escaping () -> Void) {
        self.init(title, .character(character), modifiers, alternate: alternate, liveTitle: liveTitle, action: action)
    }

    /// Arc's binding for this item's keys, if it has one (docs/SHORTCUTS.md).
    var arcShortcut: ArcShortcut? {
        guard let shortcutKey else { return nil }
        return ArcShortcuts.binding(for: shortcutKey, modifiers: ShortcutRouter.modifiers(of: modifiers))
    }

    var shortcutKey: ShortcutKey? {
        switch key {
        case .character("\t"): return .tab
        case .character(let character): return .character(Character(character.lowercased()))
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .function(let number): return .function(number)
        case nil: return nil
        }
    }

    /// `NSMenuItem.keyEquivalent`.
    var menuKeyEquivalent: String {
        switch key {
        case .character(let character): return String(character)
        case .leftArrow: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightArrow: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .upArrow: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .downArrow: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .function(let number): return String(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
        case nil: return ""
        }
    }

    /// The key and mask for an `NSMenuItem` (Chromium path): AppKit matches a
    /// shifted shortcut by its shifted character with Shift left out of the
    /// mask ("C" + ⌘ for ⇧⌘C, "+" + ⌃ for ⌃⇧=), as Arc's nib stores them; a
    /// lowercase key with an explicit Shift never matches a real key press.
    var appKitKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        Self.appKitKeyEquivalent(menuKeyEquivalent, modifiers)
    }

    /// US-layout shifted characters, for `appKitKeyEquivalent`.
    private static let shiftedCharacters: [Character: Character] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]

    static func appKitKeyEquivalent(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> (key: String, mask: NSEvent.ModifierFlags) {
        guard modifiers.contains(.shift), key.count == 1, let character = key.first else { return (key, modifiers) }
        let shifted: Character
        if character.isLetter, character.isLowercase {
            shifted = Character(character.uppercased())
        } else if let mapped = shiftedCharacters[character] {
            shifted = mapped
        } else {
            return (key, modifiers)  // Tab, Delete, arrows, function keys keep an explicit Shift.
        }
        return (String(shifted), modifiers.subtracting(.shift))
    }

    /// The title to show now; nil hides the item.
    var shownTitle: String? { liveTitle.map { $0() } ?? title }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case .character(let character): return KeyEquivalent(character)
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .function(let number): return KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
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
/// (SIDEBAR-SPEC §6); since wave 30 the keys are Arc's own (`ArcShortcuts`,
/// docs/SHORTCUTS.md).
enum ShellMenus {
    /// View menu: page navigation (Arc keeps these in the sidebar, not a toolbar).
    static func navigation(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Back", "[") { model.goBack() },
            ShellMenuItem("Back", .leftArrow, alternate: true) { model.goBack() },
            ShellMenuItem("Forward", "]") { model.goForward() },
            ShellMenuItem("Forward", .rightArrow, alternate: true) { model.goForward() },
            ShellMenuItem("Reload Page", "r") { model.reload() },
            ShellMenuItem("Reload Ignoring Cache", "r", [.command, .shift]) { model.reload(ignoringCache: true) },
            ShellMenuItem("Stop Loading", ".") { model.stopLoading() },
        ]]
    }

    /// Edit menu: find in page (Chrome/Safari shortcuts). Esc and Return live in the bar.
    static func find(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Find…", "f") { model.showFindBar() },
            ShellMenuItem("Find Next", "g") { model.findNext(forward: true) },
            ShellMenuItem("Find Previous", "g", [.command, .shift]) { model.findNext(forward: false) },
            ShellMenuItem("Jump to Selection", "j") { model.jumpToSelection() },
        ]]
    }

    /// File menu: Arc's New Note (⌃⇧N) and New Easel (⌃⇧E), and ⌘O, Arc's
    /// "Open Little Arc or Peek in…": the key Little Arc moves to a tab in the
    /// active space (Arc asks which space; ReArc has no chooser yet).
    static func documents(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("New Note", "n", [.control, .shift]) { _ = model.executeCommand(.newNote, commandID: nil) },
            ShellMenuItem("New Easel", "e", [.control, .shift]) { _ = model.executeCommand(.newEasel, commandID: nil) },
            ShellMenuItem("Open Little Arc in Space", "o") {
                if let id = model.keyLittleArcID { model.promoteLittleArcWindow(id) }
            },
        ]]
    }

    /// View menu: Zoom In (⌘=, and ⌘+), Zoom Out (⌘-, and ⇧⌘-), Actual Size.
    static func zoom(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Zoom In", "=") { model.zoom(.zoomIn) },
            ShellMenuItem("Zoom In", "=", [.command, .shift], alternate: true) { model.zoom(.zoomIn) },
            ShellMenuItem("Zoom Out", "-") { model.zoom(.zoomOut) },
            ShellMenuItem("Zoom Out", "-", [.command, .shift], alternate: true) { model.zoom(.zoomOut) },
            ShellMenuItem("Actual Size", "0") { model.zoom(.reset) },
        ]]
    }

    /// Tabs menu: Arc's Next/Previous Tab (⌥⌘↓ / ⌥⌘↑, sidebar order) and Cycle
    /// Tab (⌃⌘← / ⌃⌘→, back and forth through the tabs visited).
    static func tabNavigation(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Next Tab", .downArrow, [.command, .option]) { model.selectNextTab() },
            ShellMenuItem("Previous Tab", .upArrow, [.command, .option]) { model.selectPreviousTab() },
            ShellMenuItem("Cycle Tab Backward", .leftArrow, [.command, .control]) { model.cycleTabHistory(forward: false) },
            ShellMenuItem("Cycle Tab Forward", .rightArrow, [.command, .control]) { model.cycleTabHistory(forward: true) },
        ]]
    }

    /// Tabs menu: Arc's View > Add Split View (⌃⇧=) and Close this Split Pane (⌃⇧-).
    static func split(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Add Split View", "=", [.control, .shift]) { model.addSplitView(orientation: .horizontal) },
            ShellMenuItem("Close this Split Pane", "-", [.control, .shift]) { model.closeFocusedSplitPane() },
            ShellMenuItem("Separate from Split View") {
                if let tab = model.store.selectedTab { model.unsplitTabIfInSplit(tab.id) }
            },
        ]]
    }

    /// File menu: print the key page (⌘P, as every browser) and Export as PDF… (Safari's name).
    static func printing(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Export as PDF…") { model.exportPageAsPDF() },
            ShellMenuItem("Print…", "p") { model.printPage() },
        ]]
    }

    /// File menu: import. Chromium's importer (Import Bookmarks and Settings,
    /// which also reads passwords and history) where the engine has it; on
    /// both engines, a bookmarks file exported from any browser.
    static func importing(_ model: BrowserViewModel, chromiumImporter: Bool) -> [[ShellMenuItem]] {
        var items = [ShellMenuItem("Import Bookmarks from HTML File…") { model.importBookmarksFile() }]
        if chromiumImporter {
            items.insert(ShellMenuItem("Import from Another Browser…") { model.openBrowserPage(.importData) }, at: 0)
        }
        return [items]
    }

    /// File menu: Arc's capture commands (EASEL-CAPTURE §5). ⇧⌘2 sits beside
    /// macOS's own ⇧⌘3–5 screenshots.
    static func capture(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Capture", "2", [.command, .shift]) { model.beginPageCapture() },
            ShellMenuItem("Capture Full Page") { Task { await model.performCapture(scope: .fullPage) } },
            ShellMenuItem("Capture Visible Area") { Task { await model.performCapture(scope: .visible) } },
            ShellMenuItem("Capture in Portrait Mode") { Task { await model.capturePortrait() } },
            ShellMenuItem("Portrait Capture Watermark On/Off") { model.portraitCaptureWatermark.toggle() },
        ]]
    }

    /// View menu: the selected tab's video in or out of Picture in Picture.
    static func pictureInPicture(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Picture in Picture") { model.togglePictureInPicture() },
        ]]
    }

    /// View menu: the sidebar's downloads tray (both engines).
    static func downloads(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Show Downloads", "j", [.command, .shift]) { model.toggleDownloadsTray() },
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

    /// View > Developer, Chromium with `devtools` (ABI 1.40): the page's
    /// DevTools, docked beside it (Arc's default) or in their own window.
    static func developer(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Developer Tools", "i", [.command, .option]) { model.toggleDevTools() },
            ShellMenuItem("Developer Tools", .function(12), [], alternate: true) { model.toggleDevTools() },
            // The frontend opens on its last panel: the ABI has no panel or inspect-mode choice.
            ShellMenuItem("Inspect Elements", "c", [.command, .option]) { model.showDevTools() },
            ShellMenuItem("JavaScript Console", "j", [.command, .option]) { model.showDevTools() },
            ShellMenuItem("Open Developer Tools in a Window") { model.setDevToolsPlacement(.window) },
            ShellMenuItem("Dock Developer Tools") { model.setDevToolsPlacement(.docked) },
        ]]
    }

    /// Tabs menu: Arc's Tab Switcher (forward/backward), recent tabs first.
    /// The app-wide key monitor handles the keys; the items show them.
    static func tabSwitcher(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Tab Switcher (Forward)", "\t", .control) { model.cycleRecentTabs(forward: true) },
            ShellMenuItem("Tab Switcher (Backward)", "\t", [.control, .shift]) { model.cycleRecentTabs(forward: false) },
        ]]
    }

    /// Tabs menu: Cmd+1…8 select that sidebar row (favorites, pinned, Today),
    /// Cmd+9 the last one (Arc / Chrome "Switch to Nth Tab").
    static func tabPositions(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [(1 ... 9).map { number in
            ShellMenuItem(number == 9 ? "Last Tab" : "Tab \(number)", Character("\(number)")) {
                model.selectItem(atPosition: number)
            }
        }]
    }

    /// Spaces menu: Ctrl+1…9, next/previous, and space management.
    static func spaces(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [
            [
                ShellMenuItem("Next Space", .rightArrow, [.command, .option]) { model.cycleSpace(forward: true) },
                ShellMenuItem("Previous Space", .leftArrow, [.command, .option]) { model.cycleSpace(forward: false) },
            ],
            // Arc's live Spaces menu lists the spaces by name, ⌃1…⌃9 on the first nine.
            (1 ... 9).map { number in
                ShellMenuItem("Space \(number)", Character("\(number)"), .control, liveTitle: {
                    let spaces = model.store.spacesInActiveProfile
                    return spaces.indices.contains(number - 1) ? spaces[number - 1].name : nil
                }) { model.selectSpace(atIndex: number - 1) }
            },
            [
                ShellMenuItem("New Space…") { model.beginSpaceCreation() },
                ShellMenuItem("Rename Space…") { model.beginRename(.space(model.store.activeSpaceID)) },
                ShellMenuItem("Edit Theme and Icon…") { model.spaceEditorID = model.store.activeSpaceID },
            ],
            SpaceAppearance.allCases.map { appearance in
                ShellMenuItem("Appearance: \(appearance.title)") { model.setSpaceAppearance(appearance) }
            },
            [
                ShellMenuItem("Move Space Left") { model.moveActiveSpace(by: -1) },
                ShellMenuItem("Move Space Right") { model.moveActiveSpace(by: 1) },
                ShellMenuItem("Delete Space…") {
                    guard model.canDeleteSpaces else { return }
                    model.pendingDeletion = .space(model.store.activeSpaceID)
                },
            ],
        ]
    }

    /// Edit menu (Arc's place for them): Copy URL ⇧⌘C, as Markdown ⌥⇧⌘C and
    /// as Quote ⌃⇧⌘C, links cleaned of trackers, with Arc's toast.
    static func copyLink(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Copy URL", "c", [.command, .shift]) { model.copyURL() },
            ShellMenuItem("Copy URL as Markdown", "c", [.command, .shift, .option]) { model.copyURL(format: .markdown) },
            ShellMenuItem("Copy URL as Quote", "c", [.command, .shift, .control]) { model.copyURL(format: .quote) },
        ]]
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
                ShellMenuItem("Archive Tab") { model.archiveTab() },
            ],
            [
                ShellMenuItem("Reset Tab to Original URL") { model.resetTabToSavedURL() },
                ShellMenuItem("Reset All Tabs in This Space") { model.resetPinnedTabs() },
                ShellMenuItem("Clear Unpinned Tabs", "k", [.command, .shift]) { model.clearTodayTabs() },
            ],
            [
                ShellMenuItem("Flip Split Orientation") { model.flipSplitOrientation() },
                ShellMenuItem("Expand Current Split") { model.toggleExpandedSplitPane() },
            ],
            [
                ShellMenuItem("Expand Pinned Section") { model.setPinnedSectionCollapsed(false) },
                ShellMenuItem("Collapse Pinned Section") { model.setPinnedSectionCollapsed(true) },
            ],
            [
                ShellMenuItem("New Folder") { model.newFolder() },
                ShellMenuItem("Expand All Folders") { model.store.setAllFoldersExpanded(true) },
                ShellMenuItem("Collapse All Folders") { model.store.setAllFoldersExpanded(false) },
            ],
            [
                ShellMenuItem("New Boost") { model.newBoost() },
                ShellMenuItem("New Legacy Boost (Advanced)") { model.newLegacyBoost() },
                ShellMenuItem("Import Boosts…") { BoostFilePanels.importBoosts(model: model) },
            ],
        ]
    }

    /// View menu: Arc's View Library and its pages (`openLibrary`,
    /// `viewEaselsAndNotes`, `viewScreenshotsAndCaptures`, `openDownloads`,
    /// `viewArchive`, `viewBoosts`; SIDEBAR-SPEC §6).
    static func library(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [
            [ShellMenuItem("View Library", "l", [.command, .shift]) { model.openLibrary(nil) }],
            LibrarySection.allCases.map { section in
                ShellMenuItem(section.menuTitle) { model.openLibrary(section) }
            },
        ]
    }
}

/// Renders menu groups as SwiftUI menu buttons (WebKit path).
struct ShellMenuButtons: View {
    let groups: [[ShellMenuItem]]

    var body: some View {
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index].filter { !$0.isAlternate && $0.shownTitle != nil }) { item in
                if let key = item.keyEquivalent {
                    Button(item.shownTitle ?? item.title, action: item.action)
                        .keyboardShortcut(key, modifiers: item.eventModifiers)
                } else {
                    Button(item.shownTitle ?? item.title, action: item.action)
                }
            }
        }
    }
}
