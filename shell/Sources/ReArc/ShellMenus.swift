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

    /// Edit menu: find in page (Chrome/Safari shortcuts). Esc and Return live in the bar.
    static func find(_ model: BrowserViewModel) -> [[ShellMenuItem]] {
        [[
            ShellMenuItem("Find…", "f") { model.showFindBar() },
            ShellMenuItem("Find Next", "g") { model.findNext(forward: true) },
            ShellMenuItem("Find Previous", "g", [.command, .shift]) { model.findNext(forward: false) },
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
            (1 ... 9).map { number in
                ShellMenuItem("Space \(number)", Character("\(number)"), .control) { model.selectSpace(atIndex: number - 1) }
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
                ShellMenuItem("Copy URL as Markdown", "c", [.command, .shift, .option]) { model.copyURL(format: .markdown) },
                ShellMenuItem("Copy as Quote") { model.copyURL(format: .quote) },
                ShellMenuItem("Archive Tab") { model.archiveTab() },
            ],
            [
                ShellMenuItem("Reset Tab to Original URL") { model.resetTabToSavedURL() },
                ShellMenuItem("Reset All Tabs in This Space") { model.resetPinnedTabs() },
                ShellMenuItem("Clear Unpinned Tabs") { model.clearTodayTabs() },
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
            [ShellMenuItem("View Library") { model.openLibrary(nil) }],
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
