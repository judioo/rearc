import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// perf-7: tab and folder rows draw in AppKit and host their SwiftUI row
/// only while it is live (a drag, a rare badge, the pointer over it).
@MainActor
final class Perf7PlainRowTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    private func makeController() -> (SidebarStore, BrowserViewModel, SidebarListController, NSTableView) {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        let context = SidebarListCellContext(
            chrome: ThemeChromeColors(theme: .default, dark: false), window: nil, pager: nil, colorScheme: .light, tint: .blue)
        let controller = SidebarListController(model: model, spaceID: store.activeSpaceID, context: context)
        let scroll = controller.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 228, height: 600)
        let table = scroll.documentView as! NSTableView
        return (store, model, controller, table)
    }

    private func drain() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func cell(_ controller: SidebarListController, _ table: NSTableView, _ id: UUID) throws -> SidebarPlainRowCell {
        let index = try XCTUnwrap(controller.rows.firstIndex { $0.id == .item(id) })
        return try XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns.first, row: index) as? SidebarPlainRowCell)
    }

    private func hosted(_ cell: SidebarPlainRowCell) -> Bool {
        cell.subviews.contains { $0 is NSHostingView<SidebarHostedRow> }
    }

    func testPlainRowsFollowTheModel() throws {
        let (store, model, controller, table) = makeController()
        let t = store.addTab(kind: .today, title: "Tea", url: url("tea"))
        drain()
        let row = try cell(controller, table, t.id)
        XCTAssertFalse(hosted(row))
        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertEqual(row.accessibilityRole(), .button)
        XCTAssertEqual(row.accessibilityLabel(), "Tea")

        store.updateTab(t.id, title: "Coffee")
        drain()
        XCTAssertEqual(row.accessibilityLabel(), "Coffee")

        let other = store.addTab(kind: .today, title: "Other", url: url("other"))
        model.selectTab(other.id)
        drain()
        XCTAssertFalse(row.isAccessibilitySelected())
        XCTAssertTrue(row.accessibilityPerformPress())
        drain()
        XCTAssertTrue(store.isSelected(t.id, inSpace: store.activeSpaceID))
        XCTAssertTrue(row.isAccessibilitySelected())
    }

    func testFolderRowPressToggles() throws {
        let (store, _, controller, table) = makeController()
        let a = store.addTab(kind: .pinned, title: "A", url: url("a"))
        let folder = try XCTUnwrap(store.createFolder(title: "Work", containing: [a.id]))
        drain()
        let row = try cell(controller, table, folder.id)
        XCTAssertEqual(row.accessibilityLabel(), "Work")
        XCTAssertEqual(row.accessibilityValue() as? String, "expanded")
        XCTAssertTrue(row.accessibilityPerformPress())
        drain()
        XCTAssertFalse(store.isFolderExpanded(folder.id))
        XCTAssertEqual(row.accessibilityValue() as? String, "collapsed")
    }

    /// A drag makes every visible plain row host its SwiftUI row, so the
    /// rows' drop targets are there; the end of the drag takes them away.
    func testDragHostsTheRows() throws {
        let (store, _, controller, table) = makeController()
        let t = store.addTab(kind: .today, title: "T", url: url("t"))
        drain()
        table.layoutSubtreeIfNeeded()
        let row = try cell(controller, table, t.id)
        XCTAssertFalse(hosted(row))
        controller.update(spaceID: store.activeSpaceID, isDragging: true)
        let during = try cell(controller, table, t.id)
        XCTAssertTrue(hosted(during))
        XCTAssertFalse(during.isAccessibilityElement())
        controller.update(spaceID: store.activeSpaceID, isDragging: false)
        let after = try cell(controller, table, t.id)
        XCTAssertFalse(hosted(after))
    }

    func testOnlyTabAndFolderRowsArePlain() {
        let tab = SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: .tab), depth: 0)
        let split = SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: .split), depth: 0)
        XCTAssertTrue(SidebarListController.isPlain(.item(tab, section: .unpinned)))
        XCTAssertFalse(SidebarListController.isPlain(.item(split, section: .unpinned)))
        XCTAssertFalse(SidebarListController.isPlain(.header))
        XCTAssertFalse(SidebarListController.isPlain(.newTab))
    }
}
