import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 35: the Settings window's wiring: shortcut overrides on the menu bar
/// and the router, the Links switches on the engines, Little Arc's periodic
/// archive, Warn before quitting and the Profiles and Advanced rows.
final class Wave35ShellTests: XCTestCase {
    private final class Presenter: BrowserWindowPresenting {
        var dismissed: [LittleArcWindow.ID] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) { dismissed.append(id) }
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
    }

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w35-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w35-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w35-links-\(UUID().uuidString)")!
        model.shortcutOverrides = ShortcutOverrides()
        return model
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    // MARK: Key equivalents

    func testEveryShellMenuKeyRoundTripsThroughAChord() {
        let model = makeModel()
        let groups = ShellMenus.navigation(model) + ShellMenus.find(model) + ShellMenus.copyLink(model) + ShellMenus.zoom(model)
            + ShellMenus.tabNavigation(model) + ShellMenus.split(model) + ShellMenus.documents(model) + ShellMenus.tabSwitcher(model)
            + ShellMenus.tabPositions(model) + ShellMenus.spaces(model) + ShellMenus.sidebarItems(model) + ShellMenus.library(model)
            + ShellMenus.developer(model) + ShellMenus.capture(model) + ShellMenus.printing(model) + ShellMenus.downloads(model)
        for item in groups.flatMap({ $0 }) where item.key != nil {
            let built = item.appKitKeyEquivalent
            let chord = MenuKeyEquivalents.chord(key: built.key, mask: built.mask)
            XCTAssertNotNil(chord, item.title)
            guard let chord else { continue }
            XCTAssertEqual(chord, ShortcutChord(item.shortcutKey!, ShortcutRouter.modifiers(of: item.modifiers)), item.title)
            let back = MenuKeyEquivalents.keyEquivalent(for: chord)
            XCTAssertEqual(back.key, built.key, item.title)
            XCTAssertEqual(back.mask, built.mask, item.title)
        }
        XCTAssertNil(MenuKeyEquivalents.chord(key: "\u{8}", mask: [.command, .shift]), "⇧⌘⌫ is no Arc chord: left alone")
        XCTAssertEqual(MenuKeyEquivalents.chord(key: "Z", mask: .command), ShortcutChord(.character("z"), [.shift, .command]))
        XCTAssertEqual(MenuKeyEquivalents.chord(key: ":", mask: .command), ShortcutChord(.character(";"), [.shift, .command]))
        XCTAssertEqual(MenuKeyEquivalents.chord(key: "\t", mask: .control), ShortcutChord(.tab, .control))
    }

    func testOverridesRewriteTheMenuBarAndResetPutsArcsKeysBack() {
        let menu = NSMenu()
        let file = NSMenu()
        let newTab = file.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
        let pin = file.addItem(withTitle: "Pin/Unpin Tab", action: nil, keyEquivalent: "d")
        let redo = file.addItem(withTitle: "Redo", action: nil, keyEquivalent: "Z")
        let clear = file.addItem(withTitle: "Clear Browsing Data…", action: nil, keyEquivalent: "\u{8}")
        clear.keyEquivalentModifierMask = [.command, .shift]
        let downloads = file.addItem(withTitle: "Downloads", action: nil, keyEquivalent: "l")
        downloads.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        var overrides = ShortcutOverrides()
        overrides.set(ShortcutChord(.character("k"), [.shift, .command]), for: "newTab")
        overrides.unbind("pinTab")
        overrides.set(ShortcutChord(.character("y"), [.control, .command]), for: "redo")
        let applier = MenuKeyEquivalents()
        applier.apply(overrides, to: menu)
        XCTAssertEqual(newTab.keyEquivalent, "K", "⇧⌘K, stored as AppKit matches it")
        XCTAssertEqual(newTab.keyEquivalentModifierMask, .command)
        XCTAssertEqual(pin.keyEquivalent, "", "unbound")
        XCTAssertEqual(redo.keyEquivalent, "y")
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.control, .command])
        XCTAssertEqual(clear.keyEquivalent, "\u{8}", "not an Arc binding: untouched")
        XCTAssertEqual(downloads.keyEquivalent, "l")
        XCTAssertEqual(downloads.keyEquivalentModifierMask, [.command, .option])

        applier.apply(ShortcutOverrides(), to: menu)
        XCTAssertEqual(newTab.keyEquivalent, "t")
        XCTAssertEqual(newTab.keyEquivalentModifierMask, .command)
        XCTAssertEqual(pin.keyEquivalent, "d")
        XCTAssertEqual(redo.keyEquivalent, "Z")
        XCTAssertEqual(redo.keyEquivalentModifierMask, .command)
    }

    func testChangingAnOverrideSavesItAndTellsTheShell() {
        let model = makeModel()
        var changes = 0
        model.onShortcutOverridesChanged = { changes += 1 }
        model.shortcutOverrides.unbind("pinTab")
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(ShortcutOverrides.load(from: model.externalLinkDefaults).isCustomized("pinTab"))
        model.shortcutOverrides.unbind("pinTab")
        XCTAssertEqual(changes, 1, "no change, no re-apply")
        model.shortcutOverrides.resetAll()
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(ShortcutOverrides.load(from: model.externalLinkDefaults).hasChanges)
    }

    func testTheRouterFollowsOverrides() {
        let model = makeModel()
        let router = model.shortcutRouter
        router.pageHasFocus = { _ in true }
        var ran: [UInt16] = []
        router.performMenuKey = { ran.append($0.keyCode); return true }
        // ⌘L (Open Command Bar) is Arc-wins: taken from the page.
        XCTAssertTrue(router.handleKeyDown(key("l", .command, keyCode: 37)))
        model.shortcutOverrides.set(ShortcutChord(.character("k"), .command), for: "addressBar")
        XCTAssertFalse(router.handleKeyDown(key("l", .command, keyCode: 37)), "⌘L now belongs to nothing: the page gets it")
        XCTAssertTrue(router.handleKeyDown(key("k", .command, keyCode: 40)), "⌘K is Open Command Bar now")
        XCTAssertEqual(ran, [37, 40])
    }

    func testWebKitMenuButtonsUseOverrides() {
        let item = ShellMenuItem("Pin/Unpin Tab", "d") {}
        XCTAssertEqual(item.keyboardShortcut(with: ShortcutOverrides())?.key, KeyEquivalent("d"))
        var overrides = ShortcutOverrides()
        overrides.unbind("pinTab")
        XCTAssertNil(item.keyboardShortcut(with: overrides))
        overrides.set(ShortcutChord(.upArrow, [.option, .shift]), for: "pinTab")
        let moved = item.keyboardShortcut(with: overrides)
        XCTAssertEqual(moved?.key, .upArrow)
        XCTAssertEqual(moved?.modifiers, [.option, .shift])
        XCTAssertNil(ShellMenuItem("Export as PDF…") {}.keyboardShortcut(with: overrides))
    }

    // MARK: Links

    func testShiftClickPeekSwitchReachesTheEngineButKeepsAutomaticPeek() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
        model.store.selectTab(tab.id)
        model.loadSelectedIfNeeded()
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)) as? WKEngine
        XCTAssertEqual(engine?.shiftClickPeekEnabled, true)
        model.peekOnShiftClick = false
        XCTAssertEqual(engine?.shiftClickPeekEnabled, false)
        XCTAssertNotNil(engine?.linkPeekHandler, "automatic Peek still opens off-site links")
        XCTAssertEqual(model.externalLinkDefaults.object(forKey: BrowserViewModel.peekOnShiftClickKey) as? Bool, false)
    }

    func testOptionCommandClickSwitch() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        model.store.selectTab(tab.id)
        model.loadSelectedIfNeeded()
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab)) as? WKEngine
        XCTAssertNotNil(engine?.littleArcLinkHandler)
        model.noteMouseDown(modifiers: [.command, .option])
        model.littleArcOnModifiedClick = false
        XCTAssertNil(engine?.littleArcLinkHandler, "the click follows the link")
        XCTAssertFalse(model.takeLittleArcClick(), "Chromium's new-tab path ignores ⌥⌘ too")
        model.littleArcOnModifiedClick = true
        model.noteMouseDown(modifiers: [.command, .option])
        XCTAssertTrue(model.takeLittleArcClick())
        XCTAssertNotNil(engine?.littleArcLinkHandler)
    }

    func testIdleLittleArcsArchiveOnTheTimerAndTheirWindowsClose() {
        let model = makeModel()
        let presenter = Presenter()
        model.windowPresenter = presenter
        let start = Date(timeIntervalSince1970: 2_000_000)
        let idle = model.store.createLittleArcWindow(url: URL(string: "https://a.test")!, at: start)
        let key = model.store.createLittleArcWindow(url: URL(string: "https://b.test")!, at: start)
        model.keyLittleArcID = key.id
        model.littleArcArchiveAfter = .twelveHours
        XCTAssertEqual(LittleArcArchivePreference.load(from: model.externalLinkDefaults), .twelveHours)
        model.runLittleArcAutoArchive(now: start.addingTimeInterval(13 * 3600))
        XCTAssertEqual(presenter.dismissed, [idle.id])
        XCTAssertNil(model.store.littleArcWindow(withID: idle.id))
        XCTAssertEqual(model.store.littleArcArchivedWindows.last?.reason, .auto)
        XCTAssertNotNil(model.store.littleArcWindow(withID: key.id), "the key window stays")
    }

    func testKeyChangesCountAsLittleArcUse() {
        let model = makeModel()
        let window = model.store.createLittleArcWindow(url: URL(string: "https://a.test")!, at: Date(timeIntervalSince1970: 0))
        model.keyLittleArcID = window.id
        let touched = model.store.littleArcWindow(withID: window.id)?.lastActiveAt ?? .distantPast
        XCTAssertGreaterThan(touched, Date(timeIntervalSince1970: 0))
    }

    // MARK: General, Profiles, Advanced

    func testQuitDoesNotAskWhenTheWarningIsOff() {
        let model = makeModel()
        model.warnBeforeQuitting = false
        XCTAssertTrue(MainActor.assumeIsolated { model.confirmQuit(browserWindows: 3) })
        model.warnBeforeQuitting = true
        XCTAssertTrue(model.externalLinkDefaults.bool(forKey: QuitWarning.defaultsKey))
        XCTAssertTrue(MainActor.assumeIsolated { model.confirmQuit(browserWindows: 0) }, "no windows: nothing to warn about")
    }

    func testSettingsRememberThePaneAndRestoreChoice() {
        let model = makeModel()
        model.settingsPane = .links
        XCTAssertEqual(SettingsPane.load(from: model.externalLinkDefaults), .links)
        var shown: [SettingsPane?] = []
        model.presentSettings = { shown.append($0) }
        model.showSettings(.profiles)
        XCTAssertEqual(model.settingsPane, .profiles)
        XCTAssertEqual(shown, [.profiles])
        model.restoresWindows = false
        XCTAssertFalse(WindowRestorePreference.isEnabled(in: model.externalLinkDefaults))
    }

    func testProfilesPaneAddsWithoutSwitchingAndCountsSpaces() {
        let model = makeModel()
        let active = model.store.activeProfileID
        let added = model.saveProfile(ProfileDraft(name: "Work"), id: nil, selecting: false)!
        XCTAssertEqual(model.store.activeProfileID, active, "Settings' + does not switch profile")
        XCTAssertEqual(added.name, "Work")
        XCTAssertEqual(model.spaceCountText(for: added.id), "1 Space")
        model.store.createSpace(from: SpaceDraft.suggested(in: model.store, profileID: added.id))
        XCTAssertEqual(model.spaceCountText(for: added.id), "2 Spaces")
    }

    func testBoostsSwitchCoversEveryProfile() {
        let model = makeModel()
        let second = model.saveProfile(ProfileDraft(name: "Other"), id: nil, selecting: false)!
        XCTAssertTrue(model.boostsEnabledInAllProfiles)
        model.store.setBoostMasterEnabled(false, profileID: second.id)
        XCTAssertFalse(model.boostsEnabledInAllProfiles, "on only when every profile has them on")
        model.boostsEnabledInAllProfiles = true
        XCTAssertTrue(model.store.profiles.allSatisfy { model.store.boostLibrary(for: $0.id).masterEnabled })
        model.boostsEnabledInAllProfiles = false
        XCTAssertTrue(model.store.profiles.allSatisfy { !model.store.boostLibrary(for: $0.id).masterEnabled })
    }

    func testChromiumPageRowsNeedTheEngine() {
        let model = makeModel()
        for page: BrowserInternalPage in [.settings, .searchSettings, .downloadSettings, .privacy, .payments, .notifications, .clearBrowsingData] {
            XCTAssertFalse(model.canOpenBrowserPage(page), "WebKit has no Chromium pages: \(page.rawValue) row hidden")
        }
    }

    func testSearchEngineSeamFallsBackToWebKitsPreference() {
        let model = makeModel()
        final class Stub: SearchEngineSettings {
            var chosen: [Profile.ID: String] = [:]
            func engines(for profileID: Profile.ID) -> [SearchEngineChoice] { [SearchEngineChoice(id: "g", name: "Google")] }
            func defaultEngine(for profileID: Profile.ID) -> String? { chosen[profileID] }
            func setDefaultEngine(_ id: String, for profileID: Profile.ID) { chosen[profileID] = id }
        }
        let stub = Stub()
        model.searchEngineSettings = stub
        XCTAssertTrue(model.activeSearchEngineSettings === stub, "the engine's own call wins once it exists")
        model.searchEngineSettings = nil
        if model.webKitSearchPreference != nil {
            // The preference is saved to the test process's own defaults: put them back as they were.
            let stored = UserDefaults.standard.object(forKey: SearchProviderPreference.providerKey)
            defer { UserDefaults.standard.set(stored, forKey: SearchProviderPreference.providerKey) }
            let webKit = model.activeSearchEngineSettings
            XCTAssertEqual(webKit?.engines(for: model.store.activeProfileID).map(\.id), SearchProvider.builtIn.map(\.id))
            webKit?.setDefaultEngine(SearchProvider.google.id, for: model.store.activeProfileID)
            XCTAssertEqual(model.webKitSearchPreference?.providerID, SearchProvider.google.id)
        }
    }

    func testIconChoicesFallBackToTheStandardIcon() {
        let defaults = UserDefaults(suiteName: "rearc-w35-icon-\(UUID().uuidString)")!
        XCTAssertEqual(AppIconChoice.load(from: defaults), .standard)
        XCTAssertTrue(AppIconChoice.standard.isAvailable)
        XCTAssertTrue(AppIconChoice.available.contains(.standard))
        defaults.set("nope", forKey: AppIconChoice.defaultsKey)
        XCTAssertEqual(AppIconChoice.load(from: defaults), .standard)
        // Outside a bundle with AppIcons/ the alternates are not offered.
        for choice in AppIconChoice.allCases where !choice.isAvailable {
            choice.save(to: defaults)
            XCTAssertEqual(AppIconChoice.load(from: defaults), .standard, choice.rawValue)
        }
        let shipped = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.appIconsDirectory)) ?? [])
        for choice in AppIconChoice.allCases {
            guard let file = choice.fileName else { continue }
            XCTAssertTrue(shipped.contains("\(file).png"), "shell/Resources/AppIcons has \(file).png")
        }
    }

    private static var appIconsDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcons").path
    }
}
