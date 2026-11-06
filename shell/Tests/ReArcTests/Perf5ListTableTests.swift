import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// perf-5: the sidebar table's controller follows the store through
/// observation, adds the drop rows for a drag and reports row heights.
@MainActor
final class Perf5ListTableTests: XCTestCase {
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

    /// Lets the queued rebuild run.
    private func drain() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testRowsFollowTheOutline() throws {
        let (store, _, controller, table) = makeController()
        XCTAssertEqual(controller.rows.map(\.id), [.header, .todayDivider, .newTab])
        XCTAssertEqual(table.numberOfRows, 3)

        let a = store.addTab(kind: .pinned, title: "A", url: url("a"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("b"))
        let t = store.addTab(kind: .today, title: "T", url: url("t"))
        drain()
        XCTAssertEqual(controller.rows.map(\.id), [.header, .item(a.id), .item(b.id), .todayDivider, .newTab, .item(t.id)])
        XCTAssertEqual(table.numberOfRows, 6)

        let folder = try XCTUnwrap(store.createFolder(title: "F", containing: [a.id, b.id]))
        drain()
        // A new folder opens expanded; collapsing it takes its rows away.
        XCTAssertEqual(controller.rows.map(\.id), [.header, .item(folder.id), .item(a.id), .item(b.id), .todayDivider, .newTab, .item(t.id)])
        XCTAssertEqual(table.numberOfRows, 7)
        store.toggleFolderExpanded(folder.id)
        drain()
        XCTAssertEqual(controller.rows.map(\.id), [.header, .item(folder.id), .todayDivider, .newTab, .item(t.id)])
        XCTAssertEqual(table.numberOfRows, 5)

        // A title change stays in the row's cell: the row list is untouched.
        let before = controller.rows
        store.updateTab(t.id, title: "Renamed")
        drain()
        XCTAssertEqual(controller.rows, before)
    }

    func testDragAddsSectionDropRows() {
        let (store, _, controller, table) = makeController()
        let t = store.addTab(kind: .today, title: "T", url: url("t"))
        drain()
        controller.update(spaceID: store.activeSpaceID, isDragging: true)
        XCTAssertEqual(controller.rows, [
            .header, .sectionEnd(.pinned, isEmpty: true), .todayDivider, .newTab,
            .item(SidebarOutlineRow(node: SidebarOutlineNode(id: t.id, kind: .tab), depth: 0), section: .unpinned),
            .sectionEnd(.unpinned, isEmpty: false),
        ])
        XCTAssertEqual(table.numberOfRows, 6)
        controller.update(spaceID: store.activeSpaceID, isDragging: false)
        XCTAssertEqual(table.numberOfRows, 4)
    }

    func testHeightsAndCells() {
        let (store, _, controller, table) = makeController()
        _ = store.addTab(kind: .today, title: "T", url: url("t"))
        drain()
        let heights = (0 ..< table.numberOfRows).map { controller.tableView(table, heightOfRow: $0) }
        XCTAssertEqual(heights, [SidebarMetrics.headerHeight + SidebarMetrics.headerToFirstRow, 17, SidebarMetrics.rowPitch, SidebarMetrics.rowPitch])
        XCTAssertFalse(controller.tableView(table, shouldSelectRow: 3))
        let cell = controller.tableView(table, viewFor: table.tableColumns.first, row: 3)
        XCTAssertNotNil(cell?.subviews.first as? NSHostingView<SidebarListCell>)
    }
}
