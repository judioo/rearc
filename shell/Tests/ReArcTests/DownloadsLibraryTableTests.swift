import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// perf-8: Library › Downloads' AppKit table follows the tray through
/// observation, filters by the search, takes archived pages as appends, and
/// gives its plain cells the row's text, buttons, menu and VoiceOver label.
@MainActor
final class DownloadsLibraryTableTests: XCTestCase {
    private var window: NSWindow!

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func makeTable(_ downloads: DownloadsController, query: String = "") -> (DownloadsTableController, DownloadsTableState, NSTableView) {
        let state = DownloadsTableState()
        let controller = DownloadsTableController(downloads: downloads, state: state, query: query)
        let scroll = controller.makeScrollView()
        // Off every screen, so the table has a window and lays out its rows.
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 305, height: 480),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFrontRegardless()
        let table = scroll.documentView as! NSTableView
        table.layoutSubtreeIfNeeded()
        return (controller, state, table)
    }

    /// Lets the queued rebuild run.
    private func drain() {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func finished(_ id: String, url: String? = nil) -> DownloadEvent {
        DownloadEvent(kind: .created, guid: id, url: url ?? "https://example.test/\(id)", targetPath: "/tmp/rearc-tests/\(id).zip",
                      totalBytes: 2_048, state: .complete)
    }

    private func archived(_ id: String) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: "https://archive.test/\(id)", targetPath: "/tmp/rearc-tests/\(id).pdf",
                       totalBytes: 1_024, state: .complete, startedAt: Date(timeIntervalSince1970: 0))
    }

    private func cell(_ table: NSTableView, _ row: Int) -> DownloadsTableCell? {
        table.view(atColumn: 0, row: row, makeIfNecessary: true) as? DownloadsTableCell
    }

    func testRowsFollowTheTray() {
        let downloads = DownloadsController(fileURL: nil)
        let (controller, state, table) = makeTable(downloads)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.hasNoDownloads)

        downloads.apply([finished("a"), finished("b")], source: .chromium)
        drain()
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertFalse(state.isEmpty)

        // A new transfer goes in at the top.
        downloads.apply(DownloadEvent(kind: .created, guid: "new", url: "https://example.test/new", totalBytes: 100, state: .inProgress),
                        source: .chromium)
        drain()
        XCTAssertEqual(controller.rows.records.map(\.id), ["new", "a", "b"])
        XCTAssertEqual(table.numberOfRows, 3)

        // Its progress redraws its cell in place.
        downloads.apply(DownloadEvent(kind: .updated, guid: "new", url: "https://example.test/new", receivedBytes: 50, totalBytes: 100,
                                      state: .inProgress), source: .chromium)
        drain()
        XCTAssertEqual(cell(table, 0)?.record?.receivedBytes, 50)

        downloads.perform(.remove, on: "a")
        drain()
        XCTAssertEqual(controller.rows.records.map(\.id), ["new", "b"])
        XCTAssertEqual(table.numberOfRows, 2)
    }

    func testSearchFiltersTheTable() {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply([finished("report", url: "https://docs.test/x"), finished("photo", url: "https://pics.test/y"),
                         finished("other", url: "https://docs.test/z")], source: .chromium)
        let (controller, state, table) = makeTable(downloads, query: "docs")
        XCTAssertEqual(controller.rows.records.map(\.id), ["report", "other"], "the site matches too")

        controller.setQuery("photo")
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(controller.rows.records.map(\.id), ["photo"])

        controller.setQuery("nothing")
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.hasNoDownloads, "No matches, not No downloads yet")

        controller.setQuery("")
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertFalse(state.isEmpty)

        // A row that arrives while searching shows only when it matches.
        controller.setQuery("docs")
        downloads.apply([finished("late", url: "https://docs.test/late"), finished("miss", url: "https://else.test/")], source: .chromium)
        drain()
        XCTAssertEqual(controller.rows.records.map(\.id), ["report", "other", "late"])
    }

    func testArchivedPagesAppendWithoutMovingTheList() {
        let downloads = DownloadsController(fileURL: nil, turnBudget: DownloadsController.appTurnBudget)
        downloads.apply((0 ..< 60).map { finished("live-\($0)") }, source: .chromium)
        while downloads.hasPendingWork { drain() }
        let (controller, _, table) = makeTable(downloads)
        XCTAssertEqual(table.numberOfRows, 60)
        let clip = try! XCTUnwrap(table.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 20 * DownloadsTableMetrics.rowPitch))
        let scrolled = clip.bounds.minY

        // The engine's archived rows, 500 a turn.
        downloads.appendArchived((0 ..< 2_100).map { archived("old-\($0)") }, profile: 1)
        while downloads.hasPendingWork { drain() }
        drain()
        XCTAssertEqual(table.numberOfRows, 2_160)
        XCTAssertEqual(controller.rows.records.last?.id, "old-2099")
        XCTAssertEqual(clip.bounds.minY, scrolled, "appends below keep the scroll position")

        // A new download at the top keeps what is on screen in place.
        downloads.apply(DownloadEvent(kind: .created, guid: "new", url: "https://example.test/new", state: .inProgress), source: .chromium)
        drain()
        XCTAssertEqual(table.numberOfRows, 2_161)
        XCTAssertEqual(clip.bounds.minY, scrolled + DownloadsTableMetrics.rowPitch, accuracy: 0.5)
    }

    func testEveryRowHasTheSamePitch() {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply((0 ..< 39_414).map { finished("r\($0)") }, source: .chromium)
        let start = ProcessInfo.processInfo.systemUptime
        let (_, _, table) = makeTable(downloads)
        XCTAssertEqual(table.numberOfRows, 39_414)
        XCTAssertEqual(table.rowHeight, DownloadsTableMetrics.rowPitch)
        XCTAssertEqual(table.rect(ofRow: 39_413).maxY, 39_414 * DownloadsTableMetrics.rowPitch, accuracy: 0.5)
        // Only the visible rows have views.
        var made = 0
        table.enumerateAvailableRowViews { _, _ in made += 1 }
        XCTAssertLessThan(made, 40)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "debug build, generous")
    }

    func testCellsDrawTheRowsStates() throws {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply([
            finished("done"),
            DownloadEvent(kind: .created, guid: "busy", url: "https://example.test/busy", targetPath: "/tmp/rearc-tests/busy.dmg",
                          receivedBytes: 512, totalBytes: 1_024, state: .inProgress),
            DownloadEvent(kind: .created, guid: "failed", url: "https://example.test/failed", targetPath: "/tmp/rearc-tests/failed.zip",
                          state: .interrupted, interruptReason: 2, canResume: true),
            DownloadEvent(kind: .created, guid: "risky", url: "https://example.test/risky", targetPath: "/tmp/rearc-tests/risky.exe",
                          state: .inProgress, dangerType: 1),
        ], source: .chromium)
        let (controller, _, table) = makeTable(downloads)
        let ids = controller.rows.records.map(\.id)
        func row(_ id: String) throws -> DownloadsTableCell { try XCTUnwrap(cell(table, try XCTUnwrap(ids.firstIndex(of: id)))) }

        let done = try row("done")
        XCTAssertEqual(done.accessibilityRole(), .group)
        XCTAssertEqual(done.accessibilityLabel(), "done.zip, \(try XCTUnwrap(done.record).statusText)")
        XCTAssertEqual(done.toolTip, "https://example.test/done")
        let doneButtons = done.subviews.compactMap { $0 as? DownloadsRowButton }.filter { !$0.isHidden }
        XCTAssertEqual(doneButtons.map(\.toolTip), ["Show in Finder"])
        let actions = try XCTUnwrap(done.accessibilityCustomActions()).map(\.name)
        XCTAssertEqual(actions, ["Open", "Show in Finder", "Copy Download Link", "Remove from List"])

        let busy = try row("busy")
        XCTAssertEqual(busy.subviews.compactMap { $0 as? DownloadsRowButton }.filter { !$0.isHidden }.map(\.toolTip), ["Pause", "Cancel"])

        let failed = try row("failed")
        XCTAssertEqual(failed.subviews.compactMap { $0 as? DownloadsRowButton }.filter { !$0.isHidden }.map(\.toolTip), ["Resume"])

        // A dangerous transfer: Discard instead of the round buttons, and an orange row.
        let risky = try row("risky")
        XCTAssertTrue(downloads.needsDecision(try XCTUnwrap(risky.record)))
        XCTAssertTrue(risky.subviews.compactMap { $0 as? DownloadsRowButton }.allSatisfy(\.isHidden))
        let discard = try XCTUnwrap(risky.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Discard" })
        XCTAssertFalse(discard.isHidden)
        XCTAssertTrue(risky.accessibilityLabel()?.hasSuffix("Needs a decision") == true)
        let riskyRow = try XCTUnwrap(ids.firstIndex(of: "risky"))
        XCTAssertEqual((table.rowView(atRow: riskyRow, makeIfNecessary: true) as? DownloadsTableRowView)?.isWarned, true)
    }

    func testMenuActsOnTheSelection() throws {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply([finished("a"), finished("b"), finished("c")], source: .chromium)
        let (controller, _, table) = makeTable(downloads)
        XCTAssertEqual(controller.menuItems(for: [try XCTUnwrap(controller.record(at: 0))]).map(\.title),
                       ["Open", "Show in Finder", "", "Copy Download Link", "Remove from List"])

        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        controller.copySelection()
        let first = try XCTUnwrap(controller.record(at: 0)), last = try XCTUnwrap(controller.record(at: 2))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "\(first.url)\n\(last.url)")
        controller.removeSelection()
        drain()
        XCTAssertEqual(controller.rows.records.map(\.id), ["b"])
    }

    func testFilesDragOutAsFileURLs() throws {
        let downloads = DownloadsController(fileURL: nil)
        downloads.apply([finished("a"), DownloadEvent(kind: .created, guid: "busy", url: "https://example.test/busy", state: .inProgress)],
                        source: .chromium)
        let (controller, _, table) = makeTable(downloads)
        let busy = try XCTUnwrap(controller.rows.records.firstIndex { $0.id == "busy" })
        let done = try XCTUnwrap(controller.rows.records.firstIndex { $0.id == "a" })
        XCTAssertNil(controller.tableView(table, pasteboardWriterForRow: busy))
        let writer = try XCTUnwrap(controller.tableView(table, pasteboardWriterForRow: done) as? NSURL)
        XCTAssertEqual(writer.path, "/tmp/rearc-tests/a.zip")
    }
}
