import CoreGraphics
@testable import Onboarding
import XCTest

final class Act4Tests: XCTestCase {
    func run() -> (Act1Log, Act2Log, Act3Log, Act4Log) {
        let act1 = Act1Log.demo(start: 12)
        let act2 = Act2Log.demo(start: act1.handOff!)
        let base = Act3Log.after(act2, start: act2.handOff!, colour: ProfilePalette.colours[5].rgba)
        let act3 = Act3Log.demo(start: base.start, seeds: base.seeds, imported: base.imported)
        return (act1, act2, act3, Act4Log.after(act1: act1, act2: act2, act3: act3, start: act3.handOff!))
    }

    func testItCarriesYouAndYourSpaces() {
        let (_, act2, act3, act4) = run()
        XCTAssertEqual(act4.name, "Kai")
        XCTAssertEqual(act4.colour, ProfilePalette.colours[5].rgba)
        let kept = act3.state(at: act4.start).spaces.filter { $0.removed == nil }
        XCTAssertEqual(act4.nodes.map(\.icon), kept.map(\.icon))
        XCTAssertEqual(act4.theme, kept[0].colour, "the window wears the first space's colour")
        XCTAssertEqual(act4.totals, act2.totals(at: act2.choice!.time))
    }

    func testAFreshStartBringsNoTotals() {
        var act2 = Act2Log(start: 0, sources: ImportSource.demo)
        act2.choice = (4, false)
        XCTAssertNil(Act4Log.after(act1: nil, act2: act2, act3: nil, start: 20).totals)
    }

    func testTheMottoThenTheWindow() {
        let (_, _, _, log) = run()
        let s = log.start
        let motto = Act4Timeline.frame(log, s + 2.6)
        XCTAssertEqual(motto.words, [1, 1, 1])
        XCTAssertEqual(motto.window, 0)
        let end = Act4Timeline.frame(log, log.handOff)
        XCTAssertEqual(end.window, 1, accuracy: 1e-9)
        XCTAssertEqual(end.page, 1, accuracy: 1e-9)
        XCTAssertEqual(end.markFly, 1, accuracy: 1e-9)
        XCTAssertTrue(end.fly.allSatisfy { abs($0 - 1) < 1e-9 })
        XCTAssertEqual(end.mottoOut, 1, accuracy: 1e-9)
    }

    func testTheSwitcherFitsTheSidebar() {
        let A = Act4Layout(size: CGSize(width: 1440, height: 900))
        let n = Act3Timeline.maxSpaces
        let last = A.switcher(n - 1, of: n)
        XCTAssertLessThan(last.x + A.switcherRadius(n), A.window.minX + A.sidebarWidth)
        XCTAssertGreaterThan(A.avatar.x - A.switcherRadius(n), A.window.minX)
        XCTAssertTrue(A.window.contains(A.card))
    }
}
