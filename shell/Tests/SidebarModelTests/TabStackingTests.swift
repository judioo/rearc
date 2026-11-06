import XCTest
@testable import SidebarModel

/// Arc's tab stacking (ARC-RECORDING-2026-11-06 §8): split rows, the
/// four-pane limit, combining by drop and the collection's name.
final class TabStackingTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func makeStore(tabs count: Int) -> (SidebarStore, [Tab]) {
        let store = SidebarStore(spaces: [Space(name: "Demo")])
        let tabs = (0..<count).map { store.addTab(kind: .today, title: "T\($0)", url: url("https://t\($0).example")) }
        return (store, tabs)
    }

    // MARK: Row presentation

    func testRowShowsChipsUntilNamedOrGivenAnIcon() throws {
        let (store, tabs) = makeStore(tabs: 4)
        var split = try XCTUnwrap(store.createSplit(tabIDs: [tabs[0].id, tabs[1].id], orientation: .horizontal))
        XCTAssertFalse(split.showsAsNamedRow)
        XCTAssertTrue(split.showsPaneTitles)
        XCTAssertEqual(split.displayTitle, "2 Tabs")

        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: tabs[2].id))
        XCTAssertTrue(store.split(withID: split.id)!.showsPaneTitles, "three chips keep their titles")
        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: tabs[3].id))
        split = store.split(withID: split.id)!
        XCTAssertFalse(split.showsPaneTitles, "four chips show favicons only")
        XCTAssertEqual(split.displayTitle, "4 Tabs", "the default name follows the pane count")

        XCTAssertTrue(store.setCustomIcon(.emoji("😀"), for: split.id))
        split = store.split(withID: split.id)!
        XCTAssertTrue(split.showsAsNamedRow, "an icon alone collapses the row to icon and name")
        XCTAssertEqual(split.displayTitle, "4 Tabs")

        XCTAssertTrue(store.setCustomIcon(nil, for: split.id))
        XCTAssertFalse(store.split(withID: split.id)!.showsAsNamedRow, "removing the icon brings the chips back")
    }

    // MARK: Rename

    func testRenameNamesTheCollectionAndBlankOrDefaultClearsIt() throws {
        let (store, tabs) = makeStore(tabs: 3)
        let split = try XCTUnwrap(store.createSplit(tabIDs: [tabs[0].id, tabs[1].id], orientation: .horizontal))

        XCTAssertTrue(store.renameSplit(split.id, to: "  the 4 amigos "))
        XCTAssertEqual(store.split(withID: split.id)?.title, "the 4 amigos")
        XCTAssertTrue(store.split(withID: split.id)!.showsAsNamedRow)

        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: tabs[2].id))
        XCTAssertEqual(store.split(withID: split.id)?.displayTitle, "the 4 amigos", "a name doesn't follow the count")

        XCTAssertTrue(store.renameSplit(split.id, to: "3 Tabs"))
        XCTAssertNil(store.split(withID: split.id)?.title, "Arc's default text keeps counting")
        XCTAssertTrue(store.renameSplit(split.id, to: "x"))
        XCTAssertTrue(store.renameSplit(split.id, to: "   "))
        XCTAssertNil(store.split(withID: split.id)?.title)
        XCTAssertFalse(store.renameSplit(UUID(), to: "nope"))
    }

    func testNameSurvivesSnapshotSyncAndReopen() throws {
        let (store, tabs) = makeStore(tabs: 2)
        let split = try XCTUnwrap(store.createSplit(tabIDs: tabs.map(\.id), orientation: .horizontal))
        store.renameSplit(split.id, to: "the 4 amigos")
        store.setCustomIcon(.emoji("😀"), for: split.id)

        let named = try XCTUnwrap(store.split(withID: split.id))
        let decoded = try JSONDecoder().decode(SplitViewItem.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(decoded.title, "the 4 amigos")

        let values = SidebarSyncProjection.splitValues(named)
        XCTAssertEqual(values["title"], .string("the 4 amigos"))
        let synced = try XCTUnwrap(SidebarSyncProjection.makeSplit(id: named.id, values: values, rank: "m"))
        XCTAssertEqual(synced.title, "the 4 amigos")
        XCTAssertEqual(synced.customIcon, .emoji("😀"))

        store.closeSplit(split.id)
        _ = store.reopenMostRecentClosedTab()
        let reopened = try XCTUnwrap(store.content(for: store.activeSpaceID).today.compactMap { entry -> SplitViewItem? in
            if case .split(let split) = entry { return split } else { return nil }
        }.first)
        XCTAssertEqual(reopened.title, "the 4 amigos")
        XCTAssertEqual(reopened.customIcon, .emoji("😀"))
    }

    func testOlderSnapshotsWithoutATitleStillLoad() throws {
        let (store, tabs) = makeStore(tabs: 2)
        let split = try XCTUnwrap(store.createSplit(tabIDs: tabs.map(\.id), orientation: .vertical))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(split)) as? [String: Any])
        XCTAssertNil(object["title"], "an unnamed split writes no title key")
        object["title"] = nil
        let decoded = try JSONDecoder().decode(SplitViewItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.title)
        XCTAssertNil(SidebarSyncProjection.makeSplit(id: split.id, values: SidebarSyncProjection.splitValues(split).filter { $0.key != "title" }, rank: "")?.title)
    }

    // MARK: Combine by drop and the four-pane limit

    func testDroppingATabOnATabRowStacksThemInItsPlace() throws {
        let (store, tabs) = makeStore(tabs: 3)
        XCTAssertTrue(store.canCombineIntoSplit(tabs[2].id, onto: tabs[0].id))
        guard case .combined(let splitID) = store.combineIntoSplit(tabs[2].id, onto: tabs[0].id) else {
            return XCTFail("expected a split")
        }
        let split = try XCTUnwrap(store.split(withID: splitID))
        XCTAssertEqual(split.tabs.map(\.id), [tabs[0].id, tabs[2].id])
        let today = store.content(for: store.activeSpaceID).today.map(\.id)
        XCTAssertEqual(today.firstIndex(of: splitID).map { today.distance(from: today.startIndex, to: $0) },
                       today.firstIndex(of: tabs[1].id).map { today.distance(from: today.startIndex, to: $0) }.map { $0 + 1 },
                       "the split sits where the target tab was")
    }

    func testDroppingOnASplitRowAddsAPaneUntilFourThenSaysItIsFull() throws {
        let (store, tabs) = makeStore(tabs: 5)
        let split = try XCTUnwrap(store.createSplit(tabIDs: [tabs[0].id, tabs[1].id], orientation: .horizontal))
        XCTAssertEqual(store.combineIntoSplit(tabs[2].id, onto: split.id), .combined(split.id))
        XCTAssertEqual(store.split(withID: split.id)?.focusTabID, tabs[2].id, "the new pane gets focus")
        XCTAssertEqual(store.combineIntoSplit(tabs[3].id, onto: split.id), .combined(split.id))
        XCTAssertTrue(store.split(withID: split.id)!.isFull)
        XCTAssertTrue(store.isSplitFull(joining: tabs[0].id))

        XCTAssertTrue(store.canCombineIntoSplit(tabs[4].id, onto: split.id), "a full split still takes the drop to explain")
        XCTAssertEqual(store.combineIntoSplit(tabs[4].id, onto: split.id), .full)
        XCTAssertEqual(store.split(withID: split.id)?.tabs.count, 4)
        XCTAssertEqual(store.kind(of: tabs[4].id), .today, "the fifth tab stays a plain tab")
        XCTAssertFalse(store.canSplit(tabs[4].id, onto: tabs[0].id), "content-edge drops refuse a fifth pane too")
    }

    func testCombineRefusals() throws {
        let work = Space(name: "Work")
        let store = SidebarStore(spaces: [Space(name: "Home"), work])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.example"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.example"))
        let other = store.addTab(kind: .today, title: "W", url: url("https://w.example"), in: work.id)
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.example"))

        XCTAssertFalse(store.canCombineIntoSplit(a.id, onto: a.id))
        XCTAssertFalse(store.canCombineIntoSplit(other.id, onto: a.id), "another space's tab")
        XCTAssertFalse(store.canCombineIntoSplit(favorite.id, onto: a.id))
        XCTAssertFalse(store.canCombineIntoSplit(a.id, onto: favorite.id))
        XCTAssertEqual(store.combineIntoSplit(other.id, onto: a.id), .refused)

        let folder = try XCTUnwrap(store.createFolder(containing: [b.id]))
        XCTAssertFalse(store.canCombineIntoSplit(a.id, onto: b.id), "tabs in folders don't stack")
        XCTAssertFalse(store.canCombineIntoSplit(a.id, onto: folder.id))

        let c = store.addTab(kind: .today, title: "C", url: url("https://c.example"))
        let d = store.addTab(kind: .today, title: "D", url: url("https://d.example"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [c.id, d.id], orientation: .horizontal))
        XCTAssertFalse(store.canCombineIntoSplit(c.id, onto: split.id), "a pane can't join its own split")
        XCTAssertFalse(store.canCombineIntoSplit(split.id, onto: a.id), "a split isn't dragged into a tab")
    }

    func testAPinnedTabDroppedOnATodayRowMovesOverAndStacks() throws {
        let (store, tabs) = makeStore(tabs: 1)
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.example"))
        guard case .combined(let splitID) = store.combineIntoSplit(pinned.id, onto: tabs[0].id) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(store.locateSplit(splitID)?.section, .unpinned)
        XCTAssertTrue(store.content(for: store.activeSpaceID).pinned.isEmpty)
    }
}
