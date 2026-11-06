import XCTest
@testable import SidebarModel

final class ClosedTabStackTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testStackCapacity() {
        var stack = ClosedTabStack()
        let spaceID = UUID()
        for index in 0 ..< 30 {
            stack.push(ClosedTabRecord(
                tab: Tab(kind: .today, title: "T\(index)", url: url("https://t\(index).test")),
                spaceID: spaceID
            ))
        }
        XCTAssertEqual(stack.records.count, ClosedTabStack.capacity)
        XCTAssertEqual(stack.records.first?.tab.title, "T5")
        XCTAssertEqual(stack.records.last?.tab.title, "T29")
    }

    func testCloseTabPushesAndReopenRestores() {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let tab = store.addTab(kind: .today, title: "Gone", url: url("https://gone.test"))
        store.selectTab(tab.id)
        store.closeTab(tab.id)
        XCTAssertTrue(store.closedTabStack.canReopen)
        let restored = store.reopenMostRecentClosedTab()
        XCTAssertEqual(restored?.title, "Gone")
        XCTAssertEqual(store.selectedTabID, restored?.id)
        XCTAssertEqual(store.content(for: space.id).today.count, 1)
    }

    func testV2SnapshotMigratesToV3Fields() throws {
        let store = SidebarStore.sample()
        let data = try JSONEncoder().encode(store.makeSnapshot())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 2
        object.removeValue(forKey: "closedTabStack")
        object.removeValue(forKey: "commandBarUsageBumps")
        let v2Data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: v2Data)
        XCTAssertEqual(decoded.schemaVersion, 10)
        XCTAssertTrue(decoded.closedTabStack.records.isEmpty)
        XCTAssertTrue(decoded.commandBarUsageBumps.isEmpty)
    }

    func testV3RoundTripsBumpsAndClosedStack() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tab = store.addTab(kind: .today, title: "Bye", url: url("https://bye.test"))
        store.closeTab(tab.id)
        store.bumpCommandUsage("close-tab")
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 10)
        XCTAssertEqual(decoded.closedTabStack.records.count, 1)
        XCTAssertEqual(decoded.commandBarUsageBumps["close-tab"], 1)
    }

    // MARK: - P3.3 original placement

    func testReopenRestoresTheOriginalIndexInTodayAndPinned() throws {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let p1 = store.addTab(kind: .pinned, title: "P1", url: url("https://p1.test"))
        let p2 = store.addTab(kind: .pinned, title: "P2", url: url("https://p2.test"))
        let p3 = store.addTab(kind: .pinned, title: "P3", url: url("https://p3.test"))
        let t1 = store.addTab(kind: .today, title: "T1", url: url("https://t1.test"))
        let t2 = store.addTab(kind: .today, title: "T2", url: url("https://t2.test"))
        let t3 = store.addTab(kind: .today, title: "T3", url: url("https://t3.test"))
        store.closeTab(p2.id)
        store.closeTab(t2.id)
        let reopenedToday = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: space.id).today.map(\.id), [t3.id, reopenedToday.id, t1.id])
        let reopenedPinned = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: space.id).pinned.map(\.id), [p1.id, reopenedPinned.id, p3.id])
        XCTAssertEqual(reopenedPinned.kind, .pinned)
        XCTAssertEqual(store.selectedTabID, reopenedPinned.id)
    }

    func testReopenRestoresIntoTheFolderOrFallsBackToPinned() throws {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        let c = store.addTab(kind: .pinned, title: "C", url: url("https://c.test"))
        let folder = try XCTUnwrap(store.createFolder(title: "F", in: space.id, containing: [a.id, b.id, c.id]))
        store.closeTab(b.id)
        let reopened = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.folder(withID: folder.id)?.children.map(\.id), [a.id, reopened.id, c.id])
        XCTAssertTrue(store.isFolderExpanded(folder.id))

        store.closeTab(a.id)
        _ = store.deleteFolder(folder.id, keepingChildren: true)
        let orphan = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: space.id).pinned.last?.id, orphan.id)
        XCTAssertEqual(orphan.kind, .pinned)
    }

    func testReopenRestoresAFavoriteAtItsIndex() throws {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let f1 = store.addTab(kind: .favorite, title: "F1", url: url("https://f1.test"))
        let f2 = store.addTab(kind: .favorite, title: "F2", url: url("https://f2.test"))
        let f3 = store.addTab(kind: .favorite, title: "F3", url: url("https://f3.test"))
        store.closeTab(f2.id)
        XCTAssertTrue(store.closedTabStack.canReopen)
        let reopened = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(reopened.kind, .favorite)
        XCTAssertEqual(store.favorites(in: store.activeProfileID).map(\.id), [f1.id, reopened.id, f3.id])
        XCTAssertEqual(store.selectedTabID, reopened.id)
    }

    func testReopenRejoinsTheSplitPaneOrTakesTheSplitsPlace() throws {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        let c = store.addTab(kind: .today, title: "C", url: url("https://c.test"))
        let other = store.addTab(kind: .today, title: "O", url: url("https://o.test"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id, c.id], orientation: .horizontal))
        store.closeTab(b.id)
        let rejoined = try XCTUnwrap(store.reopenMostRecentClosedTab())
        let restoredSplit = try XCTUnwrap(store.split(withID: split.id))
        XCTAssertEqual(restoredSplit.tabs.map(\.id), [a.id, rejoined.id, c.id])
        XCTAssertEqual(restoredSplit.widthFactors.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(restoredSplit.widthFactors[rejoined.id] ?? 0, 0)
        XCTAssertEqual(store.selectedItemID, split.id)

        // The split is gone by the time the pane comes back: the tab takes its slot.
        store.closeTab(rejoined.id)
        let splitIndex = store.content(for: space.id).today.firstIndex(where: { $0.id == split.id })
        store.unsplit(split.id)
        let standalone = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: space.id).today.firstIndex(where: { $0.id == standalone.id }), splitIndex)
        XCTAssertNil(store.splitContaining(tabID: standalone.id))
        XCTAssertNotNil(store.tab(withID: other.id))
    }

    func testReopenBringsBackAWholeClosedSplit() throws {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .vertical))
        store.setSplitFocus(splitID: split.id, tabID: b.id)
        store.closeSplit(split.id)
        XCTAssertNil(store.tab(withID: a.id))
        let focus = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(focus.title, "B")
        let restored = try XCTUnwrap(store.splitContaining(tabID: focus.id)?.split)
        XCTAssertEqual(restored.tabs.map(\.title), ["A", "B"])
        XCTAssertEqual(restored.orientation, .vertical)
        XCTAssertEqual(restored.focusTabID, focus.id)
        XCTAssertEqual(store.selectedItemID, restored.id)
    }

    func testReopenFallsBackToTheActiveSpaceWhenTheSpaceIsGone() throws {
        let home = Space(name: "Home"), work = Space(name: "Work")
        let store = SidebarStore(spaces: [home, work])
        store.selectSpace(work.id)
        let tab = store.addTab(kind: .today, title: "W", url: url("https://w.test"))
        store.closeTab(tab.id)
        store.selectSpace(home.id)
        XCTAssertTrue(store.removeSpace(work.id))
        let reopened = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: home.id).today.first?.id, reopened.id)
    }

    func testRecordsWithoutPlacementStillDecodeAndReopen() throws {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let existing = store.addTab(kind: .today, title: "Old", url: url("https://old.test"))
        let legacy = #"{"records":[{"spaceID":"\#(space.id.uuidString)","tab":{"id":"\#(UUID().uuidString)","kind":"today","title":"Legacy","url":"https://legacy.test"}}]}"#
        let stack = try JSONDecoder().decode(ClosedTabStack.self, from: Data(legacy.utf8))
        XCTAssertNil(stack.records.first?.placement)
        XCTAssertNil(stack.records.first?.split)
        var snapshot = store.makeSnapshot()
        snapshot.closedTabStack = stack
        store.applySnapshot(snapshot)
        let reopened = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(store.content(for: space.id).today.map(\.id), [reopened.id, existing.id])
    }
}
