import XCTest
@testable import SidebarModel

/// ReArc's mini sidebar (⇧⌘S): the per-window mode, ⌘S leaving it alone,
/// persistence and inheritance, the layout at mini width, the edge's morph,
/// every sidebar part's mini form, and the shortcut that took ⇧⌘S.
final class MiniSidebarTests: XCTestCase {
    private let a = SidebarWindowID()
    private let b = SidebarWindowID()

    // MARK: Mode

    func testToggleSwitchesOnlyThatWindow() {
        var modes = SidebarModes()
        modes.open(a)
        modes.open(b)
        XCTAssertEqual(modes.mode(in: a), .full, "a new window with nothing to copy is full")
        let toggle = modes.toggle(in: a, sidebarVisible: true)
        XCTAssertEqual(toggle, MiniSidebarToggle(mode: .mini, showsSidebar: false))
        XCTAssertEqual(modes.mode(in: a), .mini)
        XCTAssertEqual(modes.mode(in: b), .full, "the other window keeps its mode")
        XCTAssertEqual(modes.toggle(in: a, sidebarVisible: true).mode, .full, "the same keys go back to the full sidebar")
        XCTAssertEqual(modes.mode(in: nil), .full)
    }

    func testCommandSHidingAndShowingKeepsTheMode() {
        var modes = SidebarModes()
        modes.open(a)
        modes.toggle(in: a, sidebarVisible: true)
        // ⌘S changes visibility only (`BrowserViewModel.toggleSidebar`): the
        // hidden sidebar is still mini, and so is the one ⌘S brings back,
        // and the edge reveal floats it in the same mode.
        var visible = true
        for _ in 0 ..< 4 {
            visible.toggle()
            XCTAssertEqual(modes.mode(in: a), .mini, "visible: \(visible)")
            XCTAssertEqual(modes.width(in: a, fullWidth: 260), MiniSidebarLayout.width)
        }
    }

    func testCommandShiftSOnAHiddenSidebarShowsItInTheNewMode() {
        var modes = SidebarModes()
        modes.open(a)
        XCTAssertEqual(modes.toggle(in: a, sidebarVisible: false), MiniSidebarToggle(mode: .mini, showsSidebar: true))
        XCTAssertEqual(modes.toggle(in: a, sidebarVisible: false), MiniSidebarToggle(mode: .full, showsSidebar: true))
    }

    func testTheUsersFullWidthComesBack() {
        var modes = SidebarModes()
        modes.open(a)
        XCTAssertEqual(modes.width(in: a, fullWidth: 312), 312)
        modes.toggle(in: a, sidebarVisible: true)
        XCTAssertEqual(modes.width(in: a, fullWidth: 312), MiniSidebarLayout.width)
        modes.toggle(in: a, sidebarVisible: true)
        XCTAssertEqual(modes.width(in: a, fullWidth: 312), 312, "mini mode never writes the full width")
    }

    func testNewWindowsTakeTheModeOfTheWindowTheyWereOpenedFrom() {
        var modes = SidebarModes()
        modes.open(a)
        modes.toggle(in: a, sidebarVisible: true)
        modes.open(b, openedFrom: a)
        XCTAssertEqual(modes.mode(in: b), .mini)
        let c = SidebarWindowID()
        modes.open(c, openedFrom: SidebarWindowID())
        XCTAssertEqual(modes.mode(in: c), .full, "an unknown parent gives full")
    }

    func testARestoredWindowKeepsItsOwnModeAndRegistersOnce() {
        var modes = SidebarModes()
        modes.open(a)
        modes.toggle(in: a, sidebarVisible: true)
        modes.open(b, restoring: .full, openedFrom: a)
        XCTAssertEqual(modes.mode(in: b), .full, "the saved mode wins over the key window's")
        modes.open(b, openedFrom: a)
        XCTAssertEqual(modes.mode(in: b), .full, "registering again (the view appearing) changes nothing")
        modes.forget(b)
        XCTAssertFalse(modes.isRegistered(b))
        XCTAssertEqual(modes.mode(in: b), .full)
    }

    // MARK: Persistence

    func testTheModeIsSavedPerWindowInTheSession() throws {
        let display = SavedDisplay(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084))
        let mini = SavedBrowserWindow(frame: CGRect(x: 10, y: 10, width: 900, height: 700), display: display, isKey: true, sidebarMode: .mini)
        let full = SavedBrowserWindow(frame: CGRect(x: 40, y: 40, width: 900, height: 700), display: display)
        let data = try WindowSessionFile.encode(WindowSessionSnapshot(windows: [mini, full], lastClosed: mini))
        let decoded = try XCTUnwrap(WindowSessionFile.decode(data))
        XCTAssertEqual(decoded.windows.map(\.sidebarMode), [.mini, nil])
        XCTAssertEqual(decoded.lastClosed?.sidebarMode, .mini)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""sidebarMode" : "mini""#))

        var modes = SidebarModes()
        for window in decoded.windows {
            let id = SidebarWindowID()
            modes.open(id, restoring: window.sidebarMode ?? .full, openedFrom: a)
            XCTAssertEqual(modes.mode(in: id), window.sidebarMode ?? .full)
        }
    }

    func testAFileFromBeforeTheMiniSidebarStillReads() throws {
        let old = #"{"version": 1, "windows": [{"frame": [[0, 0], [800, 600]], "isFullScreen": false, "isZoomed": false, "isKey": true}]}"#
        let snapshot = try XCTUnwrap(WindowSessionFile.decode(Data(old.utf8)))
        XCTAssertNil(snapshot.windows.first?.sidebarMode, "no key: a full sidebar")
        XCTAssertEqual(snapshot.version, WindowSessionSnapshot.currentVersion, "the key is optional, so the schema version stays")
    }

    // MARK: Layout

    func testTheColumnFitsASixteenPointIconWithTheFullSidebarsInsets() {
        XCTAssertEqual(MiniSidebarLayout.width, 52)
        XCTAssertTrue((52 ... 56).contains(MiniSidebarLayout.width))
        let top = MiniSidebarLayout.highlight(depth: 0)
        XCTAssertEqual(top.x, MiniSidebarLayout.rowInset)
        XCTAssertEqual(top.width, MiniSidebarLayout.highlight, "a square highlight")
        XCTAssertEqual(top.width, 36, "the full rows' 36 pt highlight height")
        XCTAssertEqual(MiniSidebarLayout.width - (top.x + top.width), MiniSidebarLayout.rowInset,
                       "8 pt to the page card, as at full width")
        XCTAssertEqual(MiniSidebarLayout.iconX(depth: 0), 18, "the full sidebar's icon x: icons stay put through ⇧⌘S")
        XCTAssertEqual(MiniSidebarLayout.iconLeading * 2 + MiniSidebarLayout.iconSize, MiniSidebarLayout.highlight, "the icon is centred")
    }

    func testFolderChildrenIndentAndKeepAHighlight() {
        XCTAssertEqual(MiniSidebarLayout.iconX(depth: 1), 22)
        XCTAssertEqual(MiniSidebarLayout.iconX(depth: 2), 26)
        XCTAssertEqual(MiniSidebarLayout.iconX(depth: 6), MiniSidebarLayout.iconX(depth: 2), "two levels at most")
        XCTAssertEqual(MiniSidebarLayout.indent(depth: -1), 0)
        let deepest = MiniSidebarLayout.highlight(depth: 9)
        XCTAssertGreaterThanOrEqual(deepest.x + deepest.width, MiniSidebarLayout.iconX(depth: 9) + MiniSidebarLayout.iconSize + 2,
                                    "the icon still sits inside its highlight")
    }

    func testFavoritesStackOnePerRow() {
        let mini = MiniSidebarLayout.favorites(count: 5)
        XCTAssertEqual(mini.columns, 1)
        XCTAssertEqual(mini.rows, 5)
        XCTAssertEqual(mini.tileWidth, 36)
        XCTAssertTrue(mini.stacksVertically)
        let full = FavoritesGridLayout(itemCount: 5, availableWidth: 212)
        XCTAssertFalse(full.stacksVertically)
        XCTAssertFalse(FavoritesGridLayout(itemCount: 1, availableWidth: 212).stacksVertically, "one favorite at full width still drops beside")
    }

    func testTheTrafficLightsLeaveAMiniColumnAsTheyDoWithTheSidebarOnTheRight() {
        XCTAssertTrue(SidebarPlacement(side: .left).trafficLightsInSidebar)
        XCTAssertFalse(SidebarPlacement(side: .left, isMini: true).trafficLightsInSidebar)
        XCTAssertFalse(SidebarPlacement(side: .right, isMini: true).trafficLightsInSidebar)
        XCTAssertEqual(SidebarPlacement(side: .right, isMini: true).inward, -1, "the side's other rules are unchanged")
        let layout = PageCardLayout(isNativeFullscreen: false, isPageFullscreen: false)
        let placement = SidebarPlacement(side: .left, isMini: true)
        XCTAssertEqual(layout.topInset(showsToolbar: false, trafficLightsInSidebar: placement.trafficLightsInSidebar, trafficLightClearance: 38), 38,
                       "without the strip the card starts under the buttons")
    }

    // MARK: Morph

    func testNarrowingLaysThePageOutWideAtOnceAndCutsIt() throws {
        var morph = try XCTUnwrap(SidebarWidthMorph(from: 228, to: 52))
        XCTAssertTrue(morph.isNarrowing)
        XCTAssertEqual(morph.layoutWidth, 52)
        XCTAssertEqual(morph.pageCut, 176, "at the start the card looks where it was")
        XCTAssertEqual(morph.pageOffset, 0)
        morph.shown = 100
        XCTAssertEqual(morph.pageCut, 48)
        morph.shown = 52
        XCTAssertEqual(morph.pageCut, 0)
    }

    func testWideningSlidesThePageAndLaysItOutAtTheEnd() throws {
        var morph = try XCTUnwrap(SidebarWidthMorph(from: 52, to: 228))
        XCTAssertFalse(morph.isNarrowing)
        XCTAssertEqual(morph.layoutWidth, 52)
        XCTAssertEqual(morph.pageOffset, 0)
        morph.shown = 140
        XCTAssertEqual(morph.pageOffset, 88)
        XCTAssertEqual(morph.pageCut, 0)
        morph.shown = 228
        XCTAssertEqual(morph.layoutWidth + morph.pageOffset, 228, "the end matches the narrow layout that follows")
    }

    func testNoMorphWithoutAWidthChangeAndAReversalCarriesOn() throws {
        XCTAssertNil(SidebarWidthMorph(from: 416, to: 416), "in the Library both modes are as wide")
        var narrowing = try XCTUnwrap(SidebarWidthMorph(from: 228, to: 52))
        narrowing.shown = 150
        let back = try XCTUnwrap(SidebarWidthMorph(from: 52, to: 228, current: narrowing))
        XCTAssertEqual(back.from, 150)
        XCTAssertEqual(back.shown, 150)
    }

    // MARK: Every part has a mini form

    func testEveryListRowHasAMiniRepresentation() {
        let tab = SidebarOutlineNode(id: UUID(), kind: .tab)
        let rows: [(SidebarListRow, MiniSidebarRepresentation)] = [
            (.header, .spaceIconMenu),
            (.item(SidebarOutlineRow(node: tab, depth: 0), section: .pinned), .favicon),
            (.item(SidebarOutlineRow(node: tab, depth: 0), section: .unpinned), .favicon),
            (.item(SidebarOutlineRow(node: tab, depth: 2), section: .pinned), .favicon),
            (.item(SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: .folder), depth: 0), section: .pinned), .folderGlyph),
            (.item(SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: .split), depth: 0), section: .unpinned), .splitGlyph),
            (.item(SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: .easel), depth: 0), section: .unpinned), .easelGlyph),
            (.todayDivider, .divider),
            (.newTab, .plus),
            (.sectionEnd(.pinned, isEmpty: true), .dropArea),
        ]
        for (row, expected) in rows {
            XCTAssertEqual(MiniSidebarRepresentation.of(row), expected, "\(row.id)")
        }
    }

    func testEveryOtherSidebarPartHasOne() {
        let expected: [MiniSidebarRepresentation.Part: MiniSidebarRepresentation] = [
            .trafficLights: .trafficLightsOverEmptyRow,
            .navigationButtons: .inCardToolbar, .urlField: .inCardToolbar, .sidebarToggle: .inCardToolbar,
            .profileSwitcher: .inSpaceMenu, .updateBanner: .inSpaceMenu,
            .favorite: .favicon,
            .finishSetup: .spaceIconBadge, .syncAlert: .spaceIconBadge,
            .mediaStrip: .compactMediaIcon, .call: .compactMediaIcon, .liveVideo: .compactMediaIcon,
            .library: .stackedBarButton, .downloads: .stackedBarButton,
            .spaceSwitcher: .currentSpaceSwitcher, .newMenu: .plus,
        ]
        for (part, representation) in expected {
            XCTAssertEqual(MiniSidebarRepresentation.of(part), representation, "\(part)")
        }
        // `of(_:)` switches over every part, so each has a form; this pins the count.
        XCTAssertEqual(MiniSidebarRepresentation.Part.allCases.count, 26)
    }

    func testTheTooltipNamesTheTitleThenTheSite() {
        XCTAssertEqual(MiniSidebarTooltip.text(title: "Inbox (3)", url: URL(string: "https://www.mail.example.com/u/0")),
                       "Inbox (3)\nmail.example.com")
        XCTAssertEqual(MiniSidebarTooltip.text(title: "example.com", url: URL(string: "https://example.com")), "example.com",
                       "no repeated line")
        XCTAssertEqual(MiniSidebarTooltip.text(title: "New Tab", url: URL(string: "about:blank"), isUnloaded: true),
                       "New Tab\nUnloaded — reloads when you open it")
    }

    // MARK: Shortcut

    func testCommandShiftSIsToggleMiniSidebar() throws {
        let binding = try XCTUnwrap(ArcShortcuts.binding(for: .character("s"), modifiers: [.shift, .command]))
        XCTAssertEqual(binding.id, "toggleMiniSidebar")
        XCTAssertEqual(binding.title, "Toggle Mini Sidebar")
        XCTAssertEqual(binding.priority, ArcShortcuts.binding(id: "showSidebar")?.priority, "⌘S's routing: a page that takes the key is asked again")
        XCTAssertEqual(binding.display, "⇧⌘S")
        XCTAssertEqual(ArcShortcuts.binding(for: .character("s"), modifiers: .command)?.id, "showSidebar", "⌘S is unchanged")
        XCTAssertEqual(ShortcutRouting.promptMessage(for: binding), "Press ⇧⌘S again to Toggle Mini Sidebar")
    }

    func testItSitsAfterShowHideSidebarAndTakesSavePageAsKeys() throws {
        let ids = ArcShortcuts.all.map(\.id)
        let sidebar = try XCTUnwrap(ids.firstIndex(of: "showSidebar"))
        XCTAssertEqual(ids[sidebar + 1], "toggleMiniSidebar")
        XCTAssertNil(ArcShortcuts.binding(id: "savePageAs"), "Arc's Save Page As (never implemented in ReArc) gave up ⇧⌘S")
        XCTAssertEqual(ArcShortcuts.yieldedToReArc.map(\.arcID), ["savePageAs"])
        XCTAssertEqual(ArcShortcuts.yieldedToReArc.first?.display, ArcShortcuts.binding(id: "toggleMiniSidebar")?.display)
        XCTAssertTrue(ArcShortcuts.reArcIDs.isSubset(of: Set(ids)))
        XCTAssertFalse(ArcShortcuts.shadowed.contains { $0.id == "toggleMiniSidebar" })
        let sharing = ArcShortcuts.all.filter { $0.key == .character("s") && $0.modifiers == [.shift, .command] }
        XCTAssertEqual(sharing.map(\.id), ["toggleMiniSidebar"], "no other default uses ⇧⌘S")
        XCTAssertNil(SystemShortcuts.owner(of: ShortcutChord(.character("s"), [.shift, .command])))
    }

    func testSettingsListsItAndAUserKeyFollowsItIntoTheMenu() throws {
        var overrides = ShortcutOverrides()
        let row = try XCTUnwrap(overrides.rows(matching: "Mini Sidebar").first)
        XCTAssertEqual(row.id, "toggleMiniSidebar")
        XCTAssertEqual(row.chipText, "⇧⌘S")
        XCTAssertEqual(row.conflicts, [])
        let menuDefault = ShortcutChord(.character("s"), [.shift, .command])
        XCTAssertEqual(overrides.effectiveChord(forDefault: menuDefault), menuDefault)
        let custom = ShortcutChord(.character("m"), [.control, .command])
        overrides.set(custom, for: "toggleMiniSidebar")
        XCTAssertEqual(overrides.effectiveChord(forDefault: menuDefault), custom, "the View menu item takes the user's key")
        XCTAssertEqual(overrides.binding(for: .character("m"), modifiers: [.control, .command])?.id, "toggleMiniSidebar")
        XCTAssertNil(overrides.binding(for: .character("s"), modifiers: [.shift, .command]))
        overrides.unbind("toggleMiniSidebar")
        XCTAssertNil(overrides.effectiveChord(forDefault: menuDefault))
    }

    func testTheCommandBarOffersItWithATitleForTheKeyWindow() throws {
        let store = SidebarStore()
        func command(mini: Bool) -> AppCommand? {
            AppCommandRegistry.all(in: CommandBarContext(store: store, isSidebarVisible: true, isMiniSidebar: mini, closedTabStack: ClosedTabStack()))
                .first { $0.id == "toggle-mini-sidebar" }
        }
        let full = try XCTUnwrap(command(mini: false))
        XCTAssertEqual(full.title, "Show Mini Sidebar")
        XCTAssertEqual(full.action, .toggleMiniSidebar)
        XCTAssertTrue(full.keywords.contains("mini"))
        XCTAssertEqual(command(mini: true)?.title, "Show Full Sidebar")
    }
}

final class MiniSidebarAddressBarTipTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "mini-tip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTheTipIsDueOnceWhileAutoHideIsOff() {
        let defaults = defaults()
        XCTAssertTrue(MiniSidebarAddressBarTip.takeIfDue(in: defaults))
        XCTAssertFalse(MiniSidebarAddressBarTip.takeIfDue(in: defaults))
    }

    func testNoTipWhenTheAddressBarAlreadyHides() {
        let defaults = defaults()
        defaults.set(true, forKey: AutoHideAddressBarPreference.key)
        XCTAssertFalse(MiniSidebarAddressBarTip.takeIfDue(in: defaults))
        // Turned off later, it has still never been shown, so it is due then.
        defaults.set(false, forKey: AutoHideAddressBarPreference.key)
        XCTAssertTrue(MiniSidebarAddressBarTip.takeIfDue(in: defaults))
    }
}
