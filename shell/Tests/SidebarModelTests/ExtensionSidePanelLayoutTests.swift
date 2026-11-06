import XCTest
@testable import SidebarModel

/// The extension side panel's side, width and per-window panel choice
/// (docs/arc-recordings/2026-11-06-side-panel.md).
final class ExtensionSidePanelLayoutTests: XCTestCase {
    func testThePanelSitsOppositeTheSidebar() {
        XCTAssertEqual(SidePanelPlacement.side(), .right, "Arc: sidebar left, panel right")
        XCTAssertEqual(SidePanelPlacement.side(sidebarSide: .left), .right)
        XCTAssertEqual(SidePanelPlacement.side(sidebarSide: .right), .left)
    }

    func testWidthStaysWithinBoundsAndLeavesThePage() {
        XCTAssertEqual(SidePanelWidth.clamped(100), SidePanelWidth.minimum)
        XCTAssertEqual(SidePanelWidth.clamped(5000), SidePanelWidth.maximum)
        XCTAssertEqual(SidePanelWidth.clamped(600, available: 900), 900 - SidePanelWidth.minimumPageWidth)
        XCTAssertEqual(SidePanelWidth.clamped(600, available: 500), SidePanelWidth.minimum,
                       "a narrow window still gets the minimum pane")
        XCTAssertEqual(SidePanelWidth.clamped(400, available: 1600), 400)
    }

    func testWidthPersists() throws {
        let suite = "ExtensionSidePanelLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SidePanelWidth.load(from: defaults), SidePanelWidth.standard)
        SidePanelWidth.save(450, to: defaults)
        XCTAssertEqual(SidePanelWidth.load(from: defaults), 450)
        SidePanelWidth.save(10, to: defaults)
        XCTAssertEqual(SidePanelWidth.load(from: defaults), SidePanelWidth.minimum)
    }

    func testAGlobalPanelStaysAcrossTabSwitches() {
        var state = SidePanelWindowState(extensionID: "claude", ownerTab: 1)
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: false), .create(contextual: false))
        state.adopt(panel: 10, contextual: false, owner: 1)
        state.shownPanel = 10
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .show(10), "same page beside the next tab")
        XCTAssertEqual(state.decision(for: 3, available: false, contextual: false), .close, "no panel for that tab")
    }

    func testAContextualPanelBelongsToItsTab() {
        var state = SidePanelWindowState(extensionID: "x", ownerTab: 1)
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: true), .create(contextual: true))
        state.adopt(panel: 11, contextual: true, owner: 1)
        state.adopt(panel: 10, contextual: false, owner: 2)
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: true), .show(11))
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .show(10))
        XCTAssertEqual(state.panels, [10, 11])
        XCTAssertEqual(state.forget(ownerTab: 1), 11, "the tab's panel goes with it")
        XCTAssertEqual(state.panels, [10])
    }

    func testForgettingTheShownPanel() {
        var state = SidePanelWindowState(extensionID: "x", ownerTab: 1)
        state.adopt(panel: 10, contextual: false, owner: 1)
        state.adopt(panel: 11, contextual: true, owner: 2)
        state.shownPanel = 11
        XCTAssertFalse(state.forget(panel: 10))
        XCTAssertNil(state.globalPanel)
        XCTAssertTrue(state.forget(panel: 11))
        XCTAssertNil(state.shownPanel)
        XCTAssertTrue(state.panels.isEmpty)
    }

    func testToolbarClicksToggleAndReplace() {
        XCTAssertEqual(SidePanelToggle.resolve(shownExtension: nil, clicked: "claude"), .open)
        XCTAssertEqual(SidePanelToggle.resolve(shownExtension: "claude", clicked: "claude"), .close)
        XCTAssertEqual(SidePanelToggle.resolve(shownExtension: "claude", clicked: "chatgpt"), .replace,
                       "the recording: ChatGPT's button swaps the open Claude panel")
    }
}
