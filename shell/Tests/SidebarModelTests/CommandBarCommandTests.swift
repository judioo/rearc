import XCTest
@testable import SidebarModel

final class CommandBarCommandTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testCommandsOnlyPrefixListsEnabledCommands() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addTab(kind: .today, title: "Tab", url: url("https://example.com"))
        let results = CommandBarSearch.results(for: ">", in: store)
        XCTAssertTrue(results.allSatisfy { $0.kind == .command })
        XCTAssertTrue(results.contains(where: { $0.title == "New Tab" }))
    }

    func testMinQueryLengthFiltersShortQueries() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addTab(kind: .today, title: "Tab", url: url("https://example.com"))
        store.selectTab(store.displayTabs()[0].id)
        let short = CommandBarSearch.results(for: "> p", in: store)
        XCTAssertFalse(short.contains(where: { $0.title == "Pin Tab" }))
        let long = CommandBarSearch.results(for: "> pi", in: store)
        XCTAssertTrue(long.contains(where: { $0.title == "Pin Tab" }))
    }

    func testKeywordTriggerMatches() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addTab(kind: .today, title: "Tab", url: url("https://example.com"))
        let results = CommandBarSearch.results(for: "> create", in: store)
        XCTAssertTrue(results.contains(where: { $0.title == "Create Space" }))
    }

    func testUsageBumpRanksHigher() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        store.addTab(kind: .today, title: "Tab", url: url("https://example.com"))
        store.bumpCommandUsage("new-tab")
        store.bumpCommandUsage("new-tab")
        store.bumpCommandUsage("create-space")
        let results = CommandBarSearch.results(for: ">", in: store)
        let commandTitles = results.map(\.title)
        let newIndex = commandTitles.firstIndex(of: "New Tab")
        let createIndex = commandTitles.firstIndex(of: "Create Space")
        XCTAssertNotNil(newIndex)
        XCTAssertNotNil(createIndex)
        XCTAssertLessThan(newIndex!, createIndex!)
    }

    func testSeparateFromSplitOnlyWhenInSplit() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        _ = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal)
        store.selectSplit(store.split(withID: store.displayEntries()[0].id)!.id, focusTabID: a.id)
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        XCTAssertTrue(AppCommandRegistry.all(in: context).contains(where: { $0.title == "Separate from Split View" }))

        store.unsplit(store.split(withID: store.displayEntries()[0].id)!.id)
        let context2 = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: store.closedTabStack)
        XCTAssertFalse(AppCommandRegistry.all(in: context2).contains(where: { $0.title == "Separate from Split View" }))
    }

    func testBlendedModeOrdersTabsBeforeCommands() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tab = store.addTab(kind: .today, title: "Pinboard", url: url("https://pinboard.in"))
        store.selectTab(tab.id)
        let results = CommandBarSearch.results(for: "pin", in: store)
        guard let firstTab = results.firstIndex(where: { $0.kind == .openTab }),
              let firstCommand = results.firstIndex(where: { $0.kind == .command }) else {
            return XCTFail("expected tab and command rows")
        }
        XCTAssertLessThan(firstTab, firstCommand)
    }
}
