import Foundation
import Observation
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Downloads at scale (docs/DOWNLOADS-AT-SCALE.md): the controller applies a
/// burst of engine events a turn's budget at a time, in order, and keeps the
/// bottom bar's values from the list's indexes so a replayed history that
/// changes none of them never redraws the bar.
final class DownloadsBudgetTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ guid: String, ended: TimeInterval = 0) -> DownloadEvent {
        DownloadEvent(kind: .created, guid: guid, url: "https://files.test/\(guid)", targetPath: "/tmp/\(guid)", receivedBytes: 1,
                      totalBytes: 1, state: .complete, startedAt: base.addingTimeInterval(ended), endedAt: base.addingTimeInterval(ended))
    }

    /// Each read of this clock is a millisecond later.
    private final class Clock {
        var now: TimeInterval = 0
        func read() -> TimeInterval {
            now += 0.001
            return now
        }
    }

    private func runTurns(until done: () -> Bool, limit: Int = 200) -> Int {
        var turns = 0
        while !done(), turns < limit {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            turns += 1
        }
        return turns
    }

    func testABurstPastTheBudgetWaitsForLaterTurnsInOrder() {
        let clock = Clock()
        let controller = DownloadsController(fileURL: nil, turnBudget: 0.004, clock: clock.read)
        for index in 0 ..< 3_000 { controller.apply(history("h\(index)", ended: -Double(index)), source: .chromium) }
        XCTAssertTrue(controller.hasPendingWork, "the turn spent its budget")
        let appliedAtOnce = controller.records.count
        XCTAssertGreaterThan(appliedAtOnce, 0)
        XCTAssertLessThan(appliedAtOnce, 10, "about the budget's worth applies in the delivering turn")

        _ = runTurns { !controller.hasPendingWork }
        XCTAssertFalse(controller.hasPendingWork)
        XCTAssertEqual(controller.records.map(\.id), (0 ..< 3_000).map { "h\($0)" }, "every event once, in arrival order")
        XCTAssertEqual(controller.recent.map(\.id), ["h0", "h1", "h2", "h3"])
    }

    func testWithoutABudgetEveryEventAppliesAtOnce() {
        let controller = DownloadsController(fileURL: nil)
        for index in 0 ..< 500 { controller.apply(history("h\(index)"), source: .chromium) }
        XCTAssertFalse(controller.hasPendingWork)
        XCTAssertEqual(controller.records.count, 500)
    }

    func testAnActionSeesRowsStillWaiting() {
        let clock = Clock()
        let controller = DownloadsController(fileURL: nil, turnBudget: 0.004, clock: clock.read)
        for index in 0 ..< 100 { controller.apply(history("h\(index)"), source: .chromium) }
        XCTAssertNil(controller.list.record(withID: "h99"))
        controller.perform(.remove, on: "h99")
        XCTAssertFalse(controller.hasPendingWork, "an action applies what waits first")
        XCTAssertNil(controller.list.record(withID: "h99"), "and then finds the row")
        XCTAssertEqual(controller.records.count, 99)
    }

    func testArchivedRowsFollowLiveRowsStillWaiting() {
        let clock = Clock()
        let controller = DownloadsController(fileURL: nil, turnBudget: 0.004, clock: clock.read)
        for index in 0 ..< 50 { controller.apply(history("live\(index)"), source: .chromium) }
        let archived = (0 ..< 5_000).map {
            DownloadRecord(id: "a\($0)", source: .chromium, url: "https://files.test/a\($0)", targetPath: "/tmp/a\($0)",
                           state: .complete, startedAt: base.addingTimeInterval(-1_000), updatedAt: base.addingTimeInterval(-1_000))
        }
        controller.appendArchived(archived)
        XCTAssertTrue(controller.hasPendingWork)
        _ = runTurns { !controller.hasPendingWork }
        XCTAssertEqual(controller.records.map(\.id), (0 ..< 50).map { "live\($0)" } + archived.map(\.id))
    }

    func testOlderHistoryLeavesTheBarAlone() {
        let controller = DownloadsController(fileURL: nil)
        controller.apply(DownloadEvent(kind: .created, guid: "new", url: "https://files.test/new", totalBytes: 10), source: .chromium, now: base)
        controller.apply(DownloadEvent(kind: .completed, guid: "new", url: "", targetPath: "/tmp/new", receivedBytes: 10, totalBytes: 10,
                                       state: .complete), source: .chromium, now: base.addingTimeInterval(100))
        for index in 0 ..< 4 { controller.apply(history("h\(index)", ended: 50), source: .chromium) }
        XCTAssertEqual(controller.recent.map(\.id), ["new", "h0", "h1", "h2"])

        var changed = false
        withObservationTracking {
            _ = controller.recent
            _ = controller.activeCount
            _ = controller.activeFraction
            _ = controller.hasDangerous
            _ = controller.hasFinished
        } onChange: { changed = true }
        for index in 4 ..< 2_000 { controller.apply(history("h\(index)", ended: -Double(index)), source: .chromium) }
        XCTAssertFalse(changed, "rows older than the quick view's change nothing the bar reads")
        XCTAssertEqual(controller.records.count, 2_001)

        controller.apply(history("newest", ended: 200), source: .chromium)
        XCTAssertTrue(changed)
        XCTAssertEqual(controller.recent.first?.id, "newest")
    }

    func testTheBarsValuesMatchAPassOverEveryRow() {
        let controller = DownloadsController(fileURL: nil)
        func check(_ step: String) {
            let records = controller.records
            XCTAssertEqual(controller.activeCount, records.filter(\.isActive).count, step)
            XCTAssertEqual(controller.hasDangerous, records.contains(where: controller.needsDecision), step)
            XCTAssertEqual(controller.hasFinished, records.contains { !$0.isActive }, step)
            XCTAssertEqual(controller.recent, RecentDownloads.latest(records), step)
            XCTAssertEqual(controller.activeFraction, controller.list.activeFraction, step)
        }
        check("empty")
        controller.apply(DownloadEvent(kind: .created, guid: "risky", url: "u", totalBytes: 10, dangerType: 1), source: .chromium)
        check("a dangerous download")
        controller.updateWarning(DownloadWarning(dangerType: 1, insecureStatus: 0, isDangerous: false, isInsecure: false), for: "risky")
        check("Chromium says no decision")
        controller.apply(DownloadEvent(kind: .created, guid: "scan", url: "u", totalBytes: 10, dangerType: 4), source: .chromium)
        controller.updateWarning(DownloadWarning(dangerType: 4, insecureStatus: 3, isDangerous: false, isInsecure: true), for: "scan")
        check("an insecure warning on a checking row")
        controller.updateWarning(nil, for: "risky")
        check("warning withdrawn")
        controller.apply(DownloadEvent(kind: .completed, guid: "scan", url: "", targetPath: "/tmp/scan", receivedBytes: 10, totalBytes: 10,
                                       state: .complete), source: .chromium)
        check("finished")
        controller.apply(history("old"), source: .chromium)
        controller.clearFinished()
        check("cleared")
    }
}
