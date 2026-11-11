import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// ⇧/⌘-click selection in the sidebar (Arc, 2026-11-11 recording): the
/// clicks, and the menu bar, keys and row menu acting on the selection.
@MainActor
final class MultiSelectionShellTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Demo", sortRank: "a"), Space(name: "Work", sortRank: "b")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-multi-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-multi-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-multi-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-multi-\(UUID().uuidString)"))
        return model
    }

    /// Memo pinned; Google 1…3 in Today, top to bottom; Google 1 shown.
    private func makeFixture() -> (BrowserViewModel, memo: Tab, google: [Tab]) {
        let model = makeModel()
        let memo = model.store.addTab(kind: .pinned, title: "Memo Notepad", url: URL(string: "https://memonotepad.test/")!)
        var google = (1 ... 3).map { model.store.addTab(kind: .today, title: "Google \($0)", url: URL(string: "https://www.google.com/?n=\($0)")!) }
        let order = model.store.outlineOrder(in: model.store.activeSpaceID)
        google.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        model.selectTab(google[0].id)
        return (model, memo, google)
    }

    func testShiftClickSelectsTheRangeWithoutChangingThePage() {
        let (model, memo, google) = makeFixture()
        XCTAssertTrue(model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .shift))
        XCTAssertEqual(model.keySelectionIDs, google.map(\.id))
        XCTAssertEqual(model.store.selectedTabID, google[0].id, "the page stays")

        XCTAssertTrue(model.handleSelectionClick(on: google[1].id, in: nil, modifiers: .command))
        XCTAssertEqual(model.keySelectionIDs, [google[0].id, google[2].id])
        XCTAssertTrue(model.handleSelectionClick(on: memo.id, in: nil, modifiers: .command))
        XCTAssertEqual(model.keySelectionIDs, [memo.id, google[0].id, google[2].id])

        XCTAssertFalse(model.handleSelectionClick(on: google[1].id, in: nil, modifiers: []), "a plain click is a click")
        XCTAssertNil(model.keySelectionIDs, "and drops the selection")
        XCTAssertFalse(model.handleSelectionClick(on: google[1].id, in: nil, modifiers: [.shift, .option]))
    }

    func testCopyLinksWritesOneURLPerLine() {
        let (model, _, google) = makeFixture()
        _ = model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .shift)
        model.copyURL()
        XCTAssertEqual(model.linkPasteboard.string(forType: .string),
                       "https://www.google.com/?n=\(google[0].title.last!)\nhttps://www.google.com/?n=\(google[1].title.last!)\nhttps://www.google.com/?n=\(google[2].title.last!)")
        XCTAssertEqual(model.toast?.message, "Copied URLs")
        model.copyURL(format: .markdown)
        XCTAssertEqual(model.linkPasteboard.string(forType: .string)?.components(separatedBy: "\n").first,
                       "[\(google[0].title)](https://www.google.com/?n=\(google[0].title.last!))")
        // Without a selection ⇧⌘C copies the page's own link, as before.
        model.clearSelection(in: nil)
        model.copyURL()
        XCTAssertEqual(model.toast?.message, "Copied Current URL")
    }

    func testCommandWClosesTheSelectionAndOneReopenBringsItBack() {
        let (model, memo, google) = makeFixture()
        _ = model.handleSelectionClick(on: google[1].id, in: nil, modifiers: .shift)
        _ = model.handleSelectionClick(on: memo.id, in: nil, modifiers: .command)
        XCTAssertEqual(model.closeTabMenuTitle, "Close Tabs", "a pinned tab among them stays pinned")
        model.closeSelectedTab()
        let titles = { model.store.outlineOrder(in: model.store.activeSpaceID).compactMap { model.store.tab(withID: $0)?.title } }
        XCTAssertEqual(titles(), [memo.title, google[2].title], "Today tabs archived, the pinned one kept")
        XCTAssertNil(model.keySelectionIDs)

        model.reopenClosedTab()
        XCTAssertEqual(titles(), [memo.title] + google.map(\.title), "one ⇧⌘T brings back both, in place")
    }

    func testArchiveTitleAndPinToggle() {
        let (model, memo, google) = makeFixture()
        _ = model.handleSelectionClick(on: google[1].id, in: nil, modifiers: .shift)
        XCTAssertEqual(model.closeTabMenuTitle, "Archive Tabs")
        model.togglePin()
        XCTAssertEqual(model.store.outline(for: model.store.activeSpaceID).pinned.map(\.id), [memo.id, google[0].id, google[1].id])
        XCTAssertEqual(model.toast?.message, "Pinned 2 Tabs to “Demo”")
        XCTAssertEqual(model.keySelectionIDs, [google[0].id, google[1].id], "the selection stays on the moved rows")
        model.togglePin()
        XCTAssertEqual(model.store.outline(for: model.store.activeSpaceID).today.map(\.id), google.map(\.id))
    }

    func testMenuTargetsFollowTheClickedRow() {
        let (model, memo, google) = makeFixture()
        _ = model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .shift)
        XCTAssertEqual(model.store.menuTargets(for: google[1].id, in: nil), google.map(\.id))
        XCTAssertEqual(model.store.menuTargets(for: memo.id, in: nil), [memo.id])
        XCTAssertEqual(model.store.menuTargets(for: google[1].id, in: SidebarWindowID()), [google[1].id], "another window's rows")
    }

    func testMoveToSpaceKeepsEachPage() {
        let (model, _, google) = makeFixture()
        let engines = google.map { model.engineHost.engine(for: $0, profileID: model.profileID(for: $0)) }
        _ = model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .shift)
        let work = model.store.spaces[1].id
        model.moveItems(model.keySelectionIDs!, toSpace: work)
        XCTAssertEqual(model.store.outline(for: work).today.map(\.id), google.map(\.id))
        for (tab, engine) in zip(google, engines) {
            XCTAssertTrue(model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) === engine)
        }
        XCTAssertEqual(model.store.activeSpaceID, work, "the shown tab went with them")
    }

    func testOpenInSplitViewAndNewFolder() {
        let (model, memo, google) = makeFixture()
        _ = model.handleSelectionClick(on: google[1].id, in: nil, modifiers: .shift)
        let ids = model.keySelectionIDs!
        XCTAssertTrue(model.canOpenInSplitView(ids))
        model.openInSplitView(ids)
        XCTAssertEqual(model.activeSplit?.tabs.map(\.id), [google[0].id, google[1].id])

        model.selectTab(memo.id)
        _ = model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .command)
        model.newFolder(withSelection: model.keySelectionIDs!)
        let folder = model.store.outline(for: model.store.activeSpaceID).pinned.first { $0.kind == .folder }
        XCTAssertEqual(folder?.children.map(\.id), [memo.id, google[2].id])
    }

    // MARK: Move to Profile

    func testMovingASelectionToAnotherProfileAsksOnceAndChangesEverySession() throws {
        let (model, memo, google) = makeFixture()
        let source = model.store.activeProfileID
        let work = model.store.addProfile(name: "Work")
        let workSpace = model.store.spaces(in: work.id)[0].id
        let old = google.map { model.engineHost.engine(for: $0, profileID: source) }
        model.boostSelectorFingerprintByTab[google[0].id] = BoostSelectorFingerprint(tag: "div", classHints: ["inbox"])
        _ = model.handleSelectionClick(on: google[2].id, in: nil, modifiers: .shift)
        let ids = try XCTUnwrap(model.keySelectionIDs)

        model.requestProfileMove(ids, toSpace: workSpace)
        let pending = try XCTUnwrap(model.pendingProfileMove, "one confirmation for the three tabs")
        let text = model.profileMoveMessage(pending)
        XCTAssertEqual(text.title, "Move to Work?")
        XCTAssertTrue(text.message.hasPrefix("These 3 tabs will reload in Work."), text.message)
        XCTAssertEqual(model.store.spaceContaining(tabID: google[0].id), model.store.spaces(in: source)[0].id, "nothing moves before Move")

        model.confirmProfileMove()
        XCTAssertNil(model.pendingProfileMove)
        XCTAssertEqual(model.store.outline(for: workSpace).today.map(\.id), google.map(\.id), "order and section kept")
        XCTAssertEqual(model.store.tab(withID: google[1].id)?.url, google[1].url)
        XCTAssertEqual(model.store.activeProfileID, work.id, "the shown tab went along")
        XCTAssertEqual(model.store.selectedTabID, google[0].id)
        let keys = model.engineHost.allTabEngines()
        for (tab, previous) in zip(google, old) {
            XCTAssertFalse(keys.contains { $0.0 == tab.id && $0.1 == source }, "no engine of the old profile stays")
            let current = try XCTUnwrap(model.engineHost.engine(forTabID: tab.id, profileID: work.id), "a live page reloads in Work")
            XCTAssertFalse(current === previous)
        }
        XCTAssertEqual(model.store.spaceContaining(tabID: memo.id), model.store.spaces(in: source)[0].id, "unselected rows stay")
        XCTAssertNil(model.boostSelectorFingerprintByTab[google[0].id], "the old page's boost picking does not follow")
    }

    func testOneFolderOrSplitMovesToAnotherProfileWithItsTabs() throws {
        let (model, memo, google) = makeFixture()
        let work = model.store.addProfile(name: "Work")
        let workSpace = model.store.spaces(in: work.id)[0].id
        let folder = try XCTUnwrap(model.store.createFolder(containing: [memo.id]))
        let split = try XCTUnwrap(model.store.createSplit(tabIDs: [google[1].id, google[2].id], orientation: .horizontal))

        model.requestProfileMove([folder.id], toSpace: workSpace)
        XCTAssertTrue(try XCTUnwrap(model.pendingProfileMove.map(model.profileMoveMessage)).message.hasPrefix("This tab will reload in Work."))
        model.confirmProfileMove()
        XCTAssertEqual(model.store.parentFolderID(of: memo.id), folder.id)
        XCTAssertEqual(model.store.spaceContaining(entryID: folder.id), workSpace)
        XCTAssertEqual(model.store.kind(of: memo.id), .pinned)

        model.requestProfileMove([split.id], toSpace: workSpace)
        model.confirmProfileMove()
        XCTAssertEqual(model.store.split(withID: split.id)?.tabs.map(\.id), [google[1].id, google[2].id])
        XCTAssertEqual(model.store.spaceContaining(entryID: split.id), workSpace)

        // Within one profile there is nothing to confirm.
        model.requestProfileMove([google[0].id], toSpace: model.store.spaces(in: model.store.profiles[0].id)[1].id)
        XCTAssertNil(model.pendingProfileMove)
        XCTAssertEqual(model.store.spaceContaining(tabID: google[0].id), model.store.spaces(in: model.store.profiles[0].id)[1].id)
    }
}
