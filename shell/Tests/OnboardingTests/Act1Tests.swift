@testable import Onboarding
import XCTest

final class Act1Tests: XCTestCase {
    let log = Act1Log.demo(start: 12, name: "Kai", pick: 5)

    func testTheFieldShowsWhatWasTypedSoFar() {
        let first = log.edits[0].time
        XCTAssertEqual(Act1Timeline.frame(log, first - 0.01).text, "")
        XCTAssertEqual(Act1Timeline.frame(log, first + 0.01).text, "K")
        XCTAssertEqual(Act1Timeline.frame(log, log.submitted!.time).text, "Kai")
    }

    func testOneThingAtATime() {
        let submit = log.submitted!.time
        let asking = Act1Timeline.frame(log, submit - 0.2)
        XCTAssertEqual(asking.ask, 1, accuracy: 1e-9)
        XCTAssertEqual(asking.greet, 0)
        let greeting = Act1Timeline.frame(log, submit + 1.6)
        XCTAssertEqual(greeting.ask, 0)
        XCTAssertEqual(greeting.greet, 1, accuracy: 1e-9)
        XCTAssertEqual(greeting.prompt, 0)
        let choosing = Act1Timeline.frame(log, submit + 4)
        XCTAssertEqual(choosing.greet, 0)
        XCTAssertEqual(choosing.prompt, 1, accuracy: 1e-9)
    }

    func testTheSkyFollowsTheHoverAndKeepsThePick() {
        let firstHover = log.hovers[0]
        // Just before the scripted pointer moves on to the next swatch.
        let f = Act1Timeline.frame(log, log.hovers[1].time - 0.01)
        XCTAssertEqual(f.hovered, firstHover.index)
        XCTAssertGreaterThan(f.tintAmount, 0.8)
        XCTAssertEqual(f.tint, ProfilePalette.colours[firstHover.index!].rgba)
        XCTAssertEqual(f.hover[firstHover.index!], 1, accuracy: 1e-9)

        let end = Act1Timeline.frame(log, log.handOff!)
        XCTAssertEqual(end.picked, 5)
        XCTAssertNil(end.hovered)
        XCTAssertEqual(end.tint, ProfilePalette.colours[5].rgba)
        XCTAssertEqual(end.tintAmount, 1, accuracy: 1e-9)
        XCTAssertEqual(end.avatar, 1, accuracy: 1e-9)
        XCTAssertEqual(end.swatches.enumerated().filter { $0.element > 0 }.map(\.offset), [5], "only the pick stays")
    }

    func testLeavingTheSwatchesFadesTheTintWithoutGreying() {
        var log = Act1Log(start: 0)
        log.submitted = (1, "Kai")
        log.hovers = [(5, 2), (6, nil)]
        let f = Act1Timeline.frame(log, 6.3)
        XCTAssertEqual(f.tint, ProfilePalette.colours[2].rgba)
        XCTAssertLessThan(f.tintAmount, 1)
        XCTAssertEqual(Act1Timeline.frame(log, 8).tintAmount, 0, accuracy: 1e-9)
    }

    func testTheMarkLiftsAndAct0Clears() {
        let f = Act1Timeline.frame(log, log.start + 2)
        XCTAssertEqual(f.lift, 1, accuracy: 1e-9)
        XCTAssertEqual(f.clearAct0, 1, accuracy: 1e-9)
    }
}
