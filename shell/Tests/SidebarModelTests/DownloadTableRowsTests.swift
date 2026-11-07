import XCTest
@testable import SidebarModel

/// perf-8: Library › Downloads' table edits from one list to the next.
final class DownloadTableRowsTests: XCTestCase {
    private func record(_ id: String, received: Int64 = 0, state: DownloadState = .complete) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: "https://example.test/\(id)", targetPath: "/tmp/\(id).zip",
                       receivedBytes: received, totalBytes: 100, state: state, startedAt: Date(timeIntervalSince1970: 0))
    }

    private func records(_ ids: [String]) -> [DownloadRecord] { ids.map { record($0) } }

    /// Applies `update` to `old`'s ids the way the table does.
    private func applied(_ update: DownloadTableRows.Update, old: [String], new: [String]) -> [String] {
        if update.reloadsAll { return new }
        var ids = old
        for index in update.removed.reversed() { ids.remove(at: index) }
        for index in update.inserted { ids.insert(new[index], at: index) }
        return ids
    }

    func testFirstRowsAndEmptyingReloadEverything() {
        var rows = DownloadTableRows()
        XCTAssertTrue(rows.update(to: []).isEmpty)
        XCTAssertTrue(rows.update(to: records(["a", "b"])).reloadsAll)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.update(to: []).reloadsAll)
    }

    func testNewDownloadIsAnInsertAtTheTop() {
        var rows = DownloadTableRows(records: records(["a", "b", "c"]))
        let update = rows.update(to: records(["n", "a", "b", "c"]))
        XCTAssertEqual(update, DownloadTableRows.Update(inserted: [0]))
        XCTAssertEqual(update.insertedAbove, 1)
    }

    func testArchivedPagesAreAppendsHoweverLarge() {
        let live = (0 ..< 50).map { "live-\($0)" }
        var rows = DownloadTableRows(records: records(live))
        var ids = live
        // The tray takes archived rows 500 at a time; the last page is short.
        for page in 0 ..< 4 {
            let chunk = (0 ..< (page == 3 ? 137 : 500)).map { "old-\(page)-\($0)" }
            let update = rows.update(to: records(ids + chunk))
            XCTAssertFalse(update.reloadsAll, "an append past the edit limit is still an append")
            XCTAssertEqual(update.inserted, IndexSet(integersIn: ids.count ..< ids.count + chunk.count))
            XCTAssertEqual(update.insertedAbove, 0)
            XCTAssertTrue(update.removed.isEmpty)
            ids += chunk
        }
        XCTAssertEqual(rows.records.map(\.id), ids)
    }

    func testRemovedRowAndChangedRows() {
        var rows = DownloadTableRows(records: [record("a"), record("b", received: 10, state: .inProgress), record("c"), record("d")])
        let update = rows.update(to: [record("a"), record("b", received: 60, state: .inProgress), record("d")])
        XCTAssertEqual(update.removed, [2])
        XCTAssertTrue(update.inserted.isEmpty)
        XCTAssertEqual(update.reloaded, [1], "the transfer's progress reloads its row alone")
        // Progress alone: no structural change.
        let progress = rows.update(to: [record("a"), record("b", received: 90, state: .inProgress), record("d")])
        XCTAssertEqual(progress, DownloadTableRows.Update(reloaded: [1]))
        XCTAssertTrue(rows.update(to: rows.records).isEmpty)
    }

    func testSearchReloadsAndLargeMiddleChangesReload() {
        let ids = (0 ..< 1_000).map { "r\($0)" }
        var rows = DownloadTableRows(records: records(ids))
        XCTAssertTrue(rows.update(to: records(Array(ids.prefix(10))), reloadAll: true).reloadsAll)
        rows = DownloadTableRows(records: records(ids))
        // Clear keeps a few rows: past the edit limit, reload.
        XCTAssertTrue(rows.update(to: records(["r0", "r999"])).reloadsAll)
    }

    func testRandomEditsApplyBack() {
        var generator = SystemRandomNumberGenerator()
        var ids = (0 ..< 40).map { "r\($0)" }
        var rows = DownloadTableRows(records: records(ids))
        var next = 40
        for _ in 0 ..< 300 {
            var new = ids
            switch Int.random(in: 0 ..< 4, using: &generator) {
            case 0:
                new.insert(contentsOf: (0 ..< Int.random(in: 1 ... 3)).map { _ in next += 1; return "n\(next)" }, at: 0)
            case 1:
                new += (0 ..< Int.random(in: 1 ... 30)).map { _ in next += 1; return "n\(next)" }
            case 2:
                if !new.isEmpty { new.remove(at: Int.random(in: 0 ..< new.count)) }
            default:
                new.shuffle()
            }
            let update = rows.update(to: records(new))
            XCTAssertEqual(applied(update, old: ids, new: new), new)
            ids = new
        }
    }

    func testMenuTargets() {
        // A click inside the selection acts on the selection; outside it, on the clicked row.
        XCTAssertEqual(DownloadTableRows.targets(clicked: 2, selected: [1, 2, 3], count: 5), [1, 2, 3])
        XCTAssertEqual(DownloadTableRows.targets(clicked: 4, selected: [1, 2, 3], count: 5), [4])
        // A key acts on the selection.
        XCTAssertEqual(DownloadTableRows.targets(clicked: -1, selected: [0, 7], count: 5), [0])
        XCTAssertEqual(DownloadTableRows.targets(clicked: -1, selected: [], count: 5), [])
    }

    /// 39,414 rows, one transfer's progress: one pass over the list.
    func testProgressOverALongListIsCheap() {
        let all = (0 ..< 39_414).map { record("r\($0)") }
        var rows = DownloadTableRows(records: all)
        var changed = all
        changed[0] = record("r0", received: 50, state: .inProgress)
        let start = ProcessInfo.processInfo.systemUptime
        let update = rows.update(to: changed)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(update, DownloadTableRows.Update(reloaded: [0]))
        XCTAssertLessThan(elapsed, 0.25, "debug build, generous")
    }
}
