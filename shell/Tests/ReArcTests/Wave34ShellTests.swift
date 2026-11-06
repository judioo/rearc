import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

private typealias Tab = SidebarModel.Tab

/// Wave 34: tab lifecycle against the recording of Arc
/// (docs/ARC-RECORDING-2026-11-06.md §4 items 1, 2 and 4).
@MainActor
final class Wave34ShellTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Work", sortRank: "b")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w34-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w34-\(UUID().uuidString)")!
        model.automaticPictureInPicture = false
        return model
    }

    // MARK: Close wording (§4 item 1)

    func testCloseWordingFollowsTheSection() {
        var today: Tab!, pinned: Tab!, favorite: Tab!
        let model = makeModel { store in
            today = store.addTab(kind: .today, title: "T", url: self.url("t"))
            pinned = store.addTab(kind: .pinned, title: "P", url: self.url("p"))
            favorite = store.addTab(kind: .favorite, title: "F", url: self.url("f"))
        }
        XCTAssertEqual(model.closeKind(of: today.id), .archive)
        XCTAssertEqual(model.closeKind(of: pinned.id), .unloadPinned)
        XCTAssertEqual(model.closeKind(of: favorite.id), .unloadFavorite)
        XCTAssertEqual(TabCloseKind.archive.buttonLabel, "Archive this tab", "Arc's tooltip on a Today row")
        XCTAssertEqual(TabCloseKind.unloadPinned.buttonLabel, "Close tab")
        XCTAssertEqual(TabCloseKind.unloadFavorite.buttonLabel, "Close tab")

        model.selectTab(today.id)
        XCTAssertEqual(model.closeTabMenuTitle, "Archive Tab", "Arc's Shortcuts list name for ⌘W")
        model.selectTab(pinned.id)
        XCTAssertEqual(model.closeTabMenuTitle, "Close Tab")
        model.selectTab(favorite.id)
        XCTAssertEqual(model.closeTabMenuTitle, "Close Tab")
    }

    func testTheWordingMatchesWhatCloseDoes() {
        var today: Tab!, pinned: Tab!
        let model = makeModel { store in
            today = store.addTab(kind: .today, title: "T", url: self.url("t"))
            pinned = store.addTab(kind: .pinned, title: "P", url: self.url("p"))
            store.selectTab(pinned.id)
        }
        model.loadSelectedIfNeeded()
        model.closeTab(pinned.id)
        XCTAssertEqual(model.store.kind(of: pinned.id), .pinned, "unloadPinned: the row stays")
        XCTAssertTrue(model.isTabUnloaded(pinned.id))
        model.closeTab(today.id)
        XCTAssertNil(model.store.tab(withID: today.id), "archive: the row is gone")
        XCTAssertTrue(model.store.archivedTabs.contains { $0.id == today.id })
    }

    // MARK: "Double-click to rename" (§4 item 2)

    func testPinningShowsTheRenameHintForAboutThreeSeconds() {
        var tab: Tab!
        let model = makeModel { store in
            tab = store.addTab(kind: .today, title: "T", url: self.url("t"))
            store.selectTab(tab.id)
        }
        XCTAssertNil(model.renameHintSubtitle(for: tab.id))
        model.togglePin(tab.id)
        let shownAt = try! XCTUnwrap(model.renameHint?.shownAt)
        XCTAssertEqual(model.renameHint?.tabID, tab.id)
        XCTAssertEqual(model.renameHintSubtitle(for: tab.id, now: shownAt), "Double-click to rename")
        XCTAssertEqual(model.renameHintSubtitle(for: tab.id, now: shownAt.addingTimeInterval(2.9)), "Double-click to rename")
        XCTAssertNil(model.renameHintSubtitle(for: tab.id, now: shownAt.addingTimeInterval(3)))
        XCTAssertEqual(BrowserViewModel.renameHintDuration, 3, accuracy: 0.5)

        model.expireRenameHint(now: shownAt.addingTimeInterval(1))
        XCTAssertNotNil(model.renameHint, "not yet")
        model.expireRenameHint(now: shownAt.addingTimeInterval(3))
        XCTAssertNil(model.renameHint)

        // Unpinning (⌘D again) shows no hint.
        model.togglePin(tab.id)
        XCTAssertNil(model.renameHint)
    }

    func testTheHintFollowsEveryWayIntoPinned() {
        var a: Tab!, b: Tab!, favorite: Tab!, anchor: Tab!
        let model = makeModel { store in
            anchor = store.addTab(kind: .pinned, title: "Anchor", url: self.url("anchor"))
            a = store.addTab(kind: .today, title: "A", url: self.url("a"))
            b = store.addTab(kind: .today, title: "B", url: self.url("b"))
            favorite = store.addTab(kind: .favorite, title: "F", url: self.url("f"))
        }
        let main = model.store.activeSpaceID

        // A drop after a pinned row.
        model.moveItem(a.id, relativeTo: anchor.id, after: true)
        XCTAssertEqual(model.store.kind(of: a.id), .pinned)
        XCTAssertEqual(model.renameHint?.tabID, a.id)

        // A drop on the end of the Pinned section.
        model.renameHint = nil
        model.moveItem(b.id, to: .section(spaceID: main, section: .pinned), index: 0)
        XCTAssertEqual(model.renameHint?.tabID, b.id)

        // Moving within Pinned is not a new pin.
        model.renameHint = nil
        model.moveItem(b.id, relativeTo: anchor.id, after: true)
        XCTAssertNil(model.renameHint)

        // Favorites' Move to Pinned.
        model.moveFavoriteToPinned(favorite.id)
        XCTAssertEqual(model.renameHint?.tabID, favorite.id)

        // Back to Today shows none.
        model.renameHint = nil
        model.moveItem(a.id, to: .section(spaceID: main, section: .unpinned), index: 0)
        XCTAssertNil(model.renameHint)
    }

    /// The plain AppKit row has no subtitle: while the hint shows, the cell
    /// hosts the SwiftUI row, which draws it and takes the double-click.
    func testTheHintHostsThePlainRow() throws {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        let tab = store.addTab(kind: .today, title: "Tea", url: url("tea"))
        let context = SidebarListCellContext(
            chrome: ThemeChromeColors(theme: .default, dark: false), window: nil, pager: nil, colorScheme: .light, tint: .blue)
        let controller = SidebarListController(model: model, spaceID: store.activeSpaceID, context: context)
        let scroll = controller.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 228, height: 600)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        func drain() {
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func cell() throws -> SidebarPlainRowCell {
            let index = try XCTUnwrap(controller.rows.firstIndex { $0.id == .item(tab.id) })
            return try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns.first, row: index) as? SidebarPlainRowCell)
        }
        func hosted(_ cell: SidebarPlainRowCell) -> Bool { cell.subviews.contains { $0 is NSHostingView<SidebarHostedRow> } }

        drain()
        XCTAssertFalse(hosted(try cell()))
        model.togglePin(tab.id)
        drain()
        let pinned = try cell()
        XCTAssertTrue(hosted(pinned), "the hint shows in the hosted SwiftUI row")
        model.renameHint = nil
        drain()
        XCTAssertFalse(hosted(pinned), "the row goes back to plain once the hint is gone")
    }

    // MARK: Space-switch retention (§4 item 4)

    /// Leaving a space keeps its selected pinned tab loaded on the same
    /// engine. Idle unload counts each space's selected tab as on screen
    /// (`visibleTabIDs`), so it never unloads it for the switch; a tab
    /// that is not selected in that space unloads on its usual timer.
    func testASelectedPinnedTabStaysLoadedAcrossASpaceSwitch() throws {
        var pinned: Tab!, background: Tab!
        let model = makeModel { store in
            pinned = store.addTab(kind: .pinned, title: "P", url: self.url("p"))
            background = store.addTab(kind: .today, title: "B", url: self.url("b"))
            store.selectTab(background.id)
        }
        let store = model.store
        let main = store.activeSpaceID
        let work = try XCTUnwrap(store.spaces.first { $0.id != main }).id
        model.loadSelectedIfNeeded()
        model.selectTab(pinned.id)
        let engine = try XCTUnwrap(model.engineHost.engine(forTabID: pinned.id, profileID: model.profileID(for: pinned)))

        model.selectSpace(work)
        XCTAssertEqual(store.activeSpaceID, work)
        XCTAssertFalse(model.isTabUnloaded(pinned.id), "the switch itself unloads nothing")
        XCTAssertTrue(model.engineHost.engine(forTabID: pinned.id, profileID: model.profileID(for: pinned)) === engine)

        // Both last shown well past the threshold: only the unselected tab goes.
        let now = Date()
        model.tabLastShown[pinned.id] = now.addingTimeInterval(-5 * 3600)
        model.tabLastShown[background.id] = now.addingTimeInterval(-5 * 3600)
        model.tabUnloadThreshold = .fourHours
        XCTAssertEqual(model.runAutoUnload(now: now), [background.id])
        XCTAssertTrue(model.isTabUnloaded(background.id))
        XCTAssertFalse(model.isTabUnloaded(pinned.id))
        XCTAssertEqual(model.runAutoUnload(now: now.addingTimeInterval(24 * 3600)), [], "still kept a day later")

        model.selectSpace(main)
        XCTAssertEqual(store.selectedTabID, pinned.id, "coming back shows it selected")
        XCTAssertTrue(model.engineHost.engine(forTabID: pinned.id, profileID: model.profileID(for: pinned)) === engine,
                      "the same live page, no reload")
        XCTAssertFalse(model.isTabUnloaded(pinned.id))
    }
}
