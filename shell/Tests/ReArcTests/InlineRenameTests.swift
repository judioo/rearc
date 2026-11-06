import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

private typealias Tab = SidebarModel.Tab

/// Renaming a tab or folder in its own row, as Arc does
/// (docs/arc-recordings/2026-11-06-tab-rename.md).
@MainActor
final class InlineRenameTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Work", sortRank: "b")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-rename-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-rename-\(UUID().uuidString)")!
        return model
    }

    // MARK: The edit's state

    func testBeginShowsTheOldNameSelectedWithItAsThePlaceholder() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Google", url: url("g"))
        model.beginRename(.tab(tab.id))
        XCTAssertNil(model.pendingRename, "no alert")
        let rename = try! XCTUnwrap(model.inlineRename)
        XCTAssertEqual(rename.target, .tab(tab.id))
        XCTAssertEqual(rename.previousName, "Google", "the placeholder once the field is emptied")
        XCTAssertEqual(rename.text, "Google")
        XCTAssertNotNil(model.inlineRename(forRow: tab.id))
        XCTAssertNil(model.inlineRename(forRow: UUID()))
    }

    func testTypingThenReturnSaves() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "Google", url: url("g"))
        model.beginRename(.tab(tab.id))
        model.updateInlineRename("rename in place")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.displayTitle, "Google", "nothing is saved while typing")
        model.endInlineRename(.commit)
        XCTAssertNil(model.inlineRename)
        XCTAssertEqual(model.store.tab(withID: tab.id)?.displayTitle, "rename in place")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.title, "Google", "the page title is kept underneath")
    }

    func testEscPutsTheOldNameBack() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Google", url: url("g"))
        model.store.renameTab(tab.id, to: "rename in place")
        model.beginRename(.tab(tab.id))
        model.updateInlineRename("")
        model.updateInlineRename("half-typ")
        model.endInlineRename(.cancel)
        XCTAssertNil(model.inlineRename)
        XCTAssertEqual(model.store.tab(withID: tab.id)?.customTitle, "rename in place")
    }

    func testAnEmptyNameFallsBackToThePageTitle() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Google", url: url("g"))
        model.store.renameTab(tab.id, to: "rename in place")
        model.beginRename(.tab(tab.id))
        model.updateInlineRename("  ")
        model.endInlineRename(.commit)
        XCTAssertNil(model.store.tab(withID: tab.id)?.customTitle)
        XCTAssertEqual(model.store.tab(withID: tab.id)?.displayTitle, "Google")
    }

    func testReturnWithoutAChangeLeavesThePageTitleLive() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Google", url: url("g"))
        model.beginRename(.tab(tab.id))
        model.endInlineRename(.commit)
        XCTAssertNil(model.store.tab(withID: tab.id)?.customTitle, "the title still follows the page")
        model.store.updateTab(tab.id, title: "Google Search")
        XCTAssertEqual(model.store.tab(withID: tab.id)?.displayTitle, "Google Search")
    }

    func testSavedNameTrimsAndOnlyCommitsSave() {
        var rename = SidebarInlineRename(target: .tab(UUID()), previousName: "Old")
        XCTAssertNil(rename.savedName(on: .commit), "unchanged")
        rename.text = "  New \n"
        XCTAssertEqual(rename.savedName(on: .commit), "New")
        XCTAssertNil(rename.savedName(on: .cancel))
        rename.text = ""
        XCTAssertEqual(rename.savedName(on: .commit), "", "clears a tab's custom title")
        var folder = SidebarInlineRename(target: .folder(UUID()), previousName: "Work")
        folder.text = " "
        XCTAssertNil(folder.savedName(on: .commit), "a folder keeps its name")
    }

    // MARK: Focus leaving

    func testStartingAnotherRenameSavesTheFirst() {
        let model = makeModel()
        let a = model.store.addTab(kind: .today, title: "A", url: url("a"))
        let b = model.store.addTab(kind: .today, title: "B", url: url("b"))
        model.beginRename(.tab(a.id))
        model.updateInlineRename("Alpha")
        model.beginRename(.tab(b.id))
        XCTAssertEqual(model.store.tab(withID: a.id)?.displayTitle, "Alpha")
        XCTAssertEqual(model.inlineRename?.target, .tab(b.id))
        model.updateInlineRename("Beta")
        model.beginRename(.tab(b.id))
        XCTAssertEqual(model.inlineRename?.text, "Beta", "the same row again keeps the edit")
    }

    func testALeftoverFieldCannotEndTheNextRename() {
        let model = makeModel()
        let a = model.store.addTab(kind: .today, title: "A", url: url("a"))
        let b = model.store.addTab(kind: .today, title: "B", url: url("b"))
        model.beginRename(.tab(a.id))
        let fieldA = try! XCTUnwrap(SidebarRowRename(row: a.id, model: model))
        model.beginRename(.tab(b.id))
        // Row A's field, on its way out, types and loses focus.
        fieldA.onChange("late")
        fieldA.onEnd(.commit, false)
        XCTAssertEqual(model.inlineRename?.target, .tab(b.id))
        XCTAssertEqual(model.inlineRename?.text, "B")
        XCTAssertNil(SidebarRowRename(row: a.id, model: model))
        XCTAssertEqual(model.store.tab(withID: a.id)?.displayTitle, "A")
    }

    func testTheFieldEndsOnceForReturnEscAndFocusLoss() {
        var endings: [(SidebarInlineRename.Ending, Bool)] = []
        let make = {
            SidebarRenameField(
                rename: SidebarInlineRename(target: .tab(UUID()), previousName: "Old"),
                onChange: { _ in }, onEnd: { endings.append(($0, $1)) }
            ).makeCoordinator()
        }
        let field = NSTextField(string: "x")
        let editor = NSTextView()

        let esc = make()
        XCTAssertTrue(esc.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        esc.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        let ret = make()
        XCTAssertTrue(ret.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let away = make()
        XCTAssertFalse(away.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))), "editing keys stay the editor's")
        away.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        away.finish(.commit, byKey: false)

        XCTAssertEqual(endings.map(\.0), [.cancel, .commit, .commit])
        XCTAssertEqual(endings.map(\.1), [true, true, false], "Return and Esc hand focus back to the page")
    }

    func testTypingReachesTheModel() {
        var typed: [String] = []
        let coordinator = SidebarRenameField(
            rename: SidebarInlineRename(target: .tab(UUID()), previousName: "Old"),
            onChange: { typed.append($0) }, onEnd: { _, _ in }
        ).makeCoordinator()
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: NSTextField(string: "re")))
        XCTAssertEqual(typed, ["re"])
    }

    // MARK: Which renames go in the row

    func testFolderRenamesInPlaceAndANewFolderStartsThere() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "Page", url: url("p"))
        let folder = try XCTUnwrap(model.newFolder(containing: [tab.id]))
        XCTAssertEqual(model.inlineRename?.target, .folder(folder.id))
        XCTAssertNil(model.pendingRename)
        model.updateInlineRename("Work")
        model.endInlineRename(.commit)
        XCTAssertEqual(model.store.folder(withID: folder.id)?.title, "Work")
        model.beginRename(.folder(folder.id))
        model.updateInlineRename("")
        model.endInlineRename(.commit)
        XCTAssertEqual(model.store.folder(withID: folder.id)?.title, "Work")
    }

    func testARowInACollapsedFolderIsShownToRename() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "Page", url: url("p"))
        let outer = try XCTUnwrap(model.store.createFolder(containing: [tab.id]))
        let inner = try XCTUnwrap(model.store.createFolder(parentFolderID: outer.id, containing: [tab.id]))
        model.store.setFolderExpanded(outer.id, false)
        model.store.setFolderExpanded(inner.id, false)
        model.beginRename(.tab(tab.id))
        XCTAssertEqual(model.inlineRename?.target, .tab(tab.id))
        XCTAssertTrue(model.store.isFolderExpanded(outer.id))
        XCTAssertTrue(model.store.isFolderExpanded(inner.id))
    }

    func testRowsNotOnScreenUseTheAlert() {
        let model = makeModel()
        let favorite = model.store.addTab(kind: .favorite, title: "Fav", url: url("f"))
        model.beginRename(.tab(favorite.id))
        XCTAssertNil(model.inlineRename, "a favorite has no title row")
        XCTAssertEqual(model.pendingRename, .tab(favorite.id))
        model.pendingRename = nil

        let work = model.store.spaces[1].id
        let elsewhere = model.store.addTab(kind: .today, title: "Else", url: url("e"), in: work)
        model.beginRename(.tab(elsewhere.id))
        XCTAssertNil(model.inlineRename, "another space's row is not shown")
        XCTAssertEqual(model.pendingRename, .tab(elsewhere.id))
        model.pendingRename = nil

        let tab = model.store.addTab(kind: .today, title: "Here", url: url("h"))
        model.isSidebarVisible = false
        model.beginRename(.tab(tab.id))
        XCTAssertNil(model.inlineRename, "a hidden sidebar")
        XCTAssertEqual(model.pendingRename, .tab(tab.id))
        model.pendingRename = nil
        model.isSidebarVisible = true

        model.beginRename(.space(model.store.activeSpaceID))
        XCTAssertNil(model.inlineRename)
        XCTAssertEqual(model.pendingRename, .space(model.store.activeSpaceID), "spaces keep the alert")
    }

    // MARK: The plain row

    func testTheRenamedCellHostsTheField() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Tea", url: url("tea"))
        let context = SidebarListCellContext(
            chrome: ThemeChromeColors(theme: .default, dark: false), window: nil, pager: nil, colorScheme: .light, tint: .blue)
        let controller = SidebarListController(model: model, spaceID: model.store.activeSpaceID, context: context)
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
        func field(in view: NSView) -> SidebarRenameTextField? {
            if let field = view as? SidebarRenameTextField { return field }
            return view.subviews.lazy.compactMap(field(in:)).first
        }

        drain()
        XCTAssertNil(field(in: try cell()))
        model.beginRename(.tab(tab.id))
        drain()
        let renaming = try cell()
        renaming.layoutSubtreeIfNeeded()
        let shown = try XCTUnwrap(field(in: renaming), "the row hosts the field without the pointer over it")
        XCTAssertEqual(shown.stringValue, "Tea")
        XCTAssertEqual(shown.placeholderAttributedString?.string, "Tea")
        model.endInlineRename(.cancel)
        drain()
        XCTAssertNil(field(in: try cell()))
    }

    func testTheRenamedRowStaysHosted() {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Google", url: url("g"))
        let space = model.store.activeSpaceID
        let chrome = ThemeChromeColors.fallback
        XCTAssertFalse(PlainRowState.read(id: tab.id, model: model, spaceID: space, chrome: chrome).needsHosting)
        model.beginRename(.tab(tab.id))
        XCTAssertTrue(PlainRowState.read(id: tab.id, model: model, spaceID: space, chrome: chrome).needsHosting,
                      "the field keeps focus when the pointer leaves the row")
        model.endInlineRename(.cancel)
        XCTAssertFalse(PlainRowState.read(id: tab.id, model: model, spaceID: space, chrome: chrome).needsHosting)
    }
}
