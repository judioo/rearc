import XCTest
@testable import SidebarModel

final class CommandBarSearchTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testEmptyQueryReturnsNoResults() {
        let store = SidebarStore.sample()
        XCTAssertTrue(CommandBarSearch.results(for: "", in: store).isEmpty)
        XCTAssertTrue(CommandBarSearch.results(for: "   ", in: store).isEmpty)
    }

    func testTabResultsRankFavoritesBeforePinnedBeforeToday() {
        let personal = Space(name: "Personal", theme: .default, iconName: "house.fill")
        let store = SidebarStore(spaces: [personal])
        let favorite = store.addTab(kind: .favorite, title: "GitHub", url: url("https://github.com"))
        let pinned = store.addTab(kind: .pinned, title: "GitHub Docs", url: url("https://docs.github.com"))
        let today = store.addTab(kind: .today, title: "GitHub Issues", url: url("https://github.com/issues"))

        let results = CommandBarSearch.results(for: "github", in: store)
        let tabResults = results.filter { $0.kind == .openTab }
        XCTAssertEqual(tabResults.compactMap(\.tabID), [favorite.id, pinned.id, today.id])
    }

    func testTodayRecencyOrdersNewestFirstWithinTier() {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let older = store.addTab(kind: .today, title: "Alpha docs", url: url("https://alpha.com/docs"))
        let newer = store.addTab(kind: .today, title: "Beta docs", url: url("https://beta.com/docs"))

        let results = CommandBarSearch.results(for: "docs", in: store).filter { $0.kind == .openTab }
        XCTAssertEqual(results.compactMap(\.tabID), [newer.id, older.id])
    }

    func testSearchIncludesTabsFromOtherSpaces() {
        let personal = Space(name: "Personal")
        let work = Space(name: "Work")
        let store = SidebarStore(spaces: [personal, work])
        let workTab = store.addTab(kind: .today, title: "Linear", url: url("https://linear.app"), in: work.id)

        let results = CommandBarSearch.results(for: "linear", in: store)
        XCTAssertTrue(results.contains(where: { $0.tabID == workTab.id && $0.subtitle == "Work" }))
    }

    func testFallbackSearchEntryAfterTabs() {
        let store = SidebarStore(spaces: [Space(name: "Personal")])
        let results = CommandBarSearch.results(for: "hello world", in: store)
        XCTAssertEqual(results.last?.kind, .search)
        XCTAssertEqual(results.last?.destinationURL?.host(), "duckduckgo.com")
    }

    func testFocusTabSwitchesSpace() {
        let personal = Space(name: "Personal")
        let work = Space(name: "Work")
        let store = SidebarStore(spaces: [personal, work])
        let workTab = store.addTab(kind: .today, title: "Work Tab", url: url("https://work.test"), in: work.id)

        XCTAssertTrue(store.focusTab(workTab.id))
        XCTAssertEqual(store.activeSpaceID, work.id)
        XCTAssertEqual(store.selectedTabID, workTab.id)
    }
}
