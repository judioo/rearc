import XCTest
@testable import SidebarModel

/// Wave 35: the Settings window's model: shortcut overrides and their
/// conflicts, the Little Arc archive threshold, the remembered pane, Warn
/// before quitting and window restore.
final class Wave35SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "Wave35SettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let cmdT = ShortcutChord(.character("t"), .command)
    private let cmdShiftK = ShortcutChord(.character("k"), [.shift, .command])

    // MARK: Overrides

    func testWithoutOverridesEveryBindingKeepsArcsChord() {
        let overrides = ShortcutOverrides()
        XCTAssertFalse(overrides.hasChanges)
        for shortcut in ArcShortcuts.all {
            XCTAssertEqual(overrides.chord(for: shortcut.id), ShortcutChord(of: shortcut), shortcut.id)
            XCTAssertFalse(overrides.isCustomized(shortcut.id))
        }
        XCTAssertNil(overrides.chord(for: "noSuchBinding"))
    }

    func testRecordingAChordMovesTheBindingAndTheOldChordGoesFree() {
        var overrides = ShortcutOverrides()
        let chord = ShortcutChord(.character("y"), [.control, .option, .command])
        overrides.set(chord, for: "newTab")
        XCTAssertTrue(overrides.hasChanges)
        XCTAssertTrue(overrides.isCustomized("newTab"))
        XCTAssertEqual(overrides.chord(for: "newTab"), chord)
        XCTAssertEqual(overrides.binding(for: chord.key, modifiers: chord.modifiers)?.id, "newTab")
        XCTAssertNil(overrides.binding(for: .character("t"), modifiers: .command), "⌘T no longer runs anything")
    }

    func testRecordingTheDefaultChordClearsTheOverride() {
        var overrides = ShortcutOverrides()
        overrides.set(cmdShiftK, for: "newTab")
        overrides.set(cmdT, for: "newTab")
        XCTAssertFalse(overrides.isCustomized("newTab"))
        XCTAssertFalse(overrides.hasChanges)
    }

    func testUnknownIDsAreIgnored() {
        var overrides = ShortcutOverrides(["gone": .unbound])
        XCTAssertFalse(overrides.hasChanges, "a stored ID Arc's table no longer has is dropped")
        overrides.set(cmdT, for: "gone")
        overrides.unbind("gone")
        XCTAssertFalse(overrides.hasChanges)
    }

    func testUnbindingShowsADashAndFreesTheChord() {
        var overrides = ShortcutOverrides()
        overrides.unbind("pinTab")
        XCTAssertNil(overrides.chord(for: "pinTab"))
        XCTAssertNil(overrides.binding(for: .character("d"), modifiers: .command))
        let row = overrides.rows(matching: "Pin/Unpin").first
        XCTAssertEqual(row?.chipText, "—")
        XCTAssertEqual(row?.isCustomized, true)
        XCTAssertEqual(row?.conflicts, [])
    }

    func testResetOneAndResetAll() {
        var overrides = ShortcutOverrides()
        overrides.set(cmdShiftK, for: "newTab")
        overrides.unbind("pinTab")
        overrides.reset("newTab")
        XCTAssertEqual(overrides.chord(for: "newTab"), cmdT)
        XCTAssertTrue(overrides.hasChanges)
        overrides.resetAll()
        XCTAssertFalse(overrides.hasChanges, "Reset All Shortcuts goes back to Arc's table")
        XCTAssertEqual(overrides, ShortcutOverrides())
    }

    // MARK: Conflicts

    func testATakenChordIsAConflictAndTheFirstInMenuOrderWins() {
        var overrides = ShortcutOverrides()
        overrides.set(cmdShiftK, for: "newTab")
        XCTAssertEqual(overrides.conflicts(for: cmdShiftK, excluding: "newTab"),
                       [.binding(ArcShortcuts.binding(id: "clearExplore")!)])
        XCTAssertEqual(overrides.conflicts(for: cmdShiftK, excluding: "clearExplore"),
                       [.binding(ArcShortcuts.binding(id: "newTab")!)])
        // File's New Tab comes before Tabs' Clear Unpinned Tabs, as in the menu bar.
        XCTAssertEqual(overrides.binding(for: .character("k"), modifiers: [.shift, .command])?.id, "newTab")
        let flagged = overrides.rows().filter { !$0.conflicts.isEmpty }.map(\.id)
        XCTAssertTrue(flagged.contains("newTab"))
        XCTAssertTrue(flagged.contains("clearExplore"))
    }

    func testArcsOwnDuplicateIsFlaggedByDefault() {
        // New Folder… shares ⇧⌘N with New Incognito Window in Arc's nib.
        let rows = ShortcutOverrides().rows()
        let folder = rows.first { $0.id == "newFolder" }
        XCTAssertEqual(folder?.conflicts, [.binding(ArcShortcuts.binding(id: "newIncognitoWindow")!)])
        let bindingConflicts = rows.filter { $0.conflicts.contains { if case .binding = $0 { true } else { false } } }
        XCTAssertEqual(Set(bindingConflicts.map(\.id)), ["newFolder", "newIncognitoWindow"])
    }

    func testSystemChordsAreFlagged() {
        let overrides = ShortcutOverrides()
        let space1 = overrides.rows().first { $0.id == "goToSpace1" }
        XCTAssertEqual(space1?.conflicts, [.system("Switch to Desktop 1")], "Arc's ⚠ on ⌃1…⌃9")
        XCTAssertEqual(overrides.conflicts(for: ShortcutChord(.space, .command), excluding: "x"), [.system("Spotlight")])
        XCTAssertEqual(overrides.conflicts(for: ShortcutChord(.character("4"), [.shift, .command]), excluding: "x"),
                       [.system("screenshots")])
        XCTAssertEqual(overrides.conflicts(for: ShortcutChord(.character("y"), [.control, .option, .command]), excluding: "x"), [])
        XCTAssertEqual(ShortcutConflict.system("Spotlight").message, "macOS uses this shortcut for Spotlight")
        XCTAssertEqual(ShortcutConflict.binding(ArcShortcuts.binding(id: "newTab")!).message, "Also used by New Tab…")
    }

    // MARK: Menu key equivalents

    func testMenuItemsFollowTheirBindingsOverride() {
        var overrides = ShortcutOverrides()
        let chord = ShortcutChord(.character("y"), [.control, .option, .command])
        overrides.set(chord, for: "newTab")
        overrides.unbind("pinTab")
        XCTAssertEqual(overrides.effectiveChord(forDefault: cmdT), chord)
        XCTAssertNil(overrides.effectiveChord(forDefault: ShortcutChord(.character("d"), .command)), "unbound: no key equivalent")
        let unchanged = ShortcutChord(.character("r"), .command)
        XCTAssertEqual(overrides.effectiveChord(forDefault: unchanged), unchanged)
        // ReArc's own keys (Chrome's ⌥⌘L Downloads) are not Arc bindings and stay.
        let rearcOwn = ShortcutChord(.character("l"), [.option, .command])
        XCTAssertEqual(overrides.effectiveChord(forDefault: rearcOwn), rearcOwn)
    }

    func testAShadowedDefaultFollowsTheBindingThatOwnsIt() {
        var overrides = ShortcutOverrides()
        let chord = ShortcutChord(.character("p"), [.shift, .command])
        overrides.set(chord, for: "newIncognitoWindow")
        XCTAssertEqual(overrides.effectiveChord(forDefault: ShortcutChord(.character("n"), [.shift, .command])), chord,
                       "the menu's ⇧⌘N item is New Incognito Window, first in Arc's order")
    }

    // MARK: Chords

    func testChordsNormaliseLettersAndRejectBareKeys() {
        XCTAssertEqual(ShortcutChord(.character("C"), [.shift, .command]), ShortcutChord(.character("c"), [.shift, .command]))
        XCTAssertEqual(ShortcutChord(.character("c"), [.shift, .command]).display, "⇧⌘C")
        XCTAssertFalse(ShortcutChord(.character("a"), []).isAssignable)
        XCTAssertFalse(ShortcutChord(.character("a"), .shift).isAssignable)
        XCTAssertTrue(ShortcutChord(.character("a"), .option).isAssignable)
        XCTAssertTrue(ShortcutChord(.character("a"), .control).isAssignable)
        XCTAssertTrue(ShortcutChord(.function(5), []).isAssignable)
        XCTAssertFalse(ShortcutChord(.escape, []).isAssignable)
    }

    // MARK: List and search

    func testTheListIsAlphabeticalWithEveryBinding() {
        let rows = ShortcutOverrides().rows()
        XCTAssertEqual(rows.count, ArcShortcuts.all.count)
        let titles = rows.map(\.title)
        XCTAssertEqual(titles, titles.sorted { $0.localizedStandardCompare($1) != .orderedDescending })
        XCTAssertEqual(rows.first { $0.id == "goBack_Alternate" }?.title, "Go Back (Alternate)")
        XCTAssertEqual(rows.first { $0.id == "goBack" }?.title, "Go Back")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testSearchByNameOrByChord() {
        let overrides = ShortcutOverrides()
        XCTAssertEqual(Set(overrides.rows(matching: "copy url").map(\.id)),
                       ["copyCurrentURL", "copyCurrentURLMarkdown", "copyCurrentURLAsQuote"])
        XCTAssertEqual(overrides.rows(matching: "⇧⌘C").map(\.id), ["copyCurrentURL"])
        XCTAssertEqual(overrides.rows(matching: "cmd shift c").map(\.id), ["copyCurrentURL"])
        XCTAssertEqual(overrides.rows(matching: "⌃⇧⌘").map(\.id), ["copyCurrentURLAsQuote"], "modifiers alone: every chord holding them")
        XCTAssertEqual(overrides.rows(matching: "ctrl+tab").map(\.id), ["cycleNextTab"])
        XCTAssertTrue(overrides.rows(matching: "   ").count == ArcShortcuts.all.count)
        XCTAssertTrue(overrides.rows(matching: "zzzz").isEmpty)
    }

    func testAnUnboundRowIsFoundByNameOnly() {
        var overrides = ShortcutOverrides()
        overrides.unbind("newTab")
        XCTAssertEqual(overrides.rows(matching: "New Tab").map(\.id), ["newTab"])
        XCTAssertFalse(overrides.rows(matching: "⌘T").map(\.id).contains("newTab"))
    }

    // MARK: Persistence

    func testOverridesRoundTripThroughDefaults() {
        var overrides = ShortcutOverrides()
        overrides.set(ShortcutChord(.character("y"), [.control, .option, .shift, .command]), for: "newTab")
        overrides.set(ShortcutChord(.leftArrow, [.control, .option]), for: "goBack")
        overrides.set(ShortcutChord(.function(5), []), for: "reloadPage")
        overrides.set(ShortcutChord(.space, .option), for: "addressBar")
        overrides.set(ShortcutChord(.tab, [.option, .command]), for: "cycleNextTab")
        overrides.set(ShortcutChord(.character("+"), .command), for: "zoomIn")
        overrides.set(ShortcutChord(.escape, .option), for: "exit")
        overrides.unbind("pinTab")
        overrides.save(to: defaults)
        XCTAssertEqual(ShortcutOverrides.load(from: defaults), overrides)
        XCTAssertEqual((defaults.dictionary(forKey: ShortcutOverrides.defaultsKey) as? [String: String])?["newTab"],
                       "control+option+shift+command+y")
        XCTAssertEqual((defaults.dictionary(forKey: ShortcutOverrides.defaultsKey) as? [String: String])?["zoomIn"], "command++")

        overrides.resetAll()
        overrides.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: ShortcutOverrides.defaultsKey), "no changes: nothing stored")
        XCTAssertFalse(ShortcutOverrides.load(from: defaults).hasChanges)
    }

    func testCorruptStoredEntriesAreSkipped() {
        defaults.set(["newTab": "hyper+t", "pinTab": "-", "reloadPage": "command+", "find": "command+f13"], forKey: ShortcutOverrides.defaultsKey)
        let overrides = ShortcutOverrides.load(from: defaults)
        XCTAssertEqual(overrides.overrides, ["pinTab": .unbound, "find": .chord(ShortcutChord(.function(13), .command))])
        defaults.set("not a dictionary", forKey: ShortcutOverrides.defaultsKey)
        XCTAssertFalse(ShortcutOverrides.load(from: defaults).hasChanges)
    }

    func testTokensForEveryKeyKind() {
        let keys: [ShortcutKey] = [.character("a"), .character(";"), .leftArrow, .rightArrow, .upArrow, .downArrow,
                                   .tab, .escape, .space, .function(1), .function(12)]
        for key in keys {
            XCTAssertEqual(ShortcutKey(token: key.token), key, key.token)
        }
        XCTAssertNil(ShortcutKey(token: "f0"))
        XCTAssertNil(ShortcutKey(token: "home"))
    }

    // MARK: Little Arc archive

    func testLittleArcsArchiveAfterTheChosenThreshold() {
        let store = SidebarStore.sample()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let old = store.createLittleArcWindow(url: URL(string: "https://a.example")!, at: start)
        let recent = store.createLittleArcWindow(url: URL(string: "https://b.example")!, at: start.addingTimeInterval(11 * 3600))
        let key = store.createLittleArcWindow(url: URL(string: "https://c.example")!, at: start)
        let now = start.addingTimeInterval(13 * 3600)
        XCTAssertEqual(store.autoArchiveIdleLittleArcWindows(referenceDate: now), [], "24 hours by default")
        let archived = store.autoArchiveIdleLittleArcWindows(
            referenceDate: now, threshold: AutoArchiveThreshold.twelveHours.interval, keeping: [key.id])
        XCTAssertEqual(archived, [old.id], "the key window stays, the recent one is not idle yet")
        XCTAssertEqual(store.littleArcArchivedWindows.last?.reason, .auto)
        XCTAssertNotNil(store.littleArcWindow(withID: recent.id))
        XCTAssertNotNil(store.littleArcWindow(withID: key.id))
    }

    func testATouchedLittleArcIsNotIdle() {
        let store = SidebarStore.sample()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let window = store.createLittleArcWindow(url: URL(string: "https://a.example")!, at: start)
        store.touchLittleArcWindow(id: window.id, at: start.addingTimeInterval(20 * 3600))
        XCTAssertEqual(store.autoArchiveIdleLittleArcWindows(referenceDate: start.addingTimeInterval(25 * 3600)), [])
    }

    func testLittleArcArchivePreferenceDefaultsTo24Hours() {
        XCTAssertEqual(LittleArcArchivePreference.load(from: defaults), .oneDay)
        LittleArcArchivePreference.save(.twelveHours, to: defaults)
        XCTAssertEqual(LittleArcArchivePreference.load(from: defaults), .twelveHours)
        defaults.set("fortnight", forKey: LittleArcArchivePreference.defaultsKey)
        XCTAssertEqual(LittleArcArchivePreference.load(from: defaults), .oneDay)
    }

    // MARK: Window, quit and restore

    func testSettingsPanesAreArcsWithoutMaxAndTheLastIsRemembered() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title),
                       ["Account", "General", "Profiles", "Links", "Shortcuts", "Icon", "Advanced"])
        XCTAssertEqual(SettingsPane.load(from: defaults), .general)
        SettingsPane.shortcuts.save(to: defaults)
        XCTAssertEqual(SettingsPane.load(from: defaults), .shortcuts)
        defaults.set("max", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(SettingsPane.load(from: defaults), .general)
    }

    func testQuitWarningAsksOnlyWhenOnWithWindowsOpen() {
        XCTAssertFalse(QuitWarning.isEnabled(in: defaults), "off by default")
        XCTAssertFalse(QuitWarning.shouldAsk(enabled: false, browserWindows: 3))
        XCTAssertFalse(QuitWarning.shouldAsk(enabled: true, browserWindows: 0))
        XCTAssertTrue(QuitWarning.shouldAsk(enabled: true, browserWindows: 1))
        XCTAssertEqual(QuitWarning.message(browserWindows: 1), "You have 1 window open.")
        XCTAssertEqual(QuitWarning.message(browserWindows: 2), "You have 2 windows open.")
    }

    func testRestoreOffKeepsOnlyTheLaunchWindow() {
        XCTAssertTrue(WindowRestorePreference.isEnabled(in: defaults), "on by default, as before the setting")
        defaults.set(false, forKey: WindowRestorePreference.defaultsKey)
        XCTAssertFalse(WindowRestorePreference.isEnabled(in: defaults))

        let display = SavedDisplay(uuid: "d", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
        func window(_ x: CGFloat, key: Bool) -> SavedBrowserWindow {
            var saved = SavedBrowserWindow(frame: CGRect(x: x, y: 0, width: 400, height: 300), display: display)
            saved.isKey = key
            return saved
        }
        let session = WindowSessionSnapshot(windows: [window(10, key: false), window(20, key: true), window(30, key: false)],
                                            lastClosed: window(40, key: false))
        let single = session.launchWindowOnly
        XCTAssertEqual(single.windows.map(\.frame.minX), [20])
        XCTAssertEqual(single.launchWindow?.frame.minX, 20)
        XCTAssertTrue(single.otherWindows.isEmpty)
        XCTAssertEqual(WindowSessionSnapshot(windows: [], lastClosed: window(40, key: false)).launchWindowOnly.launchWindow?.frame.minX, 40)
    }

    // MARK: Chromium settings pages

    func testSettingsWindowPagesAreSettingsSubpages() {
        for page: BrowserInternalPage in [.searchSettings, .downloadSettings, .payments, .notifications, .privacy, .clearBrowsingData] {
            XCTAssertEqual(page.url.host(), "settings", page.rawValue)
            XCTAssertTrue(page.isAvailable(engine: .chromium), page.rawValue)
            XCTAssertFalse(page.isAvailable(engine: []), page.rawValue)
            XCTAssertTrue(BrowserInternalPage.settings.isShown(by: page.url), "reuses an open settings tab")
        }
        XCTAssertEqual(BrowserInternalPage.notifications.url.absoluteString, "chrome://settings/content/notifications")
    }
}
