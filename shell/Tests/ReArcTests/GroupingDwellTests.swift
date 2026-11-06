import XCTest
@testable import ReArc

/// A tab dropped on a tab stacks them only after the pointer rests there,
/// so a click that became a short drag cannot stack a new tab by accident.
@MainActor
final class GroupingDwellTests: XCTestCase {
    func testGroupingWaitsForTheDwellOnOneTarget() {
        let a = UUID(), b = UUID()
        _ = SidebarGroupingDwell.isReady(over: nil)
        XCTAssertFalse(SidebarGroupingDwell.isReady(over: a, now: 10))
        XCTAssertFalse(SidebarGroupingDwell.isReady(over: a, now: 10.3))
        XCTAssertTrue(SidebarGroupingDwell.isReady(over: a, now: 10.5))
        // Moving to another row starts the wait again.
        XCTAssertFalse(SidebarGroupingDwell.isReady(over: b, now: 10.6))
        XCTAssertTrue(SidebarGroupingDwell.isReady(over: b, now: 11.2))
        // Leaving the middle of the row resets it.
        _ = SidebarGroupingDwell.isReady(over: nil)
        XCTAssertFalse(SidebarGroupingDwell.isReady(over: b, now: 11.3))
    }
}
