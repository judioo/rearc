@testable import Onboarding
import XCTest

final class Act3Tests: XCTestCase {
    func testSpacesComeFromTheImportOrAreSuggested() {
        let brought = Act2Log.demo(start: 0)
        let imported = Act3Log.after(brought, start: 30, colour: MarkPalette.sun)
        XCTAssertTrue(imported.imported)
        XCTAssertEqual(imported.seeds.map(\.name), ["Home", "Work", "Reading", "Travel", "Music", "Health", "Clients", "Ideas", "Archive"])

        var noSpaces = Act2Log.demo(start: 0)
        noSpaces.categories.append((1, .spaces))
        let suggested = Act3Log.after(noSpaces, start: 30, colour: MarkPalette.sun)
        XCTAssertFalse(suggested.imported)
        XCTAssertEqual(suggested.seeds.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(suggested.seeds[0].colour, MarkPalette.sun, "your first space wears your colour")

        XCTAssertFalse(Act3Log.after(nil, start: 0, colour: MarkPalette.sun).imported)
    }

    func testEditsAddsAndRemovals() {
        let seeds = Act3Log.after(Act2Log.demo(start: 0), start: 0, colour: MarkPalette.sun).seeds
        let log = Act3Log.demo(start: 0, seeds: seeds, imported: true)
        let done = log.doneTime!
        let (spaces, selected) = log.state(at: done)
        XCTAssertNil(selected)
        XCTAssertEqual(spaces.first { $0.id == 1 }?.colour, ProfilePalette.colours[6].rgba)
        XCTAssertEqual(spaces.first { $0.id == 1 }?.icon, "🎨")
        XCTAssertNotNil(spaces.first { $0.name == "Archive" }?.removed)
        XCTAssertEqual(spaces.last?.name, "Side project")
        XCTAssertEqual(spaces.last?.icon, "🎮")
        XCTAssertEqual(spaces.filter { $0.removed == nil }.count, seeds.count)
    }

    func testAddingSelectsTheNewSpace() {
        var log = Act3Log(start: 0, seeds: Act3Log.suggested(colour: MarkPalette.sun), imported: false)
        log.events = [(3, .add)]
        XCTAssertEqual(log.state(at: 3).selected, 2)
        XCTAssertEqual(log.state(at: 3).spaces.count, 3)
        XCTAssertEqual(Act3Timeline.frame(log, 4).editing?.id, 2)
    }

    func testSpacesStayOnTheBlueSideAndClearOfYou() {
        for n in 1 ... Act3Timeline.maxSpaces + 1 {
            for i in 0 ..< n {
                let a = Act3Timeline.angle(i, of: n)
                XCTAssertGreaterThanOrEqual(a, Act3Timeline.span.lowerBound)
                XCTAssertLessThanOrEqual(a, Act3Timeline.span.upperBound + 1e-9)
            }
        }
    }

    func testRemovalRelaysTheOthers() {
        var log = Act3Log(start: 0, seeds: Act3Log.suggested(colour: MarkPalette.sun) + [SpaceSeed(name: "Third", icon: "📚", colour: MarkPalette.blue)], imported: false)
        log.events = [(3, .remove(0))]
        let before = Act3Timeline.frame(log, 2.9).spaces[1].angle
        let after = Act3Timeline.frame(log, 5).spaces[1].angle
        XCTAssertEqual(after, Act3Timeline.angle(0, of: 3), accuracy: 1e-6, "Work moves up into the gap")
        XCTAssertLessThan(after, before)
    }

    func testDoneEndsEditingAndPlaysTheFinale() {
        var log = Act3Log(start: 0, seeds: Act3Log.suggested(colour: MarkPalette.sun), imported: false)
        log.events = [(3, .select(0)), (4, .done)]
        let f = Act3Timeline.frame(log, 6)
        XCTAssertEqual(f.finale, 1, accuracy: 1e-9)
        XCTAssertEqual(f.title, 0, accuracy: 1e-9)
        XCTAssertEqual(f.editor, 0, accuracy: 1e-9)
        XCTAssertEqual(log.handOff, 4 + Act3Timeline.finale)
    }
}
