import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 19 shell glue: pinned Cmd+W, Cmd+1…9, move to space, the New Space
/// dialog, per-window focused space, Clear Today and the mute toggle.
final class Wave19ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Second", sortRank: "b")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w19-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    private func engine(_ model: BrowserViewModel, _ id: Tab.ID) -> (any WebEngine)? {
        model.engineHost.engine(forTabID: id, profileID: model.store.activeProfileID)
    }

    func testCmdWOnAPinnedTabUnloadsItToItsSavedURL() throws {
        var pinned: Tab!
        var today: Tab!
        let model = makeModel { store in
            pinned = store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test/inbox")!)
            today = store.addTab(kind: .today, title: "T", url: URL(string: "https://t.test")!)
            store.selectTab(pinned.id)
        }
        model.loadSelectedIfNeeded()
        model.store.updateTab(pinned.id, url: URL(string: "https://mail.test/message")!)
        XCTAssertNotNil(engine(model, pinned.id))

        model.closeSelectedTab()
        XCTAssertNil(engine(model, pinned.id), "engine dropped")
        XCTAssertEqual(model.store.kind(of: pinned.id), .pinned, "still pinned")
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.url, URL(string: "https://mail.test/inbox"))
        XCTAssertEqual(model.store.selectedTabID, today.id)
        XCTAssertTrue(model.store.closedTabStack.records.isEmpty, "not a close")

        model.deleteTab(pinned.id)
        XCTAssertNil(model.store.tab(withID: pinned.id), "Delete Tab removes it")
    }

    func testResetLoadsTheSavedURLAndCommandsAreGated() throws {
        var pinned: Tab!
        let model = makeModel { store in
            pinned = store.addTab(kind: .pinned, title: "Mail", url: URL(string: "https://mail.test/inbox")!)
            store.selectTab(pinned.id)
        }
        let context = { CommandBarContext(store: model.store, isSidebarVisible: true, closedTabStack: model.store.closedTabStack) }
        XCTAssertFalse(AppCommandRegistry.all(in: context()).map(\.action).contains(.resetTabToOriginalURL))
        model.store.updateTab(pinned.id, url: URL(string: "https://mail.test/sent")!)
        XCTAssertTrue(AppCommandRegistry.all(in: context()).map(\.action).contains(.resetTabToOriginalURL))
        XCTAssertNil(model.executeCommand(.resetTabToOriginalURL, commandID: nil))
        XCTAssertEqual(model.store.tab(withID: pinned.id)?.url, URL(string: "https://mail.test/inbox"))
        XCTAssertFalse(AppCommandRegistry.all(in: context()).map(\.action).contains(.resetTabToOriginalURL))
    }

    func testTabPositionMenuSelectsRows() {
        var tabs: [Tab] = []
        let model = makeModel { store in
            tabs.append(store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!))
            tabs.append(store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!))
            tabs.append(store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!))
        }
        let items = ShellMenus.tabPositions(model).flatMap { $0 }
        XCTAssertEqual(items.map(\.menuKeyEquivalent), (1 ... 9).map(String.init))
        XCTAssertTrue(items.allSatisfy { $0.modifiers == .command })
        XCTAssertEqual(items.last?.title, "Last Tab")
        items[1].action()
        XCTAssertEqual(model.store.selectedTabID, tabs[2].id, "row 2 is the newest Today tab")
        items[8].action()
        XCTAssertEqual(model.store.selectedTabID, tabs[1].id)
        XCTAssertNotNil(engine(model, tabs[1].id), "the selected row loads")
    }

    func testNewSpaceOpensTheDialogAndCreateUsesItsFields() throws {
        let model = makeModel()
        let before = model.store.spaces.count
        XCTAssertNil(model.executeCommand(.createSpace, commandID: nil))
        var draft = try XCTUnwrap(model.spaceCreationDraft)
        XCTAssertEqual(model.store.spaces.count, before, "nothing until Create")
        draft.name = "Reading"
        draft.iconName = "book.fill"
        let space = try XCTUnwrap(model.createSpace(from: draft))
        XCTAssertNil(model.spaceCreationDraft)
        XCTAssertEqual(model.store.activeSpaceID, space.id)
        XCTAssertEqual(space.iconName, "book.fill")
        XCTAssertEqual(ShellMenus.spaces(model).flatMap { $0 }.first { $0.title == "New Space…" }.map { _ in true }, true)
    }

    func testEachWindowShowsItsOwnSpace() {
        var main: Tab!
        var second: Tab!
        let model = makeModel { store in
            main = store.addTab(kind: .today, title: "M", url: URL(string: "https://m.test")!)
            second = store.addTab(kind: .today, title: "S", url: URL(string: "https://s.test")!, in: store.spaces[1].id)
            store.selectTab(main.id)
        }
        let one = SidebarWindowID(), two = SidebarWindowID()
        model.store.registerWindow(one)
        model.windowBecameKey(one)
        model.store.registerWindow(two)
        model.windowBecameKey(two)
        model.selectSpace(model.store.spaces[1].id)
        model.selectTab(second.id)

        XCTAssertEqual(model.space(in: one).name, "Main")
        XCTAssertEqual(model.space(in: two).name, "Second")
        XCTAssertEqual(model.selectedTab(in: one)?.id, main.id)
        XCTAssertEqual(model.selectedTab(in: two)?.id, second.id)
        XCTAssertNotNil(model.focusedEngine(in: two))

        model.windowBecameKey(one)
        XCTAssertEqual(model.store.selectedTabID, main.id, "commands act on the key window")
        XCTAssertNotNil(model.focusedEngine(in: one), "the key window's tab loads")
    }

    func testClearTodayReleasesEnginesAndUndoRestores() {
        var tabs: [Tab] = []
        let model = makeModel { store in
            tabs.append(store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!))
            tabs.append(store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!))
            store.selectTab(tabs[1].id)
        }
        model.loadSelectedIfNeeded()
        XCTAssertNotNil(engine(model, tabs[1].id))
        model.clearTodayTabs()
        XCTAssertTrue(model.store.content(for: model.store.activeSpaceID).today.isEmpty)
        XCTAssertNil(engine(model, tabs[1].id))
        XCTAssertEqual(model.lastClearedTabIDs.count, 2)
        model.undoClearTodayTabs()
        XCTAssertEqual(model.store.content(for: model.store.activeSpaceID).today.count, 2)
        XCTAssertTrue(model.lastClearedTabIDs.isEmpty)
    }

    func testTheSpeakerMutesAndUnmutes() {
        var tab: Tab!
        let model = makeModel { store in
            tab = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
            store.selectTab(tab.id)
        }
        model.loadSelectedIfNeeded()
        model.toggleMute(tab.id)
        XCTAssertTrue(model.isUserMuted(tab.id))
        XCTAssertTrue(model.showsAudibleIndicator(for: tab.id), "a muted tab keeps its (muted) speaker")
        model.toggleMute(tab.id)
        XCTAssertFalse(model.isUserMuted(tab.id))
        XCTAssertFalse(model.showsAudibleIndicator(for: tab.id), "silent and unmuted: no speaker")
    }

    func testMoveToSpaceKeepsPinnedTabsPinned() {
        var pinned: Tab!
        let model = makeModel { store in
            pinned = store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!)
        }
        let second = model.store.spaces[1].id
        model.moveTab(pinned.id, toSpace: second)
        XCTAssertEqual(model.store.parent(of: pinned.id), .section(spaceID: second, section: .pinned))
    }

    func testDailyPageMenusExistOnlyWithTheFlag() {
        let model = makeModel()
        let titles = ShellMenus.browserPages(model).flatMap { $0 }.map(\.title)
        XCTAssertEqual(titles, ["History", "Downloads", "Passwords", "Extensions"])
        // WebKit admits no WebUI: the actions do nothing there.
        ShellMenus.browserPages(model).flatMap { $0 }.forEach { $0.action() }
        XCTAssertFalse(model.store.displayTabs().contains { $0.url.scheme == "chrome" })
    }
}
