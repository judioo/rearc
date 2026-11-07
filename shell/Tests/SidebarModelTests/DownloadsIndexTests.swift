import Foundation
import SidebarModel
import XCTest

/// Downloads at scale (docs/DOWNLOADS-AT-SCALE.md): the list's kept counts
/// and quick view index against a pass over every row, and the per-turn
/// budget for bursts of engine events.
final class DownloadsIndexTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fixed sequence, so a failure replays.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private func assertIndexesMatch(_ list: DownloadList, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let records = list.records
        let active = records.filter(\.isActive)
        XCTAssertEqual(list.activeCount, active.count, "active count after \(step)", file: file, line: line)
        XCTAssertEqual(list.hasDangerous, records.contains(where: \.isDangerous), "danger after \(step)", file: file, line: line)
        XCTAssertEqual(list.summary.finished, records.count - active.count, "finished after \(step)", file: file, line: line)
        XCTAssertEqual(list.summary.onDisk, records.filter(\.hasFileOnDisk).count, "on disk after \(step)", file: file, line: line)
        let known = active.filter { $0.totalBytes > 0 }
        let fraction: Double? = known.isEmpty ? nil : Double(known.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) })
            / Double(max(known.reduce(Int64(0)) { $0 + $1.totalBytes }, 1))
        XCTAssertEqual(list.activeFraction, fraction, "fraction after \(step)", file: file, line: line)
        for limit in [0, 1, 4, 7, 16, 17, 40] {
            XCTAssertEqual(list.latest(limit).map(\.id), RecentDownloads.latest(records, limit: limit).map(\.id),
                           "latest(\(limit)) after \(step)", file: file, line: line)
        }
    }

    func testKeptIndexesMatchAPassOverEveryRow() {
        var random = Generator(state: 42)
        var list = DownloadList(records: (0 ..< 30).map {
            DownloadRecord(id: "p\($0)", source: .chromium, url: "https://example.com/p\($0)", targetPath: $0 % 5 == 0 ? "" : "/tmp/p\($0)",
                           totalBytes: 10, state: [.complete, .complete, .inProgress, .cancelled][$0 % 4],
                           startedAt: base, updatedAt: base.addingTimeInterval(Double($0 % 7)))
        })
        assertIndexesMatch(list, "init")
        var next = 0
        var now = base.addingTimeInterval(100)
        for step in 0 ..< 3_000 {
            // Ticks of 0 or 1 s: many rows share an update time, so ties go by list order.
            now = now.addingTimeInterval(Double(Int.random(in: 0 ... 1, using: &random)))
            let ids = list.records.map(\.id)
            let pick = ids.randomElement(using: &random)
            let name: String
            switch Int.random(in: 0 ..< 100, using: &random) {
            case 0 ..< 25:
                next += 1
                list.apply(DownloadEvent(kind: .created, guid: "n\(next)", url: "https://example.com/n\(next)",
                                         totalBytes: [0, 100][next % 2], dangerType: [0, 0, 1, 4][next % 4]),
                           source: .chromium, now: now)
                name = "new download"
            case 25 ..< 45:
                next += 1
                let ended = base.addingTimeInterval(Double(Int.random(in: 0 ... 40, using: &random)))
                list.apply(DownloadEvent(kind: .created, guid: "h\(next)", url: "https://example.com/h\(next)",
                                         targetPath: next % 6 == 0 ? "" : "/tmp/h\(next)", totalBytes: 5, state: .complete,
                                         startedAt: ended, endedAt: ended),
                           source: .chromium, now: now)
                name = "history row"
            case 45 ..< 65:
                guard let id = pick else { continue }
                list.apply(DownloadEvent(kind: .updated, guid: id, url: "", targetPath: "/tmp/\(id)",
                                         receivedBytes: Int64.random(in: 0 ... 150, using: &random), totalBytes: 100,
                                         dangerType: [0, 1, 4][Int.random(in: 0 ... 2, using: &random)], isPaused: Bool.random(using: &random)),
                           source: .chromium, now: now)
                name = "progress"
            case 65 ..< 78:
                guard let id = pick else { continue }
                let kind: DownloadEvent.Kind = [.completed, .interrupted, .cancelled][Int.random(in: 0 ... 2, using: &random)]
                let state: DownloadState = kind == .completed ? .complete : kind == .interrupted ? .interrupted : .cancelled
                list.apply(DownloadEvent(kind: kind, guid: id, url: "", targetPath: Bool.random(using: &random) ? "/tmp/\(id)" : "",
                                         receivedBytes: 100, totalBytes: 100, state: state,
                                         endedAt: Bool.random(using: &random) ? now : nil),
                           source: .chromium, now: now)
                name = "finished"
            case 78 ..< 86:
                guard let id = pick else { continue }
                list.apply(DownloadEvent(kind: .removed, guid: id, url: ""), source: .chromium, now: now)
                name = "removed event"
            case 86 ..< 90:
                // The newest rows go: the quick view's index runs short and refills.
                for record in list.latest(Int.random(in: 1 ... 6, using: &random)) { list.remove(id: record.id) }
                name = "remove newest"
            case 90 ..< 93:
                let archived = (0 ..< Int.random(in: 1 ... 60, using: &random)).map { index -> DownloadRecord in
                    next += 1
                    let day = base.addingTimeInterval(Double(Int.random(in: -20 ... 5, using: &random)))
                    return DownloadRecord(id: index == 0 ? (pick ?? "a\(next)") : "a\(next)", source: .chromium,
                                          url: "https://example.com/a\(next)", targetPath: "/tmp/a\(next)",
                                          totalBytes: 3, state: .complete, startedAt: day, updatedAt: day)
                }
                list.appendArchived(archived)
                name = "archived"
            case 93 ..< 95:
                list.remove(ids: Set(ids.filter { _ in Int.random(in: 0 ..< 4, using: &random) == 0 }))
                name = "remove ids"
            case 95:
                _ = list.clearFinished()
                name = "clear"
            case 96 ..< 98:
                list.trim(to: Int.random(in: 0 ... 60, using: &random))
                name = "trim"
            default:
                list.markStaleTransfersInterrupted()
                name = "stale"
            }
            assertIndexesMatch(list, "step \(step) (\(name))")
        }
    }

    func testDecodedDuplicateIDsKeepTheirOwnPlaces() throws {
        let rows = [
            DownloadRecord(id: "dup", source: .chromium, url: "u", targetPath: "/tmp/a", state: .complete, startedAt: base),
            DownloadRecord(id: "x", source: .chromium, url: "u", targetPath: "/tmp/x", state: .complete, startedAt: base),
            DownloadRecord(id: "dup", source: .chromium, url: "u", targetPath: "/tmp/b", state: .complete, startedAt: base),
        ]
        var list = DownloadList(records: rows)
        assertIndexesMatch(list, "init")
        list.apply(DownloadEvent(kind: .completed, guid: "dup", url: "", targetPath: "/tmp/c", state: .complete, endedAt: base.addingTimeInterval(9)),
                   source: .chromium, now: base)
        assertIndexesMatch(list, "update of the first copy")
        XCTAssertEqual(list.latest(2).map(\.targetPath), ["/tmp/c", "/tmp/x"])
        list.remove(id: "dup")
        assertIndexesMatch(list, "remove of the first copy")
        XCTAssertEqual(list.latest().map(\.targetPath), ["/tmp/x", "/tmp/b"])
    }

    func testABatchAppliesEachEventAtItsOwnTimeInOrder() {
        var one = DownloadList()
        var batch = DownloadList()
        let events: [(event: DownloadEvent, source: DownloadSource, now: Date)] = [
            (DownloadEvent(kind: .created, guid: "a", url: "https://example.com/a", totalBytes: 100), .chromium, base),
            (DownloadEvent(kind: .created, guid: "h", url: "https://example.com/h", targetPath: "/tmp/h", state: .complete), .chromium, base),
            (DownloadEvent(kind: .updated, guid: "a", url: "", receivedBytes: 50, totalBytes: 100), .chromium, base.addingTimeInterval(1)),
            (DownloadEvent(kind: .completed, guid: "a", url: "", targetPath: "/tmp/a", receivedBytes: 100, totalBytes: 100, state: .complete),
             .chromium, base.addingTimeInterval(2)),
            (DownloadEvent(kind: .removed, guid: "h", url: ""), .chromium, base.addingTimeInterval(3)),
        ]
        let singles = events.map { one.apply($0.event, source: $0.source, now: $0.now) }
        XCTAssertEqual(batch.apply(events), singles)
        XCTAssertEqual(batch, one)
        XCTAssertEqual(batch.records.first?.updatedAt, base.addingTimeInterval(2))
        assertIndexesMatch(batch, "batch")
    }

    // MARK: BudgetedQueue

    func testADrainStopsOnceItsBudgetIsSpentAndKeepsOrder() {
        var queue = BudgetedQueue<Int>()
        for item in 0 ..< 1_000 { queue.append(item) }
        // Each slice of 10 costs 1 ms on this clock.
        var clock: TimeInterval = 0
        var applied: [Int] = []
        let taken = queue.drain(budget: 0.004, stride: 10, now: { clock }) { slice in
            applied += slice
            clock += 0.001
        }
        XCTAssertEqual(taken, 40, "slices until 4 ms are spent")
        XCTAssertEqual(applied, Array(0 ..< 40))
        XCTAssertEqual(queue.count, 960)

        var turns = 1
        while !queue.isEmpty {
            queue.drain(budget: 0.004, stride: 10, now: { clock }) { slice in
                applied += slice
                clock += 0.001
            }
            turns += 1
        }
        XCTAssertEqual(applied, Array(0 ..< 1_000), "every item once, in order")
        XCTAssertEqual(turns, 25)
    }

    func testADrainTakesAtLeastOneSliceEvenOverBudget() {
        var queue = BudgetedQueue<Int>()
        for item in 0 ..< 5 { queue.append(item) }
        var clock: TimeInterval = 0
        var slices: [[Int]] = []
        queue.drain(budget: 0, stride: 2, now: { clock }) { slices.append(Array($0)); clock += 1 }
        XCTAssertEqual(slices, [[0, 1]])
        queue.append(5)
        XCTAssertEqual(queue.removeAll(), [2, 3, 4, 5])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.drain(budget: 1, now: { 0 }) { _ in XCTFail("nothing to apply") }, 0)
    }

    func testADrainedQueueCompactsAndStaysCorrect() {
        var queue = BudgetedQueue<Int>()
        var next = 0, expected = 0
        for _ in 0 ..< 50 {
            for _ in 0 ..< 3_000 { queue.append(next); next += 1 }
            // One slice a drain: the queue keeps a growing tail while its consumed head is compacted.
            for _ in 0 ..< 5 { queue.drain(budget: 0, stride: 500, now: { 0 }, apply: check) }
        }
        XCTAssertEqual(queue.count, 50 * 500)
        queue.drain(budget: .infinity, stride: 500, now: { 0 }, apply: check)
        XCTAssertEqual(expected, next)

        func check(_ slice: ArraySlice<Int>) {
            for item in slice {
                XCTAssertEqual(item, expected)
                expected += 1
            }
        }
    }
}
