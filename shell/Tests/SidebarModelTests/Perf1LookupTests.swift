import Observation
import XCTest
@testable import SidebarModel

/// perf-1: the sorted-content cache and id index follow every mutation, and
/// readers are notified for the entries, spaces and selections they read only.
final class Perf1LookupTests: XCTestCase {

    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    /// Fires `changed` when anything `read` observed changes.
    private final class Probe {
        private(set) var fired = 0
        func watch(_ read: @escaping () -> Void) {
            withObservationTracking(read) { [weak self] in self?.fired += 1 }
        }
    }

    // MARK: - Brute-force reference

    /// The lookups as the linear scans computed them before the index.
    private func scanTab(_ store: SidebarStore, _ id: Tab.ID) -> Tab? {
        for favorites in store.favoritesByProfile.values {
            if let tab = favorites.first(where: { $0.id == id }) { return tab }
        }
        for space in store.spaces {
            let raw = store.contentBySpace[space.id] ?? .init()
            let pinned = SidebarTree.sortedRecursively(raw.pinned), today = SidebarTree.sortedRecursively(raw.today)
            if let tab = SidebarTree.tabs(pinned + today).first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    private func scanParent(_ store: SidebarStore, _ id: UUID) -> SidebarStore.ItemParent? {
        if let owner = store.favoritesByProfile.first(where: { $0.value.contains { $0.id == id } })?.key { return .favorites(owner) }
        for space in store.spaces {
            let raw = store.contentBySpace[space.id] ?? .init()
            if let parent = SidebarTree.parentFolderID(of: id, in: raw.pinned) {
                return parent.map { .folder($0) } ?? .section(spaceID: space.id, section: .pinned)
            }
            if let parent = SidebarTree.parentFolderID(of: id, in: raw.today) {
                return parent.map { .folder($0) } ?? .section(spaceID: space.id, section: .unpinned)
            }
        }
        return nil
    }

    private func assertLookupsMatchScans(_ store: SidebarStore, ids: [UUID], file: StaticString = #filePath, line: UInt = #line) {
        for space in store.spaces {
            let raw = store.contentBySpace[space.id] ?? .init()
            XCTAssertEqual(store.content(for: space.id).pinned, SidebarTree.sortedRecursively(raw.pinned), file: file, line: line)
            XCTAssertEqual(store.content(for: space.id).today, SidebarTree.sortedRecursively(raw.today), file: file, line: line)
        }
        for id in ids {
            XCTAssertEqual(store.tab(withID: id), scanTab(store, id), "tab \(id)", file: file, line: line)
            XCTAssertEqual(store.parent(of: id), scanParent(store, id), "parent \(id)", file: file, line: line)
        }
    }

    // MARK: - Cache invalidation

    func testContentCacheFollowsInsertsMovesAndRanks() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let a = store.spaces[0].id, b = store.spaces[1].id
        let one = store.addTab(kind: .today, title: "1", url: url("one"), in: a)
        XCTAssertEqual(store.content(for: a).today.map(\.id), [one.id])
        let two = store.addTab(kind: .today, title: "2", url: url("two"), in: a)
        XCTAssertEqual(store.content(for: a).today.map(\.id), [two.id, one.id], "a new Today tab goes on top")
        XCTAssertTrue(store.moveItem(one.id, to: .section(spaceID: a, section: .unpinned), index: 0))
        XCTAssertEqual(store.content(for: a).today.map(\.id), [one.id, two.id], "a rank change re-sorts")
        XCTAssertTrue(store.moveTab(two.id, toSpace: b))
        XCTAssertEqual(store.content(for: a).today.map(\.id), [one.id])
        XCTAssertEqual(store.content(for: b).today.map(\.id), [two.id])
        XCTAssertTrue(store.pinTab(one.id))
        XCTAssertEqual(store.content(for: a).pinned.map(\.id), [one.id])
        XCTAssertTrue(store.content(for: a).today.isEmpty)
        XCTAssertTrue(store.removeSpace(b))
        XCTAssertNil(store.tab(withID: two.id), "a deleted space's tabs leave the index")
    }

    func testIndexFollowsTabFieldUpdatesEverywhere() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let favorite = store.addTab(kind: .favorite, title: "Fav", url: url("fav"))
        let pinned = store.addTab(kind: .pinned, title: "Pin", url: url("pin"))
        let left = store.addTab(kind: .today, title: "L", url: url("left"))
        let right = store.addTab(kind: .today, title: "R", url: url("right"))
        let folder = try XCTUnwrap(store.createFolder(title: "F", containing: [pinned.id]))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [left.id, right.id], orientation: .horizontal))

        store.updateTab(favorite.id, title: "Fav 2")
        store.updateTab(pinned.id, title: "Pin 2")
        store.updateTab(right.id, title: "R 2", url: url("right2"))
        XCTAssertEqual(store.tab(withID: favorite.id)?.title, "Fav 2", "an in-place favorites write")
        XCTAssertEqual(store.tab(withID: pinned.id)?.title, "Pin 2", "a tab inside a folder")
        XCTAssertEqual(store.tab(withID: right.id)?.url, url("right2"), "a split pane")
        XCTAssertEqual(store.split(withID: split.id)?.tabs.map(\.title), ["L", "R 2"])
        XCTAssertEqual(store.folder(withID: folder.id)?.children.map(\.id), [pinned.id])
        XCTAssertEqual(store.splitContaining(tabID: left.id)?.split.id, split.id)
        XCTAssertEqual(store.kind(of: favorite.id), .favorite)
        XCTAssertEqual(store.kind(of: pinned.id), .pinned)
        XCTAssertNil(store.entry(withID: left.id), "a pane is not an entry of its own")

        store.selectTab(favorite.id)
        let stamped = try XCTUnwrap(store.tab(withID: favorite.id)?.lastActiveAt)
        store.now = { stamped.addingTimeInterval(60) }
        store.selectTab(pinned.id)
        XCTAssertEqual(store.tab(withID: pinned.id)?.lastActiveAt, stamped.addingTimeInterval(60), "the last-active stamp reaches lookups")

        store.closeTab(pinned.id)
        XCTAssertNil(store.tab(withID: pinned.id))
        XCTAssertNil(store.parent(of: pinned.id))
        XCTAssertTrue(store.unsplit(split.id))
        XCTAssertNil(store.splitContaining(tabID: left.id))
        XCTAssertEqual(store.parent(of: left.id), .section(spaceID: store.activeSpaceID, section: .unpinned))
    }

    func testIndexAgreesWithLinearScansThroughRandomMutations() {
        let fixture = BenchFixture.make(.items300, seed: 7, pageURL: { URL(string: "https://p\($0).test")! })
        let store = fixture.store
        var random = SplitMix64(seed: 11)
        var ids = fixture.tabIDs
        func pick() -> Tab.ID { ids[Int(random.next() % UInt64(ids.count))] }
        assertLookupsMatchScans(store, ids: ids)
        for step in 0 ..< 64 {
            let id = pick()
            switch step % 8 {
            case 0: store.updateTab(id, title: "renamed \(step)")
            case 1: store.selectTab(id)
            case 2: _ = store.moveTab(id, toSpace: fixture.spaceIDs[Int(random.next() % UInt64(fixture.spaceIDs.count))])
            case 3: _ = store.pinTab(id)
            case 4: _ = store.addToFavorites(id)
            case 5: store.closeTab(id); ids.removeAll { $0 == id }
            case 6: ids.append(store.addTab(kind: .today, title: "new \(step)", url: url("n\(step)"), in: fixture.spaceIDs[1]).id)
            default: _ = store.moveTab(id, to: Int(random.next() % 5))
            }
            assertLookupsMatchScans(store, ids: (0 ..< 12).map { _ in pick() } + [id])
        }
        assertLookupsMatchScans(store, ids: ids)
    }

    // MARK: - Fine-grained observation

    func testReadingOneTabIgnoresOtherTabs() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let a = store.addTab(kind: .today, title: "A", url: url("a"))
        let b = store.addTab(kind: .today, title: "B", url: url("b"))
        let probe = Probe()
        probe.watch { _ = store.tab(withID: a.id) }
        store.updateTab(b.id, title: "B 2")
        store.setUnread(true, for: b.id)
        XCTAssertEqual(probe.fired, 0, "another tab's changes")
        store.updateTab(a.id, title: "A 2")
        XCTAssertEqual(probe.fired, 1)
    }

    func testOutlineIgnoresValueChangesButNotStructure() throws {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let space = store.activeSpaceID
        let a = store.addTab(kind: .today, title: "A", url: url("a"))
        let b = store.addTab(kind: .today, title: "B", url: url("b"))
        let outline = Probe(), content = Probe()
        outline.watch { _ = store.outline(for: space) }
        content.watch { _ = store.content(for: space) }
        store.updateTab(a.id, title: "A 2")
        store.selectTab(b.id)
        XCTAssertEqual(outline.fired, 0, "a title, a selection and a last-active stamp keep the rows")
        XCTAssertEqual(content.fired, 1, "content(for:) readers see values")
        XCTAssertTrue(store.moveItem(a.id, to: .section(spaceID: space, section: .unpinned), index: 0))
        XCTAssertEqual(outline.fired, 1, "a move changes the rows")
        XCTAssertEqual(store.outline(for: space).today.map(\.id), [a.id, b.id])
        let folding = Probe()
        folding.watch { _ = store.outline(for: space) }
        _ = try XCTUnwrap(store.createFolder(title: "F", containing: [a.id]))
        XCTAssertEqual(folding.fired, 1)
        XCTAssertEqual(store.outline(for: space).pinned.first?.kind, .folder)
        XCTAssertEqual(store.outline(for: space).pinned.first?.children.map(\.id), [a.id])
    }

    func testSpacesAreObservedSeparately() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let a = store.spaces[0].id, b = store.spaces[1].id
        store.addTab(kind: .today, title: "A", url: url("a"), in: a)
        let probe = Probe()
        probe.watch { _ = store.content(for: a); _ = store.outline(for: a) }
        store.addTab(kind: .today, title: "B", url: url("b"), in: b)
        XCTAssertEqual(probe.fired, 0, "a tab added to another space")
        store.addTab(kind: .today, title: "A2", url: url("a2"), in: a)
        XCTAssertEqual(probe.fired, 1)
    }

    func testMissedLookupWaitsForTheIDToAppear() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let tab = store.addTab(kind: .today, title: "A", url: url("a"))
        store.closeTab(tab.id)
        let probe = Probe()
        probe.watch { XCTAssertNil(store.tab(withID: tab.id)) }
        XCTAssertEqual(store.restoreArchivedTab(tab.id)?.id, tab.id)
        XCTAssertEqual(probe.fired, 1)
        XCTAssertEqual(store.tab(withID: tab.id)?.title, "A")
    }

    func testSelectionNotifiesOnlyTheRowsThatChange() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let space = store.activeSpaceID
        let tabs = (0 ..< 5).map { store.addTab(kind: .today, title: "\($0)", url: url("t\($0)")) }
        store.selectTab(tabs[0].id)
        let probes = tabs.map { tab -> Probe in
            let probe = Probe()
            probe.watch { _ = store.isSelected(tab.id, inSpace: space) }
            return probe
        }
        store.selectTab(tabs[3].id)
        XCTAssertEqual(probes.map(\.fired), [1, 0, 0, 1, 0])
        XCTAssertTrue(store.isSelected(tabs[3].id, inSpace: space))
        XCTAssertFalse(store.isSelected(tabs[0].id, inSpace: space))
    }

    func testRemovingTheSelectionMovesItToTheNextRow() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a")])
        let space = store.activeSpaceID
        let first = store.addTab(kind: .today, title: "1", url: url("one"))
        let second = store.addTab(kind: .today, title: "2", url: url("two"))
        store.selectTab(second.id)
        let probe = Probe()
        probe.watch { _ = store.isSelected(first.id, inSpace: space) }
        store.closeTab(second.id)
        XCTAssertEqual(probe.fired, 1)
        XCTAssertTrue(store.isSelected(first.id, inSpace: space))
    }

    func testBackgroundSpaceSelectionFollowsItsRememberedRow() {
        let store = SidebarStore(spaces: [Space(name: "A", sortRank: "a"), Space(name: "B", sortRank: "b")])
        let a = store.spaces[0].id, b = store.spaces[1].id
        let one = store.addTab(kind: .today, title: "1", url: url("one"), in: a)
        let two = store.addTab(kind: .today, title: "2", url: url("two"), in: a)
        store.selectTab(two.id)
        store.addTab(kind: .today, title: "3", url: url("three"), in: b)
        store.selectSpace(b)
        XCTAssertTrue(store.isSelected(two.id, inSpace: a), "the background space shows its remembered row")
        let probe = Probe()
        probe.watch { _ = store.isSelected(one.id, inSpace: a) }
        store.closeTab(two.id)
        store.settlePendingSelection()
        XCTAssertEqual(probe.fired, 1, "the remembered row went: the space falls back to its first row")
        XCTAssertTrue(store.isSelected(one.id, inSpace: a))
    }
}
