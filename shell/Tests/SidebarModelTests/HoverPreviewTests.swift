import XCTest
@testable import SidebarModel

final class HoverPreviewTests: XCTestCase {
    private typealias Timer = HoverPreviewTimer<Int>
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testTabsWaitLongerThanFolders() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        XCTAssertEqual(timer.nextDeadline, at(0.8))
        XCTAssertEqual(timer.tick(now: at(0.5)), .none)
        XCTAssertEqual(timer.tick(now: at(0.8)), .show(1))
        XCTAssertEqual(timer.shown, 1)

        var folder = Timer()
        folder.pointerEntered(2, kind: .folder, now: t0)
        XCTAssertEqual(folder.nextDeadline, at(0.5))
        XCTAssertEqual(folder.tick(now: at(0.5)), .show(2))
    }

    func testLeavingBeforeTheDelayOpensNothing() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        timer.pointerExited(1, now: at(0.3))
        XCTAssertNil(timer.nextDeadline)
        XCTAssertEqual(timer.tick(now: at(1)), .none)
        XCTAssertNil(timer.shown)
    }

    func testAnOpenPreviewSurvivesTheTripFromRowToPreview() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .folder, now: t0)
        XCTAssertEqual(timer.tick(now: at(0.5)), .show(1))
        timer.pointerExited(1, now: at(1))
        XCTAssertEqual(timer.nextDeadline, at(1 + Timer.closeGrace))
        timer.previewHovered(true, now: at(1.1))
        XCTAssertNil(timer.nextDeadline)
        XCTAssertEqual(timer.tick(now: at(2)), .none)
        timer.previewHovered(false, now: at(3))
        XCTAssertEqual(timer.tick(now: at(3 + Timer.closeGrace)), .hide)
        XCTAssertNil(timer.shown)
    }

    func testReturningToTheRowKeepsThePreviewOpen() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        timer.pointerExited(1, now: at(1))
        timer.pointerEntered(1, kind: .tab, now: at(1.1))
        XCTAssertNil(timer.nextDeadline)
        XCTAssertEqual(timer.shown, 1)
    }

    func testMovingOnFromAnOpenPreviewIsWarm() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        timer.pointerExited(1, now: at(1))
        timer.pointerEntered(2, kind: .tab, now: at(1.05))
        XCTAssertEqual(timer.tick(now: at(1.05 + Timer.warmDelay)), .show(2))
        XCTAssertEqual(timer.shown, 2)

        // Shortly after one closes, the next is still warm; later it is not.
        timer.pointerExited(2, now: at(2))
        XCTAssertEqual(timer.tick(now: at(2 + Timer.closeGrace)), .hide)
        timer.pointerEntered(3, kind: .tab, now: at(2.3))
        XCTAssertEqual(timer.nextDeadline, at(2.3 + Timer.warmDelay))
        timer.pointerExited(3, now: at(2.31))
        timer.pointerEntered(4, kind: .tab, now: at(5))
        XCTAssertEqual(timer.nextDeadline, at(5.8))
    }

    func testCancelClosesAtOnceAndDoesNotWarm() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        XCTAssertEqual(timer.cancel(), .hide)
        XCTAssertEqual(timer.cancel(), .none)
        timer.pointerEntered(2, kind: .tab, now: at(0.9))
        XCTAssertEqual(timer.nextDeadline?.timeIntervalSince(at(0.9)) ?? 0, 0.8, accuracy: 0.0001)
    }

    func testRowsThatCanNoLongerPreviewAreRefused() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        XCTAssertEqual(timer.tick(now: at(1), canShow: { _ in false }), .none)
        XCTAssertNil(timer.shown)
        XCTAssertNil(timer.nextDeadline)
    }

    // MARK: - Where the pointer really is

    /// Break check 2026-11-07 night, issue 9: a fast diagonal flick out of
    /// the sidebar crossed row 2 and the open card's window. Row 2's enter
    /// arrived and its exit never did, nor the card's. Before the polls the
    /// card moved to row 2 and stayed open with the pointer in the page.
    func testAFlickThatLosesItsExitsStillCloses() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        XCTAssertEqual(timer.tick(now: at(0.8)), .show(1))
        timer.pointerExited(1, now: at(2))
        timer.pointerEntered(2, kind: .tab, now: at(2.02))
        timer.previewHovered(true, now: at(2.04))
        // No exit from row 2 or the card. The poll before row 2's warm
        // deadline finds the pointer in the page.
        timer.pointerLocated(inRow: nil, inPreview: false, now: at(2.12))
        XCTAssertNil(timer.pending, "row 2's wait ends")
        XCTAssertEqual(timer.nextDeadline, at(2.12 + Timer.closeGrace))
        XCTAssertEqual(timer.tick(now: at(2.12)), .none)
        // Later polls don't push the close back.
        timer.pointerLocated(inRow: nil, inPreview: false, now: at(2.22))
        XCTAssertEqual(timer.nextDeadline, at(2.12 + Timer.closeGrace))
        XCTAssertEqual(timer.tick(now: at(2.12 + Timer.closeGrace)), .hide)
        XCTAssertNil(timer.shown)
        XCTAssertNil(timer.nextDeadline)
    }

    /// Without the polls, the same events leave the card open on row 2 with
    /// nothing pending: what the break check saw.
    func testTheSameFlickWithoutPollsLeavesTheCardOpen() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        timer.pointerExited(1, now: at(2))
        timer.pointerEntered(2, kind: .tab, now: at(2.02))
        timer.previewHovered(true, now: at(2.04))
        XCTAssertEqual(timer.tick(now: at(2.02 + Timer.warmDelay)), .show(2))
        XCTAssertNil(timer.nextDeadline)
    }

    func testAnOpenPreviewWithNoEventsAtAllClosesAfterTheGrace() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        // The row's exit is lost: only the polls say the pointer left.
        timer.pointerLocated(inRow: 1, inPreview: false, now: at(0.9))
        XCTAssertNil(timer.nextDeadline)
        timer.pointerLocated(inRow: nil, inPreview: false, now: at(1))
        XCTAssertEqual(timer.tick(now: at(1.1)), .none)
        timer.pointerLocated(inRow: nil, inPreview: false, now: at(1.2))
        XCTAssertEqual(timer.tick(now: at(1 + Timer.closeGrace)), .hide)
    }

    func testPollsOverTheRowOrThePreviewKeepItOpen() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .folder, now: t0)
        _ = timer.tick(now: at(0.5))
        timer.pointerExited(1, now: at(1))
        // Over the preview, though its enter went missing.
        timer.pointerLocated(inRow: nil, inPreview: true, now: at(1.1))
        XCTAssertNil(timer.nextDeadline)
        XCTAssertEqual(timer.tick(now: at(2)), .none)
        // Off it, then back on the row before the grace ends, with no enter.
        timer.pointerLocated(inRow: nil, inPreview: false, now: at(3))
        timer.pointerLocated(inRow: 1, inPreview: false, now: at(3.1))
        XCTAssertEqual(timer.tick(now: at(4)), .none)
        XCTAssertEqual(timer.shown, 1)
    }

    func testAPollOverThePendingRowLetsItOpen() {
        var timer = Timer()
        timer.pointerEntered(1, kind: .tab, now: t0)
        _ = timer.tick(now: at(0.8))
        timer.pointerExited(1, now: at(1))
        timer.pointerEntered(2, kind: .tab, now: at(1.02))
        timer.pointerLocated(inRow: 2, inPreview: false, now: at(1.1))
        XCTAssertEqual(timer.pending, 2)
        XCTAssertEqual(timer.tick(now: at(1.02 + Timer.warmDelay)), .show(2))
        timer.pointerLocated(inRow: 2, inPreview: false, now: at(1.2))
        XCTAssertNil(timer.nextDeadline)
    }

    func testAPollWithNothingOpenOrPendingDoesNothing() {
        var timer = Timer()
        timer.pointerLocated(inRow: nil, inPreview: false, now: t0)
        XCTAssertNil(timer.nextDeadline)
        XCTAssertEqual(timer.tick(now: at(1)), .none)
    }

    // MARK: - Snapshot cache

    private let page = URL(string: "https://a.test/one")!
    private let other = URL(string: "https://a.test/two")!

    func testCapturesOncePerPageUntilItAges() {
        var cache = TabSnapshotCache<String>(capacity: 4, maxAge: 60)
        let id = UUID()
        XCTAssertTrue(cache.shouldCapture(id, url: page, now: t0))
        cache.beginCapture(id)
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: t0), "one capture in flight at a time")
        cache.store("shot", for: id, url: page, now: t0)
        XCTAssertEqual(cache.image(for: id, url: page), "shot")
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: at(30)))
        XCTAssertTrue(cache.shouldCapture(id, url: page, now: at(60)))
        XCTAssertTrue(cache.shouldCapture(id, url: other, now: at(1)), "a new page captures again")
        XCTAssertNil(cache.image(for: id, url: other))
    }

    func testAFailedCaptureWaitsAndKeepsTheLastImage() {
        var cache = TabSnapshotCache<String>(capacity: 4, maxAge: 60)
        let id = UUID()
        cache.store("old", for: id, url: page, now: t0)
        cache.store(nil, for: id, url: page, now: at(70))
        XCTAssertEqual(cache.image(for: id, url: page), "old")
        XCTAssertFalse(cache.shouldCapture(id, url: page, now: at(100)))

        let fresh = UUID()
        cache.store(nil, for: fresh, url: page, now: t0)
        XCTAssertNil(cache.image(for: fresh, url: page))
        XCTAssertFalse(cache.shouldCapture(fresh, url: page, now: at(10)))
    }

    func testOldestEntriesGoPastCapacity() {
        var cache = TabSnapshotCache<String>(capacity: 2, maxAge: 60)
        let ids = [UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() { cache.store("\(index)", for: id, url: page, now: t0) }
        XCTAssertEqual(cache.entries.count, 2)
        XCTAssertNil(cache.image(for: ids[0], url: page))
        XCTAssertEqual(cache.image(for: ids[2], url: page), "2")
        cache.remove(ids[2])
        XCTAssertNil(cache.image(for: ids[2], url: page))
    }
}
