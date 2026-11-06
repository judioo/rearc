import XCTest
@testable import SidebarModel

/// Wave 37: the sidebar's two-finger space swipe (direction, axis threshold,
/// ends) and the bottom bar's hover chips
/// (docs/arc-recordings/2026-11-06-space-swipe-and-dot-labels.md).
final class Wave37SpaceSwipeTests: XCTestCase {

    // MARK: Direction

    func testThePageFollowsTheFingersWhateverTheScrollSetting() {
        // Fingers move left: natural scrolling reports −dx, classic scrolling +dx.
        XCTAssertEqual(SwipeAxisLock.contentDelta(-12, invertedFromDevice: true), -12)
        XCTAssertEqual(SwipeAxisLock.contentDelta(12, invertedFromDevice: false), -12)
        XCTAssertEqual(SwipeAxisLock.contentDelta(5, invertedFromDevice: true), 5)
    }

    func testFingersMovingLeftShowTheNextSpace() {
        let width = 228.0
        var paging = SpacePaging(pageCount: 3, page: 0)
        paging.beginTracking(at: 0)
        let travel = SwipeAxisLock.contentDelta(-0.7 * width, invertedFromDevice: true)
        // SpacePagerController.swipe(byPoints:): content travel → pages.
        paging.track(by: -travel / width, at: 1)
        XCTAssertEqual(paging.position(at: 1), 0.7, accuracy: 1e-9)
        XCTAssertEqual(paging.endTracking(at: 1), 1)
    }

    // MARK: Threshold

    func testSmallTravelStaysUndecidedSoTheListKeepsIt() {
        var lock = SwipeAxisLock()
        XCTAssertEqual(lock.add(dx: 3, dy: 0), .undecided)
        XCTAssertEqual(lock.add(dx: 2.9, dy: 0), .undecided, "under 6 pt nothing is decided")
        XCTAssertEqual(lock.add(dx: 0.2, dy: 0), .horizontal)
    }

    func testHorizontalNeedsToClearlyBeatVertical() {
        var near = SwipeAxisLock()
        XCTAssertEqual(near.add(dx: 6, dy: 5), .vertical, "1.2 : 1 is a scroll, not a swipe")
        var clear = SwipeAxisLock()
        XCTAssertEqual(clear.add(dx: -7, dy: 4), .horizontal, "1.75 : 1 swipes")
        var up = SwipeAxisLock()
        XCTAssertEqual(up.add(dx: 0.5, dy: -9), .vertical)
        XCTAssertEqual(up.add(dx: 40, dy: 0), .vertical, "a vertical scroll stays one for the gesture")
    }

    func testReleaseCommitsPastHalfwayOrOnAFlick() {
        func release(after pages: Double, over seconds: Double) -> Int {
            var paging = SpacePaging(pageCount: 3, page: 1)
            paging.beginTracking(at: 0)
            for step in 1 ... 10 {
                paging.track(by: pages / 10, at: seconds * Double(step) / 10)
            }
            return paging.endTracking(at: seconds)
        }
        XCTAssertEqual(release(after: 0.4, over: 1), 1, "a slow 40 % drag springs back")
        XCTAssertEqual(release(after: 0.55, over: 1), 2, "a slow drag past halfway pages")
        XCTAssertEqual(release(after: 0.25, over: 0.06), 2, "a quick short flick pages")
        XCTAssertEqual(release(after: -0.25, over: 0.06), 0, "both ways")
    }

    // MARK: Ends

    func testEndsRubberBandAndNeverChangeSpace() {
        var first = SpacePaging(pageCount: 3, page: 0)
        first.beginTracking(at: 0)
        first.track(by: -0.5, at: 0.05)
        XCTAssertLessThan(first.position(at: 0.05), 0, "past the first space the page stretches")
        XCTAssertGreaterThan(first.position(at: 0.05), -0.35)
        XCTAssertEqual(first.endTracking(at: 0.05), 0, "a flick past the first space springs back")

        var last = SpacePaging(pageCount: 3, page: 2)
        last.beginTracking(at: 0)
        last.track(by: 0.9, at: 0.05)
        XCTAssertGreaterThan(last.position(at: 0.05), 2)
        XCTAssertEqual(last.endTracking(at: 0.05), 2)
        XCTAssertEqual(last.position(at: last.restTime!), 2, accuracy: 0.001)
    }

    // MARK: Chip text

    func testASpaceChipIsItsNameAndControlNumber() {
        XCTAssertEqual(BarChipLabel.space(named: "Work", at: 1).text, "Work ⌃2")
        XCTAssertEqual(BarChipLabel.space(named: "Home", at: 0).text, "Home ⌃1")
        XCTAssertEqual(BarChipLabel.space(named: "Nine", at: 8).shortcut, "⌃9")
        XCTAssertEqual(BarChipLabel.space(named: "Tenth", at: 9).text, "Tenth", "only nine spaces have a key")
        XCTAssertEqual(BarChipLabel.space(named: "  ", at: 2).text, "Space 3 ⌃3", "an unnamed space gets its number")
    }

    func testChipsFollowTheUsersShortcuts() {
        var overrides = ShortcutOverrides()
        overrides.set(ShortcutChord(.character("w"), [.control, .option]), for: "goToSpace2")
        overrides.unbind("viewLibrary")
        XCTAssertEqual(BarChipLabel.space(named: "Work", at: 1, overrides: overrides).text, "Work ⌃⌥W")
        XCTAssertEqual(BarChipLabel.library(overrides: overrides).text, "View Library")
        XCTAssertEqual(BarChipLabel.library().text, "View Library ⇧⌘L")
        XCTAssertEqual(BarChipLabel.exitLibrary.text, "Exit Library")
    }

    // MARK: Chip timing

    func testAChipShowsAfterAShortRestAndHidesOnLeaving() {
        var chip = HoverChipTiming<Int>(showDelay: 0.5, handOff: 0.3)
        chip.setHovering(true, 1, at: 10)
        XCTAssertNil(chip.shown)
        XCTAssertEqual(chip.deadline, 10.5)
        XCTAssertFalse(chip.advance(to: 10.4))
        XCTAssertTrue(chip.advance(to: 10.5))
        XCTAssertEqual(chip.shown, 1)
        chip.setHovering(false, 1, at: 11)
        XCTAssertNil(chip.shown)
        XCTAssertNil(chip.deadline)
    }

    func testPassingOverADotShowsNothing() {
        var chip = HoverChipTiming<Int>()
        chip.setHovering(true, 1, at: 0)
        chip.setHovering(false, 1, at: 0.2)
        XCTAssertFalse(chip.advance(to: 1))
        XCTAssertNil(chip.shown)
    }

    func testMovingAlongTheRowHandsTheChipOver() {
        var chip = HoverChipTiming<Int>(showDelay: 0.5, handOff: 0.3)
        chip.setHovering(true, 1, at: 0)
        chip.advance(to: 0.5)
        // Exit then enter, as AppKit usually orders them.
        chip.setHovering(false, 1, at: 1)
        chip.setHovering(true, 2, at: 1.05)
        XCTAssertEqual(chip.shown, 2, "the next dot labels itself at once")
        // Enter before exit: the stale exit must not hide the new chip.
        chip.setHovering(true, 3, at: 1.2)
        chip.setHovering(false, 2, at: 1.21)
        XCTAssertEqual(chip.shown, 3)
        // Off the row for a while: the next one waits again.
        chip.setHovering(false, 3, at: 2)
        chip.setHovering(true, 1, at: 2.5)
        XCTAssertNil(chip.shown)
        XCTAssertEqual(chip.deadline, 3)
    }

    func testAClickDismissesUntilTheNextRest() {
        var chip = HoverChipTiming<Int>()
        chip.setHovering(true, 1, at: 0)
        chip.advance(to: 1)
        chip.dismiss()
        XCTAssertNil(chip.shown)
        XCTAssertFalse(chip.advance(to: 5), "still on the button, it stays hidden")
        chip.setHovering(false, 1, at: 5)
        chip.setHovering(true, 2, at: 5.1)
        XCTAssertNil(chip.shown, "no hand-off after a dismissal")
    }

    // MARK: Chip placement

    func testAChipCentresOnItsDotButStaysOnTheSidebar() {
        XCTAssertEqual(BarChipPlacement.centredX(anchorMidX: 114, width: 60, containerWidth: 228), 84)
        XCTAssertEqual(BarChipPlacement.centredX(anchorMidX: 30, width: 100, containerWidth: 228), 8, "kept off the left edge")
        XCTAssertEqual(BarChipPlacement.centredX(anchorMidX: 220, width: 100, containerWidth: 228), 120, "and the right")
        XCTAssertEqual(BarChipPlacement.centredX(anchorMidX: 114, width: 300, containerWidth: 228), 8, "too wide: the start shows")
    }
}
