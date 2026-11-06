import XCTest
@testable import ReArc

/// P3.11: haptics as a sidebar drag crosses drop positions and lands.
final class ReorderHapticsTests: XCTestCase {
    func testReorderHapticsTickOnEachNewPositionAndLandOnTheDrop() {
        var tracker = ReorderHapticsTracker()
        let a = UUID(), b = UUID()
        XCTAssertEqual(tracker.positionChanged(to: SidebarDropState(targetID: a, position: .before)), .alignment)
        XCTAssertNil(tracker.positionChanged(to: SidebarDropState(targetID: a, position: .before)), "the same slot again")
        XCTAssertNil(tracker.positionChanged(to: nil), "between rows")
        XCTAssertNil(tracker.positionChanged(to: SidebarDropState(targetID: a, position: .before)), "back to the same slot")
        XCTAssertEqual(tracker.positionChanged(to: SidebarDropState(targetID: a, position: .after)), .alignment)
        XCTAssertEqual(tracker.positionChanged(to: SidebarDropState(targetID: b, position: .into)), .alignment)
        XCTAssertEqual(tracker.enteredSectionEnd(), .alignment)
        XCTAssertEqual(tracker.positionChanged(to: SidebarDropState(targetID: b, position: .into)), .alignment, "left the row for the end zone")
        XCTAssertEqual(tracker.dropped(moved: true), .levelChange)
        XCTAssertEqual(tracker.positionChanged(to: SidebarDropState(targetID: b, position: .into)), .alignment, "a new drag starts fresh")
        XCTAssertNil(tracker.dropped(moved: false))
    }

    func testReorderHapticsAreOnUntilTurnedOff() throws {
        let suite = "rearc-haptics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ReorderHapticsPreference.isEnabled(defaults))
        defaults.set(false, forKey: ReorderHapticsPreference.key)
        XCTAssertFalse(ReorderHapticsPreference.isEnabled(defaults))
    }
}
