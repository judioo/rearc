import XCTest
@testable import SidebarModel

final class AddressBarVisibilityTests: XCTestCase {
    func testDefaultIsFixedAndNeverSchedulesAHide() {
        var state = AddressBarVisibility()
        state.update(autoHideEnabled: false, pointer: .outside, hasKeyboardFocus: false, now: 0)
        state.hideIfDue(at: 100)
        XCTAssertTrue(state.isRevealed)
        XCTAssertNil(state.hideDeadline)
    }

    func testEdgeRevealsAndLeavingHidesAfterTheDelay() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        XCTAssertFalse(state.isRevealed)
        state.update(autoHideEnabled: true, pointer: .toolbar, hasKeyboardFocus: false, now: 0)
        XCTAssertFalse(state.isRevealed, "page hover below the edge must not reveal")
        state.update(autoHideEnabled: true, pointer: .topEdge, hasKeyboardFocus: false, now: 1)
        XCTAssertTrue(state.isRevealed)
        state.update(autoHideEnabled: true, pointer: .toolbar, hasKeyboardFocus: false, now: 2)
        XCTAssertNil(state.hideDeadline)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 3)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 3.1)
        XCTAssertEqual(state.hideDeadline, 3 + AddressBarVisibility.hideDelay, "movement cannot postpone hiding")
        state.hideIfDue(at: 3.2)
        XCTAssertTrue(state.isRevealed)
        state.hideIfDue(at: 3.4)
        XCTAssertFalse(state.isRevealed)
    }

    func testFocusRevealsCancelsPendingHideAndHoldsUntilBlur() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: true, now: 0)
        XCTAssertTrue(state.isRevealed, "⌘L reveals a hidden toolbar")
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 1)
        XCTAssertNotNil(state.hideDeadline)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: true, now: 1.1)
        state.hideIfDue(at: 10)
        XCTAssertTrue(state.isRevealed, "a stale timer cannot hide focused chrome")
        XCTAssertNil(state.hideDeadline)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 11)
        state.hideIfDue(at: 12)
        XCTAssertFalse(state.isRevealed)
    }

    func testReturningPointerCancelsHideAndDisablingRestoresFixed() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        state.update(autoHideEnabled: true, pointer: .topEdge, hasKeyboardFocus: false, now: 0)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 1)
        state.update(autoHideEnabled: true, pointer: .toolbar, hasKeyboardFocus: false, now: 1.1)
        state.hideIfDue(at: 2)
        XCTAssertTrue(state.isRevealed)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 3)
        state.hideIfDue(at: 4)
        state.update(autoHideEnabled: false, pointer: .outside, hasKeyboardFocus: false, now: 5)
        XCTAssertTrue(state.isRevealed)
        XCTAssertNil(state.hideDeadline)
    }

    func testSplitPanesHaveIndependentHoverAndFocus() {
        var left = AddressBarVisibility(autoHideEnabled: true)
        var right = left
        left.update(autoHideEnabled: true, pointer: .topEdge, hasKeyboardFocus: false, now: 0)
        XCTAssertTrue(left.isRevealed)
        XCTAssertFalse(right.isRevealed)
        left.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 1)
        right.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: true, now: 1)
        left.hideIfDue(at: 2)
        right.hideIfDue(at: 2)
        XCTAssertFalse(left.isRevealed)
        XCTAssertTrue(right.isRevealed)
    }

    func testRegionsForWindowFullscreenAndStackedPanes() {
        let upper = CGRect(x: 200, y: 400, width: 400, height: 390)
        let lower = CGRect(x: 200, y: 0, width: 400, height: 390)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 800), pane: upper, topEdge: 800), .topEdge)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 600, y: 800), pane: upper, topEdge: 800), .outside)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 390), pane: lower, topEdge: 390), .topEdge)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 780), pane: lower, topEdge: 390), .outside)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 370), pane: lower, topEdge: 390), .toolbar)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 300), pane: lower, topEdge: 390), .outside)
        let fullscreen = CGRect(x: 200, y: 0, width: 400, height: 900)
        XCTAssertEqual(AddressBarPointerRegion.position(CGPoint(x: 300, y: 900), pane: fullscreen, topEdge: 900), .topEdge)
    }

    func testPreferenceDefaultsAndPersists() {
        let suite = "AddressBarVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AutoHideAddressBarPreference.isEnabled(in: defaults))
        defaults.set(true, forKey: AutoHideAddressBarPreference.key)
        XCTAssertTrue(AutoHideAddressBarPreference.isEnabled(in: UserDefaults(suiteName: suite)!))
        defaults.set("invalid", forKey: AutoHideAddressBarPreference.key)
        XCTAssertFalse(AutoHideAddressBarPreference.isEnabled(in: defaults))
    }
}
