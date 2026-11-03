import XCTest
@testable import SidebarModel

/// Wave 17: folders, per-profile favorites, drag placement, archive and
/// auto-archive, space management (docs/PARITY-AUDIT.md P0 sidebar items).
final class Wave17SidebarTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func makeStore(clock: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> SidebarStore {
        let store = SidebarStore(spaces: [
            Space(name: "Personal", sortRank: "a"),
            Space(name: "Work", sortRank: "b"),
        ])
        store.now = { clock }
        return store
    }

    private func journal(_ store: SidebarStore) -> [SidebarJournalMutation] {
        store.mutationJournal.allEntries().map(\.mutation)
    }

    private func roundTrip(_ store: SidebarStore) throws -> SidebarStore {
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        let restored = SidebarStore()
        restored.now = store.now
        restored.applySnapshot(decoded)
        return restored
    }

    // MARK: - Folders

    func testCreateFolderAppendsToPinnedExpandedAndJournals() throws {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        let folder = try XCTUnwrap(store.createFolder(title: "  Reading  "))
        let content = store.content(for: store.activeSpaceID)
        XCTAssertEqual(content.pinned.map(\.id), [pinned.id, folder.id])
        XCTAssertEqual(folder.title, "Reading")
        XCTAssertTrue(store.isFolderExpanded(folder.id))
        XCTAssertTrue(journal(store).contains(.insertItem(
            id: folder.id, spaceID: store.activeSpaceID, container: .pinned, sortRank: folder.sortRank
        )))
    }

    func testCreateFolderContainingTodayTabPinsIt() throws {
        let store = makeStore()
        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [today.id]))
        XCTAssertEqual(folder.children.map(\.id), [today.id])
        XCTAssertEqual(store.kind(of: today.id), .pinned)
        XCTAssertEqual(store.parentFolderID(of: today.id), folder.id)
        XCTAssertTrue(store.content(for: store.activeSpaceID).today.isEmpty)
        XCTAssertTrue(journal(store).contains { mutation in
            if case .placeItemInFolder(today.id, folder.id, _) = mutation { return true }
            return false
        })
    }

    func testNestedFoldersOutlineAndCycleGuard() throws {
        let store = makeStore()
        let outer = try XCTUnwrap(store.createFolder(title: "Outer"))
        let inner = try XCTUnwrap(store.createFolder(title: "Inner", parentFolderID: outer.id))
        let deepest = try XCTUnwrap(store.createFolder(title: "Deepest", parentFolderID: inner.id))
        let outline = store.folderOutline()
        XCTAssertEqual(outline.map(\.folder.id), [outer.id, inner.id, deepest.id])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2])
        // A folder cannot move into itself or a descendant.
        XCTAssertFalse(store.moveItem(outer.id, to: .folder(outer.id), index: 0))
        XCTAssertFalse(store.moveItem(outer.id, to: .folder(deepest.id), index: 0))
        // Moving the inner folder out to section level is fine.
        XCTAssertTrue(store.moveItem(inner.id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: 0))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [inner.id, outer.id])
        XCTAssertEqual(store.folder(withID: inner.id)?.children.map(\.id), [deepest.id])
    }

    func testFolderChildrenAreSelectableInDisplayOrder() throws {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        let c = store.addTab(kind: .today, title: "C", url: url("https://c.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [b.id]))
        XCTAssertEqual(store.displayEntries().map(\.id), [a.id, b.id, c.id])
        XCTAssertFalse(store.displayEntries().contains { $0.id == folder.id })
        store.selectTab(a.id)
        store.selectNextTab()
        XCTAssertEqual(store.selectedItemID, b.id)
        XCTAssertEqual(store.tab(withID: b.id)?.title, "B")
        XCTAssertEqual(store.spaceContaining(tabID: b.id), store.activeSpaceID)
    }

    func testDragIntoAndOutOfFolderChangesKind() throws {
        let store = makeStore()
        let folder = try XCTUnwrap(store.createFolder())
        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        XCTAssertTrue(store.moveItem(today.id, to: .folder(folder.id), index: 0))
        XCTAssertEqual(store.kind(of: today.id), .pinned)
        XCTAssertTrue(store.moveItem(today.id, to: .section(spaceID: store.activeSpaceID, section: .unpinned), index: 0))
        XCTAssertEqual(store.kind(of: today.id), .today)
        XCTAssertNil(store.parentFolderID(of: today.id))
        XCTAssertEqual(store.folder(withID: folder.id)?.children.count, 0)
    }

    func testPlacementRules() throws {
        let store = makeStore()
        let folder = try XCTUnwrap(store.createFolder())
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        // Today holds no folders; favorites hold only plain tabs; folders hold no splits.
        XCTAssertFalse(store.moveItem(folder.id, to: .section(spaceID: store.activeSpaceID, section: .unpinned), index: 0))
        XCTAssertFalse(store.moveItem(folder.id, to: .favorites(nil), index: 0))
        XCTAssertFalse(store.moveItem(split.id, to: .folder(folder.id), index: 0))
        XCTAssertFalse(store.moveItem(split.id, to: .favorites(nil), index: 0))
        // Split panes move only with their split.
        XCTAssertFalse(store.moveItem(a.id, to: .folder(folder.id), index: 0))
        // A split can be pinned by drag; its panes become pinned.
        XCTAssertTrue(store.moveItem(split.id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: 0))
        XCTAssertEqual(store.split(withID: split.id)?.tabs.map(\.kind), [.pinned, .pinned])
        XCTAssertEqual(store.locateSplit(split.id)?.section, .pinned)
    }

    func testRenameFolder() throws {
        let store = makeStore()
        let folder = try XCTUnwrap(store.createFolder())
        XCTAssertFalse(store.renameFolder(folder.id, to: "   "))
        XCTAssertTrue(store.renameFolder(folder.id, to: "Projects"))
        XCTAssertEqual(store.folder(withID: folder.id)?.title, "Projects")
        XCTAssertEqual(journal(store).last, .upsertItem(id: folder.id))
    }

    func testDeleteFolderKeepingChildrenPutsThemWhereTheFolderWas() throws {
        let store = makeStore()
        let first = store.addTab(kind: .pinned, title: "1", url: url("https://1.test"))
        let x = store.addTab(kind: .pinned, title: "X", url: url("https://x.test"))
        let y = store.addTab(kind: .pinned, title: "Y", url: url("https://y.test"))
        let last = store.addTab(kind: .pinned, title: "9", url: url("https://9.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [x.id, y.id]))
        XCTAssertTrue(store.moveItem(folder.id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: 1))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [first.id, folder.id, last.id])
        XCTAssertEqual(store.deleteFolder(folder.id, keepingChildren: true), [])
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [first.id, x.id, y.id, last.id])
        XCTAssertNil(store.folder(withID: folder.id))
        XCTAssertFalse(store.isFolderExpanded(folder.id))
    }

    func testDeleteFolderWithContentsArchivesTabsAndMovesSelection() throws {
        let store = makeStore()
        let keep = store.addTab(kind: .pinned, title: "Keep", url: url("https://keep.test"))
        let inside = store.addTab(kind: .pinned, title: "Inside", url: url("https://inside.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [inside.id]))
        _ = try XCTUnwrap(store.createFolder(parentFolderID: folder.id))
        store.selectTab(inside.id)
        XCTAssertEqual(store.deleteFolder(folder.id, keepingChildren: false), [inside.id])
        XCTAssertNil(store.tab(withID: inside.id))
        XCTAssertEqual(store.selectedItemID, keep.id)
        XCTAssertEqual(store.archivedTabs.map(\.id), [inside.id])
        XCTAssertTrue(store.folderOutline().isEmpty)
    }

    func testExpandCollapseAndRevealOnFocus() throws {
        let store = makeStore()
        let tab = store.addTab(kind: .pinned, title: "T", url: url("https://t.test"))
        let outer = try XCTUnwrap(store.createFolder())
        let inner = try XCTUnwrap(store.createFolder(parentFolderID: outer.id, containing: [tab.id]))
        store.toggleFolderExpanded(inner.id)
        XCTAssertFalse(store.isFolderExpanded(inner.id))
        store.setAllFoldersExpanded(false)
        XCTAssertTrue(store.expandedFolderIDs.isEmpty)
        XCTAssertTrue(store.focusTab(tab.id))
        XCTAssertTrue(store.isFolderExpanded(outer.id))
        XCTAssertTrue(store.isFolderExpanded(inner.id))
        store.setAllFoldersExpanded(false)
        store.setAllFoldersExpanded(true)
        XCTAssertEqual(store.expandedFolderIDs, [outer.id, inner.id])
    }

    func testDropTabOnTabCreatesFolderAtTargetPosition() throws {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let target = store.addTab(kind: .pinned, title: "Target", url: url("https://target.test"))
        let z = store.addTab(kind: .pinned, title: "Z", url: url("https://z.test"))
        let dragged = store.addTab(kind: .today, title: "Dragged", url: url("https://dragged.test"))
        let folder = try XCTUnwrap(store.createFolder(grouping: target.id, with: dragged.id))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [a.id, folder.id, z.id])
        XCTAssertEqual(folder.children.map(\.id), [target.id, dragged.id])
        XCTAssertEqual(store.kind(of: dragged.id), .pinned)

        // A Today target makes the folder at the end of Pinned.
        let t1 = store.addTab(kind: .today, title: "T1", url: url("https://t1.test"))
        let t2 = store.addTab(kind: .today, title: "T2", url: url("https://t2.test"))
        let second = try XCTUnwrap(store.createFolder(grouping: t1.id, with: t2.id))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.last?.id, second.id)
        XCTAssertNil(store.createFolder(grouping: t1.id, with: t1.id))
    }

    func testNestedTabOperations() throws {
        let store = makeStore()
        let other = store.spaces[1].id
        let tab = store.addTab(kind: .pinned, title: "Old", url: url("https://old.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [tab.id]))
        store.updateTab(tab.id, title: "New", url: url("https://new.test"))
        XCTAssertEqual(store.tab(withID: tab.id)?.title, "New")
        XCTAssertEqual(store.tab(withID: tab.id)?.faviconToken, "N")
        XCTAssertEqual(store.kind(of: tab.id), .pinned)
        XCTAssertTrue(store.unpinTab(tab.id))
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.first?.id, tab.id)
        XCTAssertTrue(store.moveItem(tab.id, to: .folder(folder.id), index: 0))
        XCTAssertTrue(store.moveTab(tab.id, toSpace: other))
        XCTAssertEqual(store.content(for: other).today.map(\.id), [tab.id])
        XCTAssertEqual(store.folder(withID: folder.id)?.children.count, 0)
        XCTAssertTrue(journal(store).contains { mutation in
            if case .moveItem(tab.id, other, .unpinned, _) = mutation { return true }
            return false
        })
    }

    func testClosingTabInsideFolder() throws {
        let store = makeStore()
        let tab = store.addTab(kind: .pinned, title: "T", url: url("https://t.test"))
        let folder = try XCTUnwrap(store.createFolder(containing: [tab.id]))
        store.closeTab(tab.id)
        XCTAssertNil(store.tab(withID: tab.id))
        XCTAssertEqual(store.folder(withID: folder.id)?.children.count, 0)
        XCTAssertTrue(store.closedTabStack.canReopen)
    }

    func testFolderTreeSurvivesSnapshotRoundTrip() throws {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        let outer = try XCTUnwrap(store.createFolder(title: "Outer", containing: [a.id]))
        let inner = try XCTUnwrap(store.createFolder(title: "Inner", parentFolderID: outer.id, containing: [b.id]))
        store.setFolderExpanded(inner.id, false)
        let restored = try roundTrip(store)
        XCTAssertEqual(restored.content(for: store.activeSpaceID), store.content(for: store.activeSpaceID))
        XCTAssertEqual(restored.folder(withID: inner.id)?.title, "Inner")
        XCTAssertEqual(restored.folder(withID: outer.id)?.children.map(\.id), [a.id, inner.id])
        XCTAssertEqual(restored.expandedFolderIDs, [outer.id])
    }

    func testCorruptFolderCycleDoesNotHang() throws {
        let store = makeStore()
        let folder = try XCTUnwrap(store.createFolder(title: "Loop"))
        var snapshot = store.makeSnapshot()
        snapshot.foldersByID[folder.id]?.childIDs = [folder.id]
        let restored = SidebarStore()
        restored.applySnapshot(snapshot)
        XCTAssertEqual(restored.folder(withID: folder.id)?.children, [])
    }

    // MARK: - Favorites

    func testFavoritesAreKeyedByProfile() {
        let store = makeStore()
        let mine = store.addTab(kind: .favorite, title: "Mine", url: url("https://mine.test"))
        let firstProfile = store.activeProfileID
        let second = store.addProfile(name: "Work")
        store.selectProfile(second.id)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertFalse(store.displayEntries().contains { $0.id == mine.id })
        let theirs = store.addTab(kind: .favorite, title: "Theirs", url: url("https://theirs.test"))
        XCTAssertEqual(store.favorites(in: firstProfile).map(\.id), [mine.id])
        XCTAssertEqual(store.favorites(in: second.id).map(\.id), [theirs.id])
        XCTAssertEqual(store.favoriteOwner(of: theirs.id), second.id)
        XCTAssertNotEqual(store.topAppsContainerID(for: firstProfile), store.topAppsContainerID(for: second.id))
        // Focusing a favorite of another profile switches to that profile.
        XCTAssertTrue(store.focusTab(mine.id))
        XCTAssertEqual(store.activeProfileID, firstProfile)
        XCTAssertEqual(store.deleteProfile(second.id, deletingSpaces: true), nil)
        XCTAssertNil(store.tab(withID: theirs.id))
    }

    func testAddToFavoritesAndUnfavoriteByDrag() {
        let store = makeStore()
        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        XCTAssertTrue(store.addToFavorites(today.id))
        XCTAssertEqual(store.kind(of: today.id), .favorite)
        XCTAssertEqual(store.favorites.map(\.id), [today.id])
        XCTAssertTrue(store.content(for: store.activeSpaceID).today.isEmpty)
        XCTAssertTrue(journal(store).contains { mutation in
            if case .moveItem(today.id, nil, .favorite, _) = mutation { return true }
            return false
        })
        XCTAssertFalse(store.addToFavorites(today.id), "already a favorite")
        XCTAssertTrue(store.moveItem(today.id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: 0))
        XCTAssertEqual(store.kind(of: today.id), .pinned)
        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testUnloadFavoriteKeepsItAndMovesSelection() {
        let store = makeStore()
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.test"))
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        store.selectTab(favorite.id)
        XCTAssertTrue(store.unloadFavorite(favorite.id))
        XCTAssertEqual(store.favorites.map(\.id), [favorite.id])
        XCTAssertEqual(store.selectedItemID, pinned.id)
        XCTAssertFalse(store.unloadFavorite(pinned.id))
    }

    func testSchema9GlobalFavoritesMigrateToDefaultProfile() throws {
        let store = makeStore()
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.test"))
        let defaultProfile = store.activeProfileID
        let second = store.addProfile(name: "Second")
        let data = try JSONEncoder().encode(store.makeSnapshot())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 9
        for key in ["topAppsContainersByProfileID", "foldersByID", "expandedFolderIDs", "archivedTabs",
                    "autoArchiveThresholdByProfile"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try JSONDecoder().decode(SidebarSnapshot.self, from: legacy)
        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertEqual(snapshot.topAppsContainersByProfileID[defaultProfile]?.childIDs, [favorite.id])
        let restored = SidebarStore()
        restored.applySnapshot(snapshot)
        XCTAssertEqual(restored.favorites(in: defaultProfile).map(\.id), [favorite.id])
        XCTAssertTrue(restored.favorites(in: second.id).isEmpty)
    }

    // MARK: - Pin / unpin by drag

    func testCrossSectionDragPinsAndUnpinsAtIndex() {
        let store = makeStore()
        let space = store.activeSpaceID
        let p1 = store.addTab(kind: .pinned, title: "P1", url: url("https://p1.test"))
        let p2 = store.addTab(kind: .pinned, title: "P2", url: url("https://p2.test"))
        let t = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        XCTAssertTrue(store.moveItem(t.id, to: .section(spaceID: space, section: .pinned), index: 1))
        XCTAssertEqual(store.content(for: space).pinned.map(\.id), [p1.id, t.id, p2.id])
        XCTAssertEqual(store.kind(of: t.id), .pinned)
        XCTAssertTrue(store.moveEntry(p2.id, to: 0, in: space, section: .unpinned))
        XCTAssertEqual(store.kind(of: p2.id), .today)
        XCTAssertEqual(store.content(for: space).today.map(\.id), [p2.id])
    }

    // MARK: - Archive

    func testCloseArchivesAndReopenRemovesTheRecord() {
        let store = makeStore()
        let tab = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        store.closeTab(tab.id)
        XCTAssertEqual(store.archivedTabs.map(\.id), [tab.id])
        XCTAssertEqual(store.archivedTabs.first?.reason, .manual)
        XCTAssertNotNil(store.reopenMostRecentClosedTab())
        XCTAssertTrue(store.archivedTabs.isEmpty)
        // Blank tabs are not archived.
        let blank = store.addTab(kind: .today, title: "New Tab", url: url("about:blank"))
        store.closeTab(blank.id)
        XCTAssertTrue(store.archivedTabs.isEmpty)
    }

    func testArchiveAndRestoreIsLossless() throws {
        let store = makeStore()
        let other = store.spaces[1].id
        store.selectSpace(other)
        let tab = store.addTab(kind: .pinned, title: "Page", url: url("https://page.test"))
        store.renameTab(tab.id, to: "Mine")
        store.selectSpace(store.spaces[0].id)
        let record = try XCTUnwrap(store.archiveTab(tab.id))
        XCTAssertEqual(record.spaceID, other)
        XCTAssertNil(store.tab(withID: tab.id))
        let restored = try XCTUnwrap(store.restoreArchivedTab(tab.id))
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.kind, .today)
        XCTAssertEqual(restored.displayTitle, "Mine")
        XCTAssertEqual(store.activeSpaceID, other)
        XCTAssertEqual(store.selectedItemID, tab.id)
        XCTAssertTrue(store.archivedTabs.isEmpty)
        XCTAssertNil(store.archiveTab(UUID()))
    }

    func testAutoArchiveUsesPerProfileThresholdAndSparesSelection() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var clock = start
        let store = makeStore()
        store.now = { clock }
        let idle = store.addTab(kind: .today, title: "Idle", url: url("https://idle.test"))
        let selected = store.addTab(kind: .today, title: "Selected", url: url("https://selected.test"))
        let pinned = store.addTab(kind: .pinned, title: "Pinned", url: url("https://pinned.test"))
        store.selectTab(selected.id)
        XCTAssertEqual(store.autoArchiveThreshold(), .twelveHours)

        clock = start.addingTimeInterval(11 * 3600)
        XCTAssertEqual(store.autoArchiveIdleTodayTabs(), [])
        clock = start.addingTimeInterval(12 * 3600)
        XCTAssertEqual(store.autoArchiveIdleTodayTabs(), [idle.id])
        XCTAssertEqual(store.archivedTabs.last?.reason, .auto)
        XCTAssertNotNil(store.tab(withID: selected.id))
        XCTAssertNotNil(store.tab(withID: pinned.id))

        // A second profile with a 7-day threshold keeps its idle tab.
        let second = store.addProfile(name: "Slow")
        store.setAutoArchiveThreshold(.sevenDays, for: second.id)
        let slowSpace = store.spaces(in: second.id)[0].id
        let slow = store.addTab(kind: .today, title: "Slow", url: url("https://slow.test"), in: slowSpace)
        clock = clock.addingTimeInterval(2 * 86_400)
        XCTAssertFalse(store.autoArchiveIdleTodayTabs().contains(slow.id))
        clock = clock.addingTimeInterval(6 * 86_400)
        XCTAssertTrue(store.autoArchiveIdleTodayTabs().contains(slow.id))
    }

    func testThresholdAndArchiveSurviveSnapshot() throws {
        let store = makeStore()
        store.setAutoArchiveThreshold(.thirtyDays)
        let tab = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        store.archiveTab(tab.id)
        let restored = try roundTrip(store)
        XCTAssertEqual(restored.autoArchiveThreshold(for: store.activeProfileID), .thirtyDays)
        XCTAssertEqual(restored.archivedTabs, store.archivedTabs)
        restored.clearArchive()
        XCTAssertTrue(restored.archivedTabs.isEmpty)
    }

    func testLegacyTabsGetLastActiveStampedAtLoad() throws {
        let store = makeStore()
        let tab = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        var snapshot = store.makeSnapshot()
        snapshot.tabsByID[tab.id]?.lastActiveAt = nil
        let loadTime = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let restored = SidebarStore()
        restored.now = { loadTime }
        restored.applySnapshot(snapshot)
        XCTAssertEqual(restored.tab(withID: tab.id)?.lastActiveAt, loadTime)
    }

    func testArchivePolicyPrunesAndGroups() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func record(_ title: String, age: TimeInterval) -> ArchivedTabRecord {
            ArchivedTabRecord(
                tab: Tab(kind: .today, title: title, url: URL(string: "https://\(title).test")!),
                spaceID: nil,
                archivedAt: now.addingTimeInterval(-age),
                reason: .manual
            )
        }
        let records = [record("fresh", age: 60), record("week", age: 3 * 86_400), record("ancient", age: 61 * 86_400)]
        let pruned = TabArchivePolicy.pruned(records, now: now)
        XCTAssertEqual(pruned.map(\.tab.title), ["fresh", "week"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let groups = TabArchivePolicy.grouped(pruned, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.bucket), [.today, .lastWeek])
        XCTAssertEqual(TabArchivePolicy.grouped(pruned, matching: "WEEK", now: now, calendar: calendar).map(\.bucket), [.lastWeek])
    }

    // MARK: - Spaces and profiles

    func testRenameRecolorAndReiconSpace() {
        let store = makeStore()
        let id = store.activeSpaceID
        XCTAssertFalse(store.renameSpace(id, to: "  "))
        XCTAssertTrue(store.renameSpace(id, to: " Home "))
        XCTAssertEqual(store.space(withID: id)?.name, "Home")
        store.setSpaceTheme(id, theme: SpaceTheme.editorPalette[1][2])
        XCTAssertEqual(store.space(withID: id)?.theme, SpaceTheme.editorPalette[1][2])
        store.setSpaceIcon(id, iconName: "leaf.fill")
        XCTAssertTrue(store.space(withID: id)?.iconIsSymbolName ?? false)
        store.setSpaceIcon(id, iconName: "🚀🚀🚀")
        XCTAssertEqual(store.space(withID: id)?.iconName, "🚀🚀")
        XCTAssertFalse(store.space(withID: id)?.iconIsSymbolName ?? true)
        XCTAssertEqual(journal(store).filter { $0 == .upsertSpace(id: id) }.count, 4)
    }

    func testDeleteSpaceStaysInProfileAndUnblocksProfileDelete() {
        let store = makeStore()
        let second = store.addProfile(name: "Second")
        store.selectProfile(second.id)
        let extra = store.addSpace(name: "Extra")
        store.selectSpace(extra.id)
        XCTAssertTrue(store.removeSpace(extra.id))
        XCTAssertEqual(store.activeProfileID, second.id)
        XCTAssertEqual(store.deleteProfile(second.id), .profileOwnsSpaces(count: 1))
        XCTAssertTrue(store.removeSpace(store.spaces(in: second.id)[0].id))
        XCTAssertNil(store.deleteProfile(second.id))
        XCTAssertFalse(store.profiles.contains { $0.id == second.id })
    }

    func testDeleteProfileWithItsSpaces() {
        let store = makeStore()
        let second = store.addProfile(name: "Second")
        store.selectProfile(second.id)
        let space = store.activeSpaceID
        store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        XCTAssertNil(store.deleteProfile(second.id, deletingSpaces: true))
        XCTAssertNil(store.space(withID: space))
        XCTAssertNil(store.contentBySpace[space])
        XCTAssertNotEqual(store.activeProfileID, second.id)
        XCTAssertTrue(store.spaces.contains { $0.id == store.activeSpaceID })
        XCTAssertEqual(store.deleteProfile(store.activeProfileID, deletingSpaces: true), .cannotDeleteLastProfile)
    }

    func testSelectSpaceByIndex() {
        let store = makeStore()
        XCTAssertTrue(store.selectSpace(atIndex: 1))
        XCTAssertEqual(store.activeSpaceID, store.spacesInActiveProfile[1].id)
        XCTAssertFalse(store.selectSpace(atIndex: 5))
        XCTAssertFalse(store.selectSpace(atIndex: -1))
    }

    // MARK: - Tabs

    func testRenameTabSurvivesNavigation() {
        let store = makeStore()
        let tab = store.addTab(kind: .pinned, title: "Page", url: url("https://p.test"))
        XCTAssertTrue(store.renameTab(tab.id, to: "Mine"))
        store.updateTab(tab.id, title: "Navigated", url: url("https://p.test/2"))
        XCTAssertEqual(store.tab(withID: tab.id)?.displayTitle, "Mine")
        XCTAssertTrue(store.renameTab(tab.id, to: "  "))
        XCTAssertEqual(store.tab(withID: tab.id)?.displayTitle, "Navigated")
    }

    func testDuplicateTab() throws {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        let copy = try XCTUnwrap(store.duplicateTab(a.id))
        XCTAssertEqual(store.content(for: store.activeSpaceID).pinned.map(\.id), [a.id, copy.id, b.id])
        XCTAssertEqual(copy.url, a.url)
        let folder = try XCTUnwrap(store.createFolder(containing: [b.id]))
        let nested = try XCTUnwrap(store.duplicateTab(b.id))
        XCTAssertEqual(store.folder(withID: folder.id)?.children.map(\.id), [b.id, nested.id])
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.test"))
        let favoriteCopy = try XCTUnwrap(store.duplicateTab(favorite.id))
        XCTAssertEqual(store.kind(of: favoriteCopy.id), .today)
    }

    func testSelectionStampsLastActive() {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = makeStore()
        store.now = { clock }
        let tab = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        clock = clock.addingTimeInterval(500)
        store.selectTab(tab.id)
        XCTAssertEqual(store.tab(withID: tab.id)?.lastActiveAt, clock)
    }

    // MARK: - Sync records

    func testFolderPlacementMapsToParentRecordAndIsNotSquashedAcross() {
        let device = UUID()
        let item = UUID()
        let folder = UUID()
        let space = UUID()
        func entry(_ seq: UInt64, _ mutation: SidebarJournalMutation) -> SidebarJournalEntry {
            SidebarJournalEntry(sequence: seq, timestamp: Date(timeIntervalSince1970: 1), deviceID: device, mutation: mutation)
        }
        let records = CloudKitRecordMapper.map(journalEntry: entry(1, .placeItemInFolder(id: item, folderID: folder, sortRank: "m")))
        XCTAssertEqual(records.first?.parentID, "item_\(folder.uuidString.lowercased())")
        XCTAssertEqual(records.first?.sortRank, "m")

        let squashed = MutationCoalescer.squash([
            entry(1, .moveItem(id: item, spaceID: space, container: .pinned, sortRank: "a")),
            entry(2, .placeItemInFolder(id: item, folderID: folder, sortRank: "b")),
            entry(3, .moveItem(id: item, spaceID: space, container: .unpinned, sortRank: "c")),
        ])
        XCTAssertEqual(squashed.map(\.sequence), [1, 2, 3])
        let folderMoves = MutationCoalescer.squash([
            entry(1, .placeItemInFolder(id: item, folderID: folder, sortRank: "b")),
            entry(2, .placeItemInFolder(id: item, folderID: folder, sortRank: "d")),
        ])
        XCTAssertEqual(folderMoves.map(\.mutation), [.placeItemInFolder(id: item, folderID: folder, sortRank: "d")])
    }
}
