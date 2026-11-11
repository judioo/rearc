import XCTest
@testable import SidebarModel

/// ⇧/⌘-click selection of sidebar rows (Arc, 2026-11-11 recording): the
/// range and toggle rules, when the selection ends, and the commands on it.
final class MultiSelectionTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private let window = SidebarWindowID()

    private func makeStore() -> SidebarStore {
        let store = SidebarStore(spaces: [
            Space(name: "Personal", sortRank: "a"),
            Space(name: "Work", sortRank: "b"),
        ])
        store.now = { Date(timeIntervalSinceReferenceDate: 800_000_000) }
        store.registerWindow(window)
        store.windowBecameKey(window)
        return store
    }

    /// Pinned: Mail, then a folder holding Docs and Wiki; Today: Google 1…3.
    private struct Fixture {
        let store: SidebarStore
        let mail: Tab, docs: Tab, wiki: Tab, folder: SidebarFolder
        let google: [Tab]
        var space: Space.ID { store.activeSpaceID }

        /// The rows on screen, as the sidebar lays them out.
        var visible: [UUID] {
            SidebarListRow.rows(
                outline: store.outline(for: space), expanded: store.expandedFolderIDs,
                pinnedCollapsed: false, isDragging: false,
                selection: { store.selection(among: $0, inSpace: space) }
            ).compactMap { if case .item(let row, _) = $0 { row.id } else { nil } }
        }
    }

    private func makeFixture() -> Fixture {
        let store = makeStore()
        let mail = store.addTab(kind: .pinned, title: "Mail", url: url("https://mail.test"))
        let docs = store.addTab(kind: .pinned, title: "Docs", url: url("https://docs.test"))
        let wiki = store.addTab(kind: .pinned, title: "Wiki", url: url("https://wiki.test"))
        let folder = store.createFolder(title: "Work", containing: [docs.id, wiki.id])!
        var google: [Tab] = []
        for number in 1 ... 3 {
            let tab = store.addTab(kind: .today, title: "Google \(number)", url: url("https://www.google.com/?q=\(number)"))
            google.append(tab)
        }
        // Today in reading order, whichever end addTab used.
        let order = store.outlineOrder(in: store.activeSpaceID)
        google.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        return Fixture(store: store, mail: mail, docs: docs, wiki: wiki, folder: folder, google: google)
    }

    // MARK: - Pure rules

    func testShiftClickSelectsTheRangeFromTheActiveRow() {
        let ids = (0 ..< 5).map { _ in UUID() }
        var selection = SidebarMultiSelection(spaceID: UUID(), activeID: ids[1])
        selection.extend(to: ids[3], visibleOrder: ids)
        XCTAssertEqual(selection.members, Set(ids[1 ... 3]))
        XCTAssertEqual(selection.anchor, ids[1])
        // Upwards from the same anchor replaces the range.
        selection.extend(to: ids[0], visibleOrder: ids)
        XCTAssertEqual(selection.members, Set(ids[0 ... 1]))
    }

    func testCommandClickTogglesOneRowAndMovesTheAnchor() {
        let ids = (0 ..< 6).map { _ in UUID() }
        var selection = SidebarMultiSelection(spaceID: UUID(), activeID: ids[0])
        selection.toggle(ids[4])
        XCTAssertEqual(selection.members, [ids[0], ids[4]])
        XCTAssertEqual(selection.anchor, ids[4])
        selection.extend(to: ids[2], visibleOrder: ids)
        XCTAssertEqual(selection.members, Set([ids[0]] + ids[2 ... 4]), "the range starts at the ⌘-clicked row")
        selection.toggle(ids[3])
        XCTAssertEqual(selection.members, [ids[0], ids[2], ids[4]])
        selection.toggle(ids[0])
        XCTAssertTrue(selection.contains(ids[0]), "the active row stays selected")
    }

    func testTheActiveRowAloneIsNoSelection() {
        let ids = (0 ..< 3).map { _ in UUID() }
        var selection = SidebarMultiSelection(spaceID: UUID(), activeID: ids[0])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.contains(ids[0]))
        selection.toggle(ids[1])
        selection.toggle(ids[1])
        XCTAssertTrue(selection.isEmpty)
        selection = SidebarMultiSelection(spaceID: selection.spaceID, activeID: ids[0])
        selection.extend(to: ids[0], visibleOrder: ids)
        XCTAssertTrue(selection.isEmpty, "a ⇧-click on the active row selects nothing else")
        selection.extend(to: ids[2], visibleOrder: ids)
        XCTAssertEqual(selection.members, Set(ids))
    }

    func testWithoutAnAnchorOnScreenTheRangeIsTheClickedRow() {
        let ids = (0 ..< 3).map { _ in UUID() }
        // The active item is a favorite: not a row of the list.
        var selection = SidebarMultiSelection(spaceID: UUID(), activeID: UUID())
        selection.extend(to: ids[2], visibleOrder: ids)
        XCTAssertEqual(selection.others, [ids[2]])
        XCTAssertEqual(selection.anchor, ids[2])
        selection.extend(to: ids[0], visibleOrder: ids)
        XCTAssertEqual(selection.others, Set(ids))
    }

    func testMenuTargetsAreTheSelectionOnlyFromInsideIt() {
        let ids = (0 ..< 4).map { _ in UUID() }
        var selection = SidebarMultiSelection(spaceID: UUID(), activeID: ids[0])
        selection.extend(to: ids[2], visibleOrder: ids)
        XCTAssertEqual(SidebarMultiSelection.menuTargets(for: ids[1], selection: selection, order: ids), Array(ids[0 ... 2]))
        XCTAssertEqual(SidebarMultiSelection.menuTargets(for: ids[0], selection: selection, order: ids), Array(ids[0 ... 2]),
                       "the active row is part of it")
        XCTAssertEqual(SidebarMultiSelection.menuTargets(for: ids[3], selection: selection, order: ids), [ids[3]])
        XCTAssertEqual(SidebarMultiSelection.menuTargets(for: ids[3], selection: nil, order: ids), [ids[3]])
    }

    func testCopyFormatIsOneLinkPerLine() {
        let links = [
            (url: url("https://www.google.com/"), title: "Google 1"),
            (url: url("https://www.google.com/"), title: "Google 2"),
            (url: url("https://example.com/a(b)"), title: "Ex [1]"),
        ]
        XCTAssertEqual(PageLinkCopyFormat.plain.text(links: links),
                       "https://www.google.com/\nhttps://www.google.com/\nhttps://example.com/a(b)")
        XCTAssertEqual(PageLinkCopyFormat.markdown.text(links: links),
                       "[Google 1](https://www.google.com/)\n[Google 2](https://www.google.com/)\n[Ex \\[1\\]](https://example.com/a%28b%29)")
        XCTAssertEqual(PageLinkCopyFormat.multipleConfirmation(cleaned: false), "Copied URLs")
        XCTAssertEqual(PageLinkCopyFormat.multipleConfirmation(cleaned: true), "Copied clean links without trackers")
    }

    // MARK: - In the store

    func testRangeRunsAcrossPinnedFoldersAndToday() {
        let f = makeFixture()
        f.store.selectTab(f.wiki.id)
        f.store.extendMultiSelection(to: f.google[1].id, inSpace: f.space, visibleOrder: f.visible, in: window)
        XCTAssertEqual(f.store.multiSelectedIDs(in: window), [f.wiki.id, f.google[0].id, f.google[1].id])
        // From the active row up to the top takes the folder row and Mail.
        f.store.extendMultiSelection(to: f.mail.id, inSpace: f.space, visibleOrder: f.visible, in: window)
        XCTAssertEqual(f.store.multiSelectedIDs(in: window), [f.mail.id, f.folder.id, f.docs.id, f.wiki.id])
        XCTAssertTrue(f.store.isMultiSelected(f.folder.id, in: window), "a folder row selects the folder")
        XCTAssertFalse(f.store.isMultiSelected(f.google[0].id, in: window))
        XCTAssertFalse(f.store.isMultiSelected(f.mail.id, in: SidebarWindowID()), "per window")
        XCTAssertEqual(f.store.selectedTabID, f.wiki.id, "the page does not change")
    }

    func testACollapsedFolderKeepsItsRowsOutOfTheRange() {
        let f = makeFixture()
        f.store.setFolderExpanded(f.folder.id, false)
        f.store.selectTab(f.mail.id)
        f.store.extendMultiSelection(to: f.google[0].id, inSpace: f.space, visibleOrder: f.visible, in: window)
        XCTAssertEqual(f.store.multiSelectedIDs(in: window), [f.mail.id, f.folder.id, f.google[0].id])
    }

    func testSelectionEndsWithAnotherActiveRowOrSpace() {
        let f = makeFixture()
        f.store.selectTab(f.google[0].id)
        f.store.toggleMultiSelection(f.google[2].id, inSpace: f.space, in: window)
        XCTAssertNotNil(f.store.multiSelectedIDs(in: window))
        f.store.selectTab(f.google[1].id)
        XCTAssertNil(f.store.multiSelectedIDs(in: window), "a plain click shows another tab")

        f.store.toggleMultiSelection(f.google[2].id, inSpace: f.space, in: window)
        XCTAssertNotNil(f.store.multiSelection(in: window))
        f.store.clearMultiSelection(in: window)
        XCTAssertNil(f.store.multiSelection(in: window), "Esc or a plain click on the active row")

        f.store.toggleMultiSelection(f.google[2].id, inSpace: f.space, in: window)
        f.store.selectSpace(f.store.spaces[1].id)
        XCTAssertNil(f.store.multiSelection(in: window), "switching space")
    }

    func testClosedArchivedAndMovedRowsLeaveTheSelection() {
        let f = makeFixture()
        let work = f.store.spaces[1].id
        f.store.selectTab(f.mail.id)
        f.store.extendMultiSelection(to: f.google[2].id, inSpace: f.space, visibleOrder: f.visible, in: window)
        f.store.closeTab(f.google[2].id)
        f.store.archiveTab(f.google[1].id)
        XCTAssertTrue(f.store.moveEntry(f.google[0].id, toSpace: work))
        XCTAssertEqual(f.store.multiSelectedIDs(in: window), [f.mail.id, f.folder.id, f.docs.id, f.wiki.id])
        // Reordering within the space keeps a row.
        XCTAssertTrue(f.store.unpinTab(f.docs.id))
        XCTAssertTrue(f.store.isMultiSelected(f.docs.id, in: window))
    }

    func testRowsNotifyOnlyWhenTheyJoinOrLeave() {
        let f = makeFixture()
        f.store.selectTab(f.google[0].id)
        var joined = false, untouched = false
        withObservationTracking { _ = f.store.isMultiSelected(f.google[2].id, in: window) } onChange: { joined = true }
        withObservationTracking { _ = f.store.isMultiSelected(f.mail.id, in: window) } onChange: { untouched = true }
        f.store.toggleMultiSelection(f.google[2].id, inSpace: f.space, in: window)
        XCTAssertTrue(joined)
        XCTAssertFalse(untouched)
    }

    // MARK: - Commands

    func testCloseAsOneBatchReopensTogether() {
        let f = makeFixture()
        let titles = { f.store.outlineOrder(in: f.space).compactMap { f.store.tab(withID: $0)?.title } }
        let before = titles()
        f.store.closeTab(f.mail.id)
        f.store.closingAsOneBatch {
            f.store.closeTab(f.google[0].id)
            f.store.closeTab(f.google[2].id)
        }
        let reopened = f.store.reopenMostRecentClosedBatch()
        XCTAssertEqual(reopened.map(\.title), [f.google[2].title, f.google[0].title], "one ⇧⌘T for the batch")
        XCTAssertEqual(f.store.reopenMostRecentClosedBatch().map(\.title), ["Mail"], "a single close stays single")
        XCTAssertEqual(titles(), before, "each back in its place")
    }

    func testBatchIDsDecodeFromOldRecordsAndRoundTrip() throws {
        let tab = Tab(kind: .today, title: "A", url: url("https://a.test"))
        let record = ClosedTabRecord(tab: tab, spaceID: UUID(), placement: .section(.unpinned, index: 0), batchID: UUID())
        let decoded = try JSONDecoder().decode(ClosedTabRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        old["batchID"] = nil
        let legacy = try JSONDecoder().decode(ClosedTabRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.batchID)
    }

    func testPinAndUnpinKeepTheOrder() {
        let f = makeFixture()
        let ids = f.google.map(\.id)
        XCTAssertEqual(f.store.pinTabs(ids + [f.mail.id]), ids, "pinned tabs are skipped")
        let pinned = f.store.outline(for: f.space).pinned.map(\.id)
        XCTAssertEqual(Array(pinned.suffix(3)), ids)
        XCTAssertEqual(f.store.unpinTabs(ids), ids)
        XCTAssertEqual(Array(f.store.outline(for: f.space).today.map(\.id).prefix(3)), ids)
    }

    func testMoveToSpaceKeepsSectionsOrderAndFolderContents() {
        let f = makeFixture()
        let work = f.store.spaces[1].id
        let moved = f.store.moveEntries([f.mail.id, f.folder.id, f.docs.id, f.google[0].id, f.google[1].id], toSpace: work)
        XCTAssertEqual(Set(moved), [f.mail.id, f.folder.id, f.google[0].id, f.google[1].id], "Docs moves with its folder")
        let outline = f.store.outline(for: work)
        XCTAssertEqual(outline.pinned.map(\.id), [f.mail.id, f.folder.id])
        XCTAssertEqual(outline.today.map(\.id), [f.google[0].id, f.google[1].id])
        XCTAssertEqual(f.store.parentFolderID(of: f.docs.id), f.folder.id)
    }

    func testNewFolderWithSelectionAndMoveToFolder() {
        let f = makeFixture()
        let folder = f.store.createFolder(withSelection: [f.mail.id, f.google[1].id], in: f.space)!
        XCTAssertEqual(f.store.folder(withID: folder.id)?.children.map(\.id), [f.mail.id, f.google[1].id])
        let moved = f.store.moveEntries([f.google[0].id, f.google[2].id, f.folder.id], intoFolder: folder.id)
        XCTAssertEqual(moved, [f.google[0].id, f.google[2].id, f.folder.id])
        XCTAssertEqual(f.store.moveEntries([folder.id], intoFolder: f.folder.id), [], "a folder never goes inside itself")
    }

    func testFavoritesDuplicateAndLinks() {
        let f = makeFixture()
        XCTAssertEqual(f.store.linkTabIDs(for: [f.folder.id, f.wiki.id, f.google[0].id]), [f.docs.id, f.wiki.id, f.google[0].id])
        XCTAssertEqual(f.store.duplicateTabs([f.google[0].id, f.folder.id]).map(\.title), [f.google[0].title])
        XCTAssertEqual(f.store.addTabsToFavorites([f.google[1].id, f.google[2].id]), [f.google[1].id, f.google[2].id])
        XCTAssertEqual(f.store.favorites.suffix(2).map(\.id), [f.google[1].id, f.google[2].id])
    }

    func testOpenInSplitViewTakesTwoToFourTabs() {
        let f = makeFixture()
        XCTAssertFalse(f.store.canSplit(selection: [f.google[0].id]))
        XCTAssertFalse(f.store.canSplit(selection: [f.google[0].id, f.folder.id]), "folders do not split")
        XCTAssertTrue(f.store.canSplit(selection: [f.mail.id, f.google[0].id, f.google[1].id]))
        let split = f.store.split(selection: [f.mail.id, f.google[0].id, f.google[1].id])
        XCTAssertEqual(split?.tabs.map(\.id), [f.mail.id, f.google[0].id, f.google[1].id])
        XCTAssertFalse(f.store.canSplit(selection: [f.mail.id, f.google[2].id]), "a tab already in a split")
    }

    func testDraggedRowsLandTogetherInOrder() {
        let f = makeFixture()
        // Mail and Google 3 dropped after Google 1: Mail unpins, both follow in order.
        XCTAssertEqual(f.store.moveEntries([f.mail.id, f.google[2].id], relativeTo: f.google[0].id, after: true),
                       [f.mail.id, f.google[2].id])
        XCTAssertEqual(f.store.outline(for: f.space).today.map(\.id), [f.google[0].id, f.mail.id, f.google[2].id, f.google[1].id])
        XCTAssertNil(f.store.moveEntries([f.mail.id, f.google[0].id], relativeTo: f.google[0].id, after: false),
                     "the target is one of the rows")
        // Appended to Pinned, folder and its contents as one.
        XCTAssertEqual(f.store.moveEntries([f.google[0].id, f.google[1].id], appendingTo: .section(spaceID: f.space, section: .pinned)),
                       [f.google[0].id, f.google[1].id])
        XCTAssertEqual(f.store.outline(for: f.space).pinned.map(\.id), [f.folder.id, f.google[0].id, f.google[1].id])
    }
}
