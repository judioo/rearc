import XCTest
@testable import SidebarModel

/// The space dot row's layout and hit testing: a hovered dot widens and its
/// neighbours move aside, and the pointer and clicks follow the drawing
/// (QA-2026-11-07 open issue 7; ARC-RECORDING-2026-11-06.md §5.2).
final class SpaceDotLayoutTests: XCTestCase {
    private let plain = Space(name: "Plain")
    private let heart = Space(name: "Heart", iconName: "heart.fill")
    private let house = Space(name: "House", iconName: "house.fill")

    func testSlotWidths() {
        XCTAssertEqual(SpaceDotLayout(spaces: [plain, heart, house], current: heart.id, hovered: nil).widths, [9, 22, 9])
        XCTAssertEqual(SpaceDotLayout(spaces: [plain, heart, house], current: plain.id, hovered: nil).widths, [13, 9, 9])
        XCTAssertEqual(SpaceDotLayout(spaces: [plain, heart, house], current: heart.id, hovered: house.id).widths, [9, 13, 22])
    }

    func testAHoveredDotWithoutAnIconStillTakesAnIconsSlot() {
        let other = Space(name: "Other")
        XCTAssertEqual(SpaceDotLayout(spaces: [heart, other], current: heart.id, hovered: other.id).widths, [13, 22])
    }

    func testTheRowIsCentredOnItsMiddle() {
        let layout = SpaceDotLayout(widths: [9, 22, 9])
        XCTAssertEqual(layout.width, 40)
        XCTAssertEqual(layout.slot(0), -20 ..< -11)
        XCTAssertEqual(layout.slot(1), -11 ..< 11)
        XCTAssertEqual(layout.slot(2), 11 ..< 20)
    }

    func testEachPointHitsTheSlotItIsDrawnIn() throws {
        let layout = SpaceDotLayout(widths: [9, 13, 22, 9])
        XCTAssertNil(layout.index(at: -layout.width / 2 - 0.5))
        XCTAssertNil(layout.index(at: layout.width / 2))
        for x in stride(from: -layout.width / 2, to: layout.width / 2, by: 0.25) {
            let i = try XCTUnwrap(layout.index(at: x))
            XCTAssertTrue(layout.slot(i).contains(x), "x \(x) hit dot \(i) at \(layout.slot(i))")
        }
    }

    /// Issue 7: the hovered dot used to cover its neighbour's spot. Now the
    /// neighbours move aside, each by half the growth, and a click on a
    /// neighbour where it is drawn selects that neighbour.
    func testHoveringMovesTheNeighboursAside() {
        let a = Space(name: "A"), b = Space(name: "B", iconName: "star.fill"), c = Space(name: "C")
        let spaces = [a, b, c]
        let rest = SpaceDotLayout(spaces: spaces, current: a.id, hovered: nil)
        let hovered = SpaceDotLayout(spaces: spaces, current: a.id, hovered: b.id)
        XCTAssertLessThanOrEqual(hovered.slot(0).upperBound, rest.slot(0).upperBound)
        XCTAssertGreaterThan(hovered.slot(2).lowerBound, rest.slot(2).lowerBound)
        XCTAssertTrue(hovered.slot(1).contains(rest.slot(1).lowerBound))
        XCTAssertTrue(hovered.slot(1).contains(rest.slot(1).upperBound - 0.01))
        for i in spaces.indices {
            let mid = (hovered.slot(i).lowerBound + hovered.slot(i).upperBound) / 2
            XCTAssertEqual(hovered.index(at: mid), i)
        }
    }

    /// Moving along the row passes the icon from dot to dot, in order, and
    /// each handoff holds: the row reflows around the newly hovered dot with
    /// the pointer still on it. Every mix of icons and current space, both ways.
    func testHoverHandsOffFromDotToDotWithoutFlicker() {
        for count in 1 ... 6 {
            for mask in 0 ..< (1 << count) {
                let spaces = (0 ..< count).map { i in
                    Space(name: "S\(i)", iconName: mask & (1 << i) != 0 ? "star.fill" : Space.defaultIconName)
                }
                for current in spaces {
                    for step in [0.25, -0.25] {
                        sweep(spaces, current: current.id, step: step)
                    }
                }
            }
        }
    }

    private func sweep(_ spaces: [Space], current: Space.ID, step: Double) {
        let label = "icons \(spaces.map(\.hasIcon)), current \(spaces.firstIndex { $0.id == current }!)"
        var hovered: Space.ID?
        var visited: [Int] = []
        for x in stride(from: -60 * step / abs(step), through: 60 * step / abs(step), by: step) {
            let next = SpaceDotLayout.hovered(at: x, spaces: spaces, current: current, hovered: hovered)
            let settled = SpaceDotLayout.hovered(at: x, spaces: spaces, current: current, hovered: next)
            XCTAssertEqual(settled, next, "\(label): flickers at \(x)")
            hovered = next
            if let i = spaces.firstIndex(where: { $0.id == next }), visited.last != i { visited.append(i) }
        }
        let order = step > 0 ? Array(spaces.indices) : spaces.indices.reversed()
        XCTAssertEqual(visited, order, label)
        XCTAssertNil(hovered, "the pointer left the row")
    }

    /// A hovered row is never narrower than the resting one, so leaving off
    /// an end doesn't land back on the end dot as the row settles.
    func testLeavingOffAnEndStaysLeft() {
        for spaces in [[plain, heart, house], [heart, plain], [plain, Space(name: "Other")]] {
            for current in spaces {
                let rest = SpaceDotLayout(spaces: spaces, current: current.id, hovered: nil)
                for hovered in spaces {
                    let layout = SpaceDotLayout(spaces: spaces, current: current.id, hovered: hovered.id)
                    XCTAssertGreaterThanOrEqual(layout.width, rest.width)
                }
            }
        }
    }
}
