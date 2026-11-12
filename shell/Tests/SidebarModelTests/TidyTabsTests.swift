import XCTest
@testable import SidebarModel

/// Max › Tidy Tabs' rules (MAX.md §5): groups by site and obvious topic,
/// named sensibly, and an apply that one Undo reverses exactly.
final class TidyTabsTests: XCTestCase {
    private func item(_ title: String, _ host: String) -> TidyTabs.Item {
        TidyTabs.Item(id: UUID(), title: title, host: host)
    }

    func testTopicsGroupSitesOfAKindAndASingleSitesGroupIsNamedAfterIt() {
        let items = [
            item("Pull request #12", "github.com"), item("swift - How to", "stackoverflow.com"),
            item("Cats", "www.youtube.com"), item("More cats", "youtube.com"),
            item("Weather", "weather.example"), item("Inbox", "mail.google.com"),
            item("Budget", "docs.google.com"),
        ]
        let groups = TidyTabs.groups(for: items)
        XCTAssertEqual(groups.map(\.name), ["Code", "YouTube"], "two sites of one kind: the kind; one site: its name")
        XCTAssertEqual(groups[0].members, [items[0].id, items[1].id])
        XCTAssertEqual(groups[1].members, [items[2].id, items[3].id])
        XCTAssertFalse(groups.flatMap(\.members).contains(items[4].id), "a tab alone stays in Today")
    }

    func testTitleWordsMakeATopicAndOtherwiseASiteGroups() {
        let items = [
            item("Flights to Lisbon", "airline-a.example"), item("Cheap hotels in Porto", "rooms.example"),
            item("Ticket 1", "tracker.acme.com"), item("Ticket 2", "tracker.acme.com"), item("Ticket 3", "acme.com"),
        ]
        let groups = TidyTabs.groups(for: items)
        XCTAssertEqual(Set(groups.map(\.name)), ["Travel", "Acme"])
        XCTAssertEqual(groups.first { $0.name == "Acme" }?.members.count, 3, "subdomains are one site")
    }

    func testNothingGroupsWhenNoTwoTabsShareASiteOrTopic() {
        XCTAssertTrue(TidyTabs.groups(for: [item("A", "a.example"), item("B", "b.example"), item("C", "c.example")]).isEmpty)
    }

    func testGroupNamesAreCappedAndUnique() {
        var items: [TidyTabs.Item] = []
        for index in 0 ..< 8 {
            items += [item("x", "site\(index).example"), item("y", "site\(index).example")]
        }
        let groups = TidyTabs.groups(for: items)
        XCTAssertEqual(groups.count, TidyTabs.maximumGroups)
        XCTAssertEqual(Set(groups.map(\.name)).count, groups.count)
    }

    // MARK: The store

    private func store(today: [(String, String)]) -> (SidebarStore, [Tab]) {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let tabs = today.map { store.addTab(kind: .today, title: $0.0, url: URL(string: "https://\($0.1)/")!) }
        return (store, tabs)
    }

    func testTheBroomNeedsMoreThanSixTodayTabs() {
        let (six, _) = store(today: (0 ..< 6).map { ("T\($0)", "github.com") })
        XCTAssertFalse(six.canTidyTabs())
        six.addTab(kind: .today, title: "T6", url: URL(string: "https://github.com/x")!)
        XCTAssertTrue(six.canTidyTabs())
    }

    func testTidyFilesTodaysTabsAndUndoPutsEveryOneBackInOrder() throws {
        let (store, tabs) = store(today: [("Cats", "youtube.com"), ("Weather", "weather.example"), ("PR", "github.com"),
                                          ("Dogs", "youtube.com"), ("Q", "stackoverflow.com"), ("Other", "other.example"),
                                          ("Birds", "youtube.com")])
        let pinned = store.addTab(kind: .pinned, title: "Pinned", url: URL(string: "https://github.com/pinned")!)
        let spaceID = store.activeSpaceID
        let todayBefore = store.content(for: spaceID).today.map(\.id)
        let archivedBefore = store.archivedTabs.count

        let undo = try XCTUnwrap(store.tidyTodayTabs())
        XCTAssertEqual(undo.folderIDs.count, 2)
        let folders = store.folderOutline(in: spaceID).map(\.folder)
        XCTAssertEqual(folders.map(\.title), ["YouTube", "Code"])
        // Today lists the newest first; a folder keeps Today's order.
        XCTAssertEqual(folders[0].children.map(\.id), [tabs[6].id, tabs[3].id, tabs[0].id])
        XCTAssertEqual(store.content(for: spaceID).today.map(\.id), [tabs[5].id, tabs[1].id], "ungrouped tabs stay in Today")
        XCTAssertEqual(store.kind(of: pinned.id), .pinned)
        XCTAssertNil(store.parentFolderID(of: pinned.id), "a pinned tab is left alone")
        XCTAssertEqual(store.archivedTabs.count, archivedBefore, "nothing archived")
        XCTAssertEqual(tabs.compactMap { store.tab(withID: $0.id) }.count, tabs.count, "nothing closed")

        let restored = store.undoTidyTabs(undo)
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(store.content(for: spaceID).today.map(\.id), todayBefore)
        XCTAssertTrue(store.folderOutline(in: spaceID).isEmpty, "the emptied folders go")
        for tab in tabs { XCTAssertNil(store.tab(withID: tab.id)?.savedURL, "back to Today, not pinned") }
    }

    func testSplitsStayAndATabMovedSinceIsNotPulledBack() throws {
        let (store, tabs) = store(today: [("A", "youtube.com"), ("B", "youtube.com"), ("C", "youtube.com"), ("D", "x.example"),
                                          ("E", "y.example"), ("F", "z.example"), ("G", "w.example")])
        let left = store.addTab(kind: .today, title: "L", url: URL(string: "https://youtube.com/l")!)
        let right = store.addTab(kind: .today, title: "R", url: URL(string: "https://youtube.com/r")!)
        let split = try XCTUnwrap(store.splitTab(right.id, with: left.id))
        let undo = try XCTUnwrap(store.tidyTodayTabs())
        XCTAssertNotNil(store.splitContaining(tabID: left.id), "a split is not taken apart")
        XCTAssertNil(store.parentFolderID(of: left.id))
        _ = split
        let folder = try XCTUnwrap(undo.folderIDs.first)
        store.moveItem(tabs[0].id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: 0)
        store.undoTidyTabs(undo)
        XCTAssertEqual(store.kind(of: tabs[0].id), .pinned, "the person moved it since: it stays")
        XCTAssertEqual(store.kind(of: tabs[1].id), .today)
        XCTAssertNil(store.folder(withID: folder))
    }
}
