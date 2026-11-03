import XCTest
@testable import SidebarModel

/// Wave 19: pinned saved URLs, Cmd+1…9, moving items to a space, per-window
/// focused space, space order, Clear Today (docs/PARITY-AUDIT.md P1 sidebar).
final class Wave19SidebarTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func makeStore() -> SidebarStore {
        let store = SidebarStore(spaces: [
            Space(name: "Personal", sortRank: "a"),
            Space(name: "Work", sortRank: "b"),
        ])
        store.now = { Date(timeIntervalSinceReferenceDate: 800_000_000) }
        return store
    }

    private func roundTrip(_ store: SidebarStore) throws -> SidebarStore {
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        return restored
    }

    // MARK: - Pinned saved URL

    func testPinnedTabsSaveTheirURLAndTodayTabsDoNot() {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "Mail", url: url("https://mail.test/inbox"))
        let today = store.addTab(kind: .today, title: "News", url: url("https://news.test"))
        XCTAssertEqual(store.tab(withID: pinned.id)?.savedURL, url("https://mail.test/inbox"))
        XCTAssertNil(store.tab(withID: today.id)?.savedURL)

        XCTAssertTrue(store.pinTab(today.id))
        XCTAssertEqual(store.tab(withID: today.id)?.savedURL, url("https://news.test"), "pinning saves the current URL")
        XCTAssertEqual(store.tab(withID: today.id)?.savedTitle, "News")
        XCTAssertTrue(store.unpinTab(today.id))
        XCTAssertNil(store.tab(withID: today.id)?.savedURL, "leaving Pinned forgets it")
        XCTAssertTrue(store.addToFavorites(pinned.id))
        XCTAssertNil(store.tab(withID: pinned.id)?.savedURL)
    }

    func testNavigationKeepsTheSavedURLAndResetRestoresIt() {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "Mail", url: url("https://mail.test/inbox"))
        XCTAssertFalse(store.resetTabToSavedURL(pinned.id), "nothing to reset yet")
        store.updateTab(pinned.id, title: "Message", url: url("https://mail.test/message/1"))
        let away = store.tab(withID: pinned.id)!
        XCTAssertTrue(away.isAwayFromSavedURL)
        XCTAssertEqual(away.savedURL, url("https://mail.test/inbox"))

        XCTAssertTrue(store.resetTabToSavedURL(pinned.id))
        let reset = store.tab(withID: pinned.id)!
        XCTAssertEqual(reset.url, url("https://mail.test/inbox"))
        XCTAssertEqual(reset.title, "Mail")
        XCTAssertFalse(reset.isAwayFromSavedURL)
        XCTAssertTrue(store.mutationJournal.allEntries().contains { $0.mutation == .upsertItem(id: pinned.id) })
    }

    func testUnloadingAPinnedTabKeepsItAndMovesSelection() throws {
        let store = makeStore()
        let first = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let second = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        let folder = try XCTUnwrap(store.createFolder(title: "F", containing: [second.id]))
        store.selectTab(second.id)
        store.updateTab(second.id, title: "B2", url: url("https://b.test/2"))

        XCTAssertTrue(store.unloadPinnedTab(second.id))
        XCTAssertEqual(store.tab(withID: second.id)?.url, url("https://b.test"), "reset to the saved URL")
        XCTAssertEqual(store.parentFolderID(of: second.id), folder.id, "still in its folder")
        XCTAssertNotEqual(store.selectedItemID, second.id)
        XCTAssertEqual(store.selectedItemID, first.id)
        XCTAssertFalse(store.archivedTabs.contains { $0.id == second.id }, "unloading is not closing")

        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        XCTAssertFalse(store.unloadPinnedTab(today.id))
    }

    func testResetAllPinnedTabsAndMakeCurrentSaved() {
        let store = makeStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("https://b.test"))
        store.addTab(kind: .pinned, title: "C", url: url("https://c.test"))
        store.updateTab(a.id, url: url("https://a.test/x"))
        store.updateTab(b.id, url: url("https://b.test/y"))
        XCTAssertTrue(store.updateSavedURLToCurrent(b.id))
        XCTAssertEqual(store.tab(withID: b.id)?.savedURL, url("https://b.test/y"))
        XCTAssertEqual(store.resetPinnedTabs(), [a.id])
        XCTAssertEqual(store.tab(withID: a.id)?.url, url("https://a.test"))
    }

    func testSavedURLPersistsAndOlderPinnedTabsAreStamped() throws {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "Mail", url: url("https://mail.test/inbox"))
        store.updateTab(pinned.id, url: url("https://mail.test/sent"))
        let restored = try roundTrip(store)
        XCTAssertEqual(restored.tab(withID: pinned.id)?.savedURL, url("https://mail.test/inbox"))
        XCTAssertEqual(restored.tab(withID: pinned.id)?.url, url("https://mail.test/sent"))

        // A pinned tab encoded before wave 19 has no savedURL: it keeps the URL it had.
        let legacy = #"{"id":"\#(UUID().uuidString)","kind":"pinned","title":"Old","url":"https://old.test/page"}"#
        let decoded = try JSONDecoder().decode(Tab.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.savedURL, url("https://old.test/page"))
        XCTAssertEqual(decoded.savedTitle, "Old")
        let todayJSON = #"{"id":"\#(UUID().uuidString)","kind":"today","title":"T","url":"https://t.test"}"#
        XCTAssertNil(try JSONDecoder().decode(Tab.self, from: Data(todayJSON.utf8)).savedURL)
    }

    func testDuplicatedAndReopenedPinnedTabsKeepTheSavedURL() throws {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "Mail", url: url("https://mail.test/inbox"))
        store.updateTab(pinned.id, url: url("https://mail.test/sent"))
        let copy = try XCTUnwrap(store.duplicateTab(pinned.id))
        XCTAssertEqual(copy.savedURL, url("https://mail.test/inbox"))
        store.closeTab(pinned.id)
        let reopened = try XCTUnwrap(store.reopenMostRecentClosedTab())
        XCTAssertEqual(reopened.savedURL, url("https://mail.test/inbox"))
        XCTAssertEqual(reopened.url, url("https://mail.test/sent"))
    }

    // MARK: - Cmd+1…9

    func testSelectByPositionUsesDisplayOrderAndNineIsLast() throws {
        let store = makeStore()
        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.test"))
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        let older = store.addTab(kind: .today, title: "T1", url: url("https://t1.test"))
        let newer = store.addTab(kind: .today, title: "T2", url: url("https://t2.test"))
        // Display order: favorite, pinned, newer (Today inserts at the top), older.
        XCTAssertEqual(store.selectItem(atPosition: 1), favorite.id)
        XCTAssertEqual(store.selectedTabID, favorite.id)
        XCTAssertEqual(store.selectItem(atPosition: 2), pinned.id)
        XCTAssertEqual(store.selectItem(atPosition: 3), newer.id)
        XCTAssertEqual(store.selectItem(atPosition: 9), older.id, "9 is always the last row")
        XCTAssertNil(store.selectItem(atPosition: 6), "no sixth row")
        XCTAssertEqual(store.selectedTabID, older.id, "a missing row leaves the selection alone")
        XCTAssertNil(store.selectItem(atPosition: 0))
        XCTAssertEqual(store.selectItem(atPosition: 1, includingFavorites: false), pinned.id)
    }

    func testSelectByPositionSelectsSplitsAsOneRow() throws {
        let store = makeStore()
        let a = store.addTab(kind: .today, title: "A", url: url("https://a.test"))
        let b = store.addTab(kind: .today, title: "B", url: url("https://b.test"))
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        XCTAssertEqual(store.selectItem(atPosition: 1), split.id)
        XCTAssertEqual(store.selectedItemID, split.id)
    }

    // MARK: - Move to space

    func testMovingToASpaceKeepsTheSection() throws {
        let store = makeStore()
        let work = store.spaces[1].id
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        store.addTab(kind: .pinned, title: "W", url: url("https://w.test"), in: work)
        store.addTab(kind: .today, title: "W2", url: url("https://w2.test"), in: work)

        XCTAssertTrue(store.moveEntry(pinned.id, toSpace: work))
        XCTAssertEqual(store.content(for: work).pinned.last?.id, pinned.id, "end of Pinned")
        XCTAssertEqual(store.kind(of: pinned.id), .pinned)
        XCTAssertEqual(store.tab(withID: pinned.id)?.savedURL, url("https://p.test"), "still pinned, URL kept")
        XCTAssertTrue(store.moveEntry(today.id, toSpace: work))
        XCTAssertEqual(store.content(for: work).today.first?.id, today.id, "top of Today")
        XCTAssertFalse(store.moveEntry(today.id, toSpace: work), "already there")
    }

    func testMovingAFolderOrNestedTabToASpace() throws {
        let store = makeStore()
        let work = store.spaces[1].id
        let tab = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        let nested = store.addTab(kind: .pinned, title: "N", url: url("https://n.test"))
        let folder = try XCTUnwrap(store.createFolder(title: "F", containing: [tab.id]))
        let inner = try XCTUnwrap(store.createFolder(title: "Inner", parentFolderID: folder.id, containing: [nested.id]))
        XCTAssertTrue(store.moveEntry(nested.id, toSpace: work))
        XCTAssertEqual(store.parent(of: nested.id), .section(spaceID: work, section: .pinned), "out of the folder, still pinned")
        XCTAssertTrue(store.moveEntry(folder.id, toSpace: work))
        XCTAssertEqual(store.spaceContaining(entryID: folder.id), work)
        XCTAssertEqual(store.parentFolderID(of: tab.id), folder.id, "children move with their folder")
        XCTAssertEqual(store.parentFolderID(of: inner.id), folder.id)
    }

    func testAMovedSelectedItemIsFollowedAndFavoritesDoNotMove() {
        let store = makeStore()
        let personal = store.spaces[0].id
        let work = store.spaces[1].id
        let today = store.addTab(kind: .today, title: "T", url: url("https://t.test"))
        store.selectTab(today.id)
        XCTAssertTrue(store.moveEntry(today.id, toSpace: work))
        XCTAssertEqual(store.activeSpaceID, work)
        XCTAssertEqual(store.selectedTabID, today.id)

        store.selectSpace(personal)
        let other = store.addTab(kind: .today, title: "O", url: url("https://o.test"))
        let stay = store.addTab(kind: .today, title: "S", url: url("https://s.test"))
        store.selectTab(stay.id)
        XCTAssertTrue(store.moveEntry(other.id, toSpace: work))
        XCTAssertEqual(store.activeSpaceID, personal, "an unselected item does not switch spaces")
        XCTAssertEqual(store.selectedTabID, stay.id)

        let favorite = store.addTab(kind: .favorite, title: "F", url: url("https://f.test"))
        XCTAssertFalse(store.moveEntry(favorite.id, toSpace: work))
    }

    // MARK: - Per-window focused space

    func testEachWindowKeepsItsOwnSpace() {
        let store = makeStore()
        let personal = store.spaces[0].id
        let work = store.spaces[1].id
        let personalTab = store.addTab(kind: .today, title: "P", url: url("https://p.test"))
        let workTab = store.addTab(kind: .today, title: "W", url: url("https://w.test"), in: work)
        store.selectTab(personalTab.id)

        let one = SidebarWindowID(), two = SidebarWindowID()
        store.registerWindow(one)
        store.windowBecameKey(one)
        store.registerWindow(two)
        XCTAssertEqual(store.focusedSpaceID(in: two), personal, "a new window starts on the key window's space")
        store.windowBecameKey(two)
        store.selectSpace(work)
        store.selectTab(workTab.id)
        XCTAssertEqual(store.focusedSpaceID(in: two), work)
        XCTAssertEqual(store.focusedSpaceID(in: one), personal, "window one keeps its space")
        XCTAssertEqual(store.selectedTab(inSpace: store.focusedSpaceID(in: one))?.id, personalTab.id)

        store.windowBecameKey(one)
        XCTAssertEqual(store.activeSpaceID, personal)
        XCTAssertEqual(store.selectedTabID, personalTab.id, "the space's selection comes back")
        XCTAssertEqual(store.focusedSpaceID(in: two), work)
        XCTAssertEqual(store.selectedTab(inSpace: work)?.id, workTab.id)
    }

    func testWindowsFollowProfilesAndDeletedSpaces() {
        let store = makeStore()
        let personal = store.spaces[0].id
        let profile = store.addProfile(name: "Work")
        let other = store.addSpace(name: "Other", profileID: profile.id)
        XCTAssertEqual(other.profileID, profile.id)

        let one = SidebarWindowID(), two = SidebarWindowID()
        store.windowBecameKey(one)
        store.windowBecameKey(two)
        store.selectSpace(other.id)
        XCTAssertEqual(store.activeProfileID, profile.id)
        store.windowBecameKey(one)
        XCTAssertEqual(store.activeSpaceID, personal)
        XCTAssertEqual(store.activeProfileID, store.profiles[0].id, "the window's space brings its profile")

        XCTAssertTrue(store.removeSpace(other.id))
        XCTAssertEqual(store.focusedSpaceID(in: two), store.activeSpaceID, "a deleted space falls back to the active one")
        store.unregisterWindow(two)
        XCTAssertNil(store.focusedSpaceByWindow[two])
        XCTAssertEqual(store.focusedSpaceID(in: nil), store.activeSpaceID)
    }

    // MARK: - Space order

    func testMoveSpaceReordersWithinTheProfileAndJournals() throws {
        let store = makeStore()
        let third = store.addSpace(name: "Third")
        let names = { store.spacesInActiveProfile.map(\.name) }
        XCTAssertEqual(names(), ["Personal", "Work", "Third"])
        XCTAssertTrue(store.moveSpace(third.id, toIndex: 0))
        XCTAssertEqual(names(), ["Third", "Personal", "Work"])
        XCTAssertTrue(store.selectSpace(atIndex: 0))
        XCTAssertEqual(store.activeSpaceID, third.id, "Ctrl+1 follows the new order")
        XCTAssertFalse(store.moveSpace(third.id, toIndex: 0), "no change")
        XCTAssertTrue(store.moveSpace(store.spaces.first { $0.name == "Personal" }!.id, toIndex: 2))
        XCTAssertEqual(names(), ["Third", "Work", "Personal"])
        let ranks = store.spacesInActiveProfile.map(\.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(), "ranks follow the order")
        XCTAssertTrue(store.mutationJournal.allEntries().contains {
            if case .moveSpace(let id, _) = $0.mutation { return id == third.id }
            return false
        })
        XCTAssertEqual(try roundTrip(store).spacesInActiveProfile.map(\.name), ["Third", "Work", "Personal"])
    }

    // MARK: - Clear Today

    func testClearTodayArchivesAndUndoRestoresInOrder() {
        let store = makeStore()
        let pinned = store.addTab(kind: .pinned, title: "P", url: url("https://p.test"))
        let older = store.addTab(kind: .today, title: "T1", url: url("https://t1.test"))
        let newer = store.addTab(kind: .today, title: "T2", url: url("https://t2.test"))
        store.selectTab(newer.id)
        let cleared = store.clearTodayTabs()
        XCTAssertEqual(cleared, [newer.id, older.id])
        XCTAssertTrue(store.content(for: store.activeSpaceID).today.isEmpty)
        XCTAssertEqual(store.selectedTabID, pinned.id)
        XCTAssertEqual(Set(store.archivedTabs.map(\.id)), [newer.id, older.id])

        store.restoreClearedTabs(cleared)
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.map(\.id), [newer.id, older.id])
        XCTAssertTrue(store.archivedTabs.isEmpty)
    }
}

/// Wave 19: the New Space dialog model.
final class SpaceDraftTests: XCTestCase {
    func testSuggestionNumbersTheProfilesSpaces() {
        let store = SidebarStore()
        let draft = SpaceDraft.suggested(in: store)
        XCTAssertEqual(draft.name, "Space 2")
        XCTAssertEqual(draft.profileID, store.activeProfileID)
        XCTAssertEqual(draft.theme, SpaceTheme.presets[1])
        let other = store.addProfile(name: "Work")
        let otherDraft = SpaceDraft.suggested(in: store, profileID: other.id)
        XCTAssertEqual(otherDraft.name, "Space \(store.spaces(in: other.id).count + 1)")
        XCTAssertEqual(otherDraft.profileID, other.id)
    }

    func testCreateUsesEveryFieldAndSelectsTheSpace() throws {
        let store = SidebarStore()
        let other = store.addProfile(name: "Work")
        var draft = SpaceDraft.suggested(in: store)
        draft.name = "  Research  "
        draft.theme = SpaceTheme.editorPalette[1][2]
        draft.iconName = "🧪"
        draft.profileID = other.id
        let space = try XCTUnwrap(store.createSpace(from: draft))
        XCTAssertEqual(space.name, "Research")
        XCTAssertEqual(space.theme, SpaceTheme.editorPalette[1][2])
        XCTAssertEqual(space.iconName, "🧪")
        XCTAssertEqual(space.profileID, other.id)
        XCTAssertEqual(store.activeSpaceID, space.id)
        XCTAssertEqual(store.activeProfileID, other.id)
    }

    func testABlankNameOrMissingProfileCreatesNothing() {
        let store = SidebarStore()
        var draft = SpaceDraft.suggested(in: store)
        draft.name = "   "
        XCTAssertFalse(draft.canCreate(in: store))
        XCTAssertNil(store.createSpace(from: draft))
        draft.name = "Ok"
        draft.profileID = UUID()
        XCTAssertNil(store.createSpace(from: draft))
        XCTAssertEqual(store.spaces.count, 1)
    }
}

/// Wave 19: a muted tab keeps a speaker that unmutes it.
final class TabMuteToggleTests: XCTestCase {
    func testMutedTabsKeepTheirIndicator() {
        let id = UUID()
        var model = TabMediaMuteModel()
        XCTAssertFalse(model.showsAudibleIndicator(for: id, media: .silent))
        XCTAssertTrue(model.showsAudibleIndicator(for: id, media: WebMediaState(isPlaying: true, isAudible: true)))
        model.markUserMuted(id)
        XCTAssertTrue(model.isUserMuted(id))
        XCTAssertTrue(model.showsAudibleIndicator(for: id, media: .silent), "muted: the speaker stays to unmute")
        model.markUserUnmuted(id)
        XCTAssertFalse(model.showsAudibleIndicator(for: id, media: .silent))
    }
}

/// Wave 19: the resizable sidebar width.
final class SidebarWidthTests: XCTestCase {
    func testWidthIsClampedAndRemembered() throws {
        XCTAssertEqual(SidebarWidth.clamped(100), SidebarWidth.minimum)
        XCTAssertEqual(SidebarWidth.clamped(9000), SidebarWidth.maximum)
        XCTAssertEqual(SidebarWidth.clamped(.nan), SidebarWidth.standard)
        XCTAssertEqual(SidebarWidth.clamped(300), 300)
        let suite = "rearc-width-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SidebarWidth.load(from: defaults), SidebarWidth.standard)
        SidebarWidth.save(310, to: defaults)
        XCTAssertEqual(SidebarWidth.load(from: defaults), 310)
        SidebarWidth.save(5000, to: defaults)
        XCTAssertEqual(SidebarWidth.load(from: defaults), SidebarWidth.maximum)
    }
}
