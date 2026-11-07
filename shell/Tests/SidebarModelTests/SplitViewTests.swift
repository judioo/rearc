import XCTest
@testable import SidebarModel

final class SplitViewTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func makeStoreWithTabs() -> (SidebarStore, Tab, Tab, Tab) {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.com"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.com"))
        let c = store.addTab(kind: .today, title: "C", url: url("https://c.com"))
        return (store, a, b, c)
    }

    func testCreateSplitRemovesTabsFromSection() {
        let (store, a, b, _) = makeStoreWithTabs()
        let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal)
        XCTAssertNotNil(split)
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.count, 2)
        XCTAssertTrue(store.content(for: store.activeSpaceID).today.contains(where: { $0.id == split!.id }))
        XCTAssertNotNil(store.splitContaining(tabID: a.id))
        XCTAssertNotNil(store.tab(withID: a.id))
    }

    func testCreateSplitRejectsCrossSpaceTabs() {
        let work = Space(name: "Work")
        let store = SidebarStore(spaces: [Space(name: "Home"), work])
        let homeTab = store.addTab(kind: .today, title: "H", url: url("https://h.com"))
        let workTab = store.addTab(kind: .today, title: "W", url: url("https://w.com"), in: work.id)
        XCTAssertNil(store.createSplit(tabIDs: [homeTab.id, workTab.id], orientation: .horizontal))
    }

    func testAddTabToSplitUpToFour() {
        let (store, a, b, c) = makeStoreWithTabs()
        let d = store.addTab(kind: .today, title: "D", url: url("https://d.com"))
        guard let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .vertical) else {
            return XCTFail("split")
        }
        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: c.id))
        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: d.id))
        XCTAssertEqual(store.split(withID: split.id)?.tabs.count, 4)
        let e = store.addTab(kind: .today, title: "E", url: url("https://e.com"))
        XCTAssertFalse(store.addTabToSplit(splitID: split.id, tabID: e.id))
    }

    func testAddedPaneTakesAnEqualShare() {
        let (store, a, b, c) = makeStoreWithTabs()
        guard let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal) else {
            return XCTFail("split")
        }
        store.resizeSplitPanes(splitID: split.id, widthFactors: [a.id: 0.75, b.id: 0.25])
        XCTAssertTrue(store.addTabToSplit(splitID: split.id, tabID: c.id))
        let factors = store.split(withID: split.id)?.widthFactors ?? [:]
        XCTAssertEqual(factors[c.id] ?? 0, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(factors[a.id] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(factors[b.id] ?? 0, 1.0 / 6, accuracy: 1e-9)
    }

    func testTwoTabSplitDissolvesOnRemoveTab() {
        let (store, a, b, _) = makeStoreWithTabs()
        guard let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal) else {
            return XCTFail("split")
        }
        XCTAssertTrue(store.removeTabFromSplit(splitID: split.id, tabID: a.id))
        XCTAssertNil(store.split(withID: split.id))
        XCTAssertNotNil(store.locate(a.id))
        XCTAssertNotNil(store.locate(b.id))
    }

    func testUnsplitRestoresTabsToSection() {
        let (store, a, b, _) = makeStoreWithTabs()
        guard let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal) else {
            return XCTFail("split")
        }
        XCTAssertTrue(store.unsplit(split.id))
        XCTAssertNil(store.split(withID: split.id))
        let ids = store.content(for: store.activeSpaceID).today.compactMap { entry -> UUID? in
            if case .tab(let tab) = entry { return tab.id }
            return nil
        }
        XCTAssertTrue(ids.contains(a.id))
        XCTAssertTrue(ids.contains(b.id))
    }

    func testResizeNormalizesWidthFactors() {
        let (store, a, b, c) = makeStoreWithTabs()
        guard let split = store.createSplit(tabIDs: [a.id, b.id, c.id], orientation: .horizontal) else {
            return XCTFail("split")
        }
        store.resizeSplitPanes(splitID: split.id, widthFactors: [
            a.id: 2, b.id: 1, c.id: 1,
        ])
        let factors = store.split(withID: split.id)!.widthFactors
        let sum = [a.id, b.id, c.id].compactMap { factors[$0] }.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.0001)
        XCTAssertEqual(factors[a.id] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testCloseSplitRemovesAllTabs() {
        let (store, a, b, c) = makeStoreWithTabs()
        guard let split = store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal) else {
            return XCTFail("split")
        }
        _ = store.addTab(kind: .today, title: "D", url: url("https://d.com"))
        store.selectSplit(split.id)
        store.closeSplit(split.id)
        XCTAssertNil(store.split(withID: split.id))
        XCTAssertNil(store.tab(withID: a.id))
        XCTAssertNil(store.tab(withID: b.id))
        XCTAssertEqual(store.selectedTabID, c.id)
    }

    func testClosePaneInThreeTabSplitRemovesTabAndKeepsRemainingFocus() throws {
        let (store, a, b, c) = makeStoreWithTabs()
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id, c.id], orientation: .horizontal))
        store.selectSplit(split.id, focusTabID: b.id)

        store.closeTab(b.id)

        XCTAssertNil(store.tab(withID: b.id))
        XCTAssertEqual(store.split(withID: split.id)?.tabs.map(\.id), [a.id, c.id])
        XCTAssertEqual(store.selectedItemID, split.id)
        XCTAssertEqual(store.selectedTabID, c.id)
        XCTAssertFalse(store.makeSnapshot().tabsByID.keys.contains(b.id))
    }

    func testSnapshotRoundTripsSplit() throws {
        let (store, a, b, _) = makeStoreWithTabs()
        _ = store.createSplit(tabIDs: [a.id, b.id], orientation: .vertical)
        let snapshot = store.makeSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertEqual(snapshot.splitsByID.count, 1)
        XCTAssertEqual(snapshot.topAppsContainer.kind, .topApps)

        let loaded = SidebarStore()
        loaded.applySnapshot(snapshot)
        XCTAssertEqual(loaded.content(for: loaded.activeSpaceID).today.filter {
            if case .split = $0 { return true }
            return false
        }.count, 1)
    }
}
