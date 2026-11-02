import XCTest
@testable import SidebarModel

final class SidebarStoreTests: XCTestCase {

    private func makeStore() -> SidebarStore {
        let personal = Space(name: "Personal", theme: SpaceTheme.presets[0], iconName: "house.fill")
        let work = Space(name: "Work", theme: SpaceTheme.presets[1], iconName: "briefcase.fill")
        return SidebarStore(spaces: [personal, work])
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Spaces

    func testStoreAlwaysHasAtLeastOneSpace() {
        let store = SidebarStore()
        XCTAssertEqual(store.spaces.count, 1)
        XCTAssertEqual(store.activeSpaceID, store.spaces[0].id)
    }

    func testAddSpaceAppendsAndDoesNotSwitch() {
        let store = makeStore()
        let originalActive = store.activeSpaceID
        let space = store.addSpace(name: "Gaming")
        XCTAssertEqual(store.spaces.count, 3)
        XCTAssertEqual(store.activeSpaceID, originalActive)
        XCTAssertEqual(store.space(withID: space.id)?.name, "Gaming")
    }

    func testCannotRemoveLastSpace() {
        let store = SidebarStore(spaces: [Space(name: "Only")])
        store.removeSpace(store.spaces[0].id)
        XCTAssertEqual(store.spaces.count, 1)
    }

    func testRemovingActiveSpaceActivatesFirstRemaining() {
        let store = makeStore()
        let second = store.spaces[1]
        store.selectSpace(second.id)
        store.removeSpace(second.id)
        XCTAssertEqual(store.activeSpaceID, store.spaces[0].id)
        XCTAssertNil(store.contentBySpace[second.id])
    }

    func testCycleSpaceWraps() {
        let store = makeStore()
        let first = store.spaces[0].id
        let second = store.spaces[1].id
        store.cycleSpace()
        XCTAssertEqual(store.activeSpaceID, second)
        store.cycleSpace()
        XCTAssertEqual(store.activeSpaceID, first)
        store.cycleSpace(forward: false)
        XCTAssertEqual(store.activeSpaceID, second)
    }

    // MARK: - Adding tabs & section placement

    func testTodayTabsInsertAtTop() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.com"))
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.map(\.id), [b.id, a.id])
    }

    func testPinnedTabsAppendAtEnd() {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.com"))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [a.id, b.id])
    }

    func testFavoritesAreGlobalAcrossSpaces() {
        let store = makeStore()
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        let otherSpace = store.spaces[1].id
        XCTAssertTrue(store.displayTabs(in: otherSpace).contains(where: { $0.id == favorite.id }))
        // Per-space sections are not shared.
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        XCTAssertFalse(store.displayTabs(in: otherSpace).contains(where: { $0.id == pinned.id }))
    }

    func testDisplayOrderIsFavoritesPinnedToday() {
        let store = makeStore()
        let f = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        let p = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        let t = store.addTab(kind: .today, title: "T", url: url("https://t.com"))
        XCTAssertEqual(store.displayTabs().map(\.id), [f.id, p.id, t.id])
    }

    // MARK: - Reorder rules

    func testMoveWithinSectionReorders() {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.com"))
        let c = store.addTab(kind: .pinned, title: "C", url: url("https://c.com"))
        XCTAssertTrue(store.moveTab(c.id, to: 0))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [c.id, a.id, b.id])
    }

    func testMoveClampsOutOfRangeIndices() {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.com"))
        XCTAssertTrue(store.moveTab(a.id, to: 99))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [b.id, a.id])
        XCTAssertTrue(store.moveTab(a.id, to: -5))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [a.id, b.id])
    }

    func testMoveNeverCrossesSectionBoundaries() {
        let store = makeStore()
        let f = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        _ = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        // No destination index can make a favorite land in pinned, because the
        // index is interpreted within the tab's own section.
        XCTAssertTrue(store.moveTab(f.id, to: 99))
        XCTAssertEqual(store.favorites.map(\.id), [f.id])
        XCTAssertEqual(store.kind(of: f.id), .favorite)
    }

    func testMoveUnknownTabReturnsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.moveTab(UUID(), to: 0))
    }

    func testPinMovesTodayTabToEndOfPinned() {
        let store = makeStore()
        let p = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        let t = store.addTab(kind: .today, title: "T", url: url("https://t.com"))
        XCTAssertTrue(store.pinTab(t.id))
        let content = store.content(for: store.activeSpaceID)
        XCTAssertEqual(content.pinned.map(\.id), [p.id, t.id])
        XCTAssertTrue(content.today.isEmpty)
        XCTAssertEqual(store.kind(of: t.id), .pinned)
        XCTAssertEqual(store.tab(withID: t.id)?.kind, .pinned)
    }

    func testUnpinMovesPinnedTabToTopOfToday() {
        let store = makeStore()
        let existing = store.addTab(kind: .today, title: "E", url: url("https://e.com"))
        let p = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        XCTAssertTrue(store.unpinTab(p.id))
        let content = store.content(for: store.activeSpaceID)
        XCTAssertEqual(content.today.map(\.id), [p.id, existing.id])
        XCTAssertTrue(content.pinned.isEmpty)
    }

    func testPinOnlyAppliesToTodayTabsAndViceVersa() {
        let store = makeStore()
        let f = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        let p = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        XCTAssertFalse(store.pinTab(f.id))
        XCTAssertFalse(store.pinTab(p.id))
        XCTAssertFalse(store.unpinTab(f.id))
        let t = store.addTab(kind: .today, title: "T", url: url("https://t.com"))
        XCTAssertFalse(store.unpinTab(t.id))
    }

    // MARK: - Close semantics

    func testClosingSelectedTabSelectsNextInDisplayOrder() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.com"))
        // display order: [b, a] (today inserts at top)
        store.selectTab(b.id)
        store.closeTab(b.id)
        XCTAssertEqual(store.selectedTabID, a.id)
    }

    func testClosingLastTabSelectsPrevious() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.com"))
        // display order: [b, a]
        store.selectTab(a.id)
        store.closeTab(a.id)
        XCTAssertEqual(store.selectedTabID, b.id)
    }

    func testClosingOnlyTabLeavesNoSelection() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        store.selectTab(a.id)
        store.closeTab(a.id)
        XCTAssertNil(store.selectedTabID)
        XCTAssertTrue(store.displayTabs().isEmpty)
    }

    func testClosingUnselectedTabKeepsSelection() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.com"))
        store.selectTab(a.id)
        store.closeTab(b.id)
        XCTAssertEqual(store.selectedTabID, a.id)
    }

    func testClosingFavoriteRemovesItFromEverySpace() {
        let store = makeStore()
        let f = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        store.closeTab(f.id)
        XCTAssertFalse(store.displayTabs(in: store.spaces[1].id).contains(where: { $0.id == f.id }))
    }

    func testCloseTabWorksForTabInNonActiveSpace() {
        let store = makeStore()
        let personalID = store.spaces[0].id
        let workID = store.spaces[1].id
        let workTab = store.addTab(kind: .today, title: "Work only", url: url("https://work.test"), in: workID)
        store.selectSpace(personalID)
        store.closeTab(workTab.id)
        XCTAssertNil(store.tab(withID: workTab.id))
        XCTAssertTrue(store.content(for: workID).today.isEmpty)
    }

    // MARK: - Space switching & selection memory

    func testSpaceSwitchRestoresPerSpaceSelection() {
        let store = makeStore()
        let personalID = store.spaces[0].id
        let workID = store.spaces[1].id

        let pTab = store.addTab(kind: .today, title: "P", url: url("https://p.com"), in: personalID)
        let wTab = store.addTab(kind: .today, title: "W", url: url("https://w.com"), in: workID)

        store.selectSpace(personalID)
        store.selectTab(pTab.id)
        store.selectSpace(workID)
        XCTAssertEqual(store.selectedTabID, wTab.id) // first visit: first tab
        store.selectSpace(personalID)
        XCTAssertEqual(store.selectedTabID, pTab.id) // remembered
        store.selectSpace(workID)
        XCTAssertEqual(store.selectedTabID, wTab.id) // remembered
    }

    func testForgettenSelectionFallsBackWhenTabClosed() {
        let store = makeStore()
        let personalID = store.spaces[0].id
        let workID = store.spaces[1].id
        let pTab = store.addTab(kind: .today, title: "P", url: url("https://p.com"), in: personalID)
        let wTab = store.addTab(kind: .today, title: "W", url: url("https://w.com"), in: workID)
        store.selectTab(pTab.id)
        store.selectSpace(workID)
        store.selectTab(wTab.id)
        // Close the remembered personal tab from under the store.
        store.selectSpace(personalID)
        store.closeTab(pTab.id)
        XCTAssertNil(store.selectedTabID)
        store.selectSpace(workID)
        XCTAssertEqual(store.selectedTabID, wTab.id)
    }

    // MARK: - Next/previous cycling

    func testNextPreviousCyclesWithWraparound() {
        let store = makeStore()
        let f = store.addTab(kind: .favorite, title: "F", url: url("https://f.com"))
        let p = store.addTab(kind: .pinned, title: "P", url: url("https://p.com"))
        let t = store.addTab(kind: .today, title: "T", url: url("https://t.com"))
        // order: [f, p, t]
        store.selectTab(f.id)
        store.selectNextTab()
        XCTAssertEqual(store.selectedTabID, p.id)
        store.selectNextTab()
        XCTAssertEqual(store.selectedTabID, t.id)
        store.selectNextTab()
        XCTAssertEqual(store.selectedTabID, f.id) // wrap
        store.selectPreviousTab()
        XCTAssertEqual(store.selectedTabID, t.id) // wrap backwards
    }

    func testNextWithNoSelectionSelectsFirst() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        XCTAssertNil(store.selectedTabID)
        store.selectNextTab()
        XCTAssertEqual(store.selectedTabID, a.id)
    }

    // MARK: - Unread state

    func testSelectingTabClearsUnread() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        store.setUnread(true, for: a.id)
        XCTAssertEqual(store.tab(withID: a.id)?.isUnread, true)
        store.selectTab(a.id)
        XCTAssertEqual(store.tab(withID: a.id)?.isUnread, false)
    }

    // MARK: - URL entry parsing

    func testURLEntryPassesFullURLsThrough() {
        XCTAssertEqual(URLEntry.resolve("https://example.com/path?q=1")?.absoluteString,
                       "https://example.com/path?q=1")
        XCTAssertEqual(URLEntry.resolve("about:blank")?.absoluteString, "about:blank")
    }

    func testURLEntryPrefixesBareHosts() {
        XCTAssertEqual(URLEntry.resolve("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(URLEntry.resolve("example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(URLEntry.resolve("  sub.example.com/path  ")?.absoluteString, "https://sub.example.com/path")
    }

    func testURLEntrySearchesForPhrases() {
        let resolved = URLEntry.resolve("hello world")
        XCTAssertEqual(resolved?.host(), "duckduckgo.com")
        XCTAssertTrue(resolved?.absoluteString.contains("q=hello%20world") ?? false)
        // A host-like string with a space is a search, not a URL.
        XCTAssertEqual(URLEntry.resolve("example.com/a b")?.host(), "duckduckgo.com")
    }

    func testURLEntryRejectsEmptyInput() {
        XCTAssertNil(URLEntry.resolve(""))
        XCTAssertNil(URLEntry.resolve("   "))
    }

    // MARK: - Update

    func testUpdateTabChangesTitleURLAndFaviconToken() {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "Old", url: url("https://old.com"))
        store.updateTab(a.id, title: "New", url: url("https://newsite.io"))
        let tab = store.tab(withID: a.id)
        XCTAssertEqual(tab?.title, "New")
        XCTAssertEqual(tab?.url, url("https://newsite.io"))
        XCTAssertEqual(tab?.faviconToken, "N")
    }
}
