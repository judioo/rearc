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
        var state = SidePanelWindowState(extensionID: "chatgpt", ownerTab: 1)
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: false, explicit: true), .create(contextual: false))
        state.adopt(panel: 10, contextual: false, owner: 1)
        state.shownPanel = 10
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .show(10), "same page beside the next tab")
        XCTAssertEqual(state.decision(for: 3, available: false, contextual: false), .hide,
                       "a tab without the panel hides it; the global page stays loaded")
        state.shownPanel = nil
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .show(10), "and it is back on the next tab")
    }

    func testAContextualPanelFollowsItsTab() {
        // Claude: setOptions({tabId, path}) and open({tabId}) on a toolbar click; no global path.
        var state = SidePanelWindowState(extensionID: "claude", ownerTab: 1)
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: true), .close, "a tab switch opens nothing")
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: true, explicit: true), .create(contextual: true))
        state.adopt(panel: 11, contextual: true, owner: 1)
        state.shownPanel = 11
        XCTAssertEqual(state.decision(for: 2, available: false, contextual: false), .hide, "another tab: hidden, kept")
        state.shownPanel = nil
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: true), .show(11), "back with its tab, same page")
        XCTAssertEqual(state.decision(for: 3, available: true, contextual: true), .hide,
                       "a tab with its own options but no panel yet gets none unasked")
    }

    func testATabsOwnPanelBesideAGlobalOne() {
        var state = SidePanelWindowState(extensionID: "x", ownerTab: 1)
        state.adopt(panel: 10, contextual: false, owner: 1)
        state.shownPanel = 10
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: true), .create(contextual: true),
                       "Chrome shows the tab's entry for the shown extension")
        state.adopt(panel: 11, contextual: true, owner: 2)
        state.shownPanel = 11
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: false), .show(10))
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: true), .show(11))
        XCTAssertEqual(state.panels, [10, 11])
        XCTAssertEqual(state.forget(ownerTab: 2), 11, "the tab's panel goes with it")
        XCTAssertNil(state.shownPanel, "and off screen")
        XCTAssertEqual(state.panels, [10])
    }

    func testANewGlobalPanelOnlyWhileOneIsShown() {
        var state = SidePanelWindowState(extensionID: "x", ownerTab: 1)
        state.adopt(panel: 11, contextual: true, owner: 1)
        state.shownPanel = 11
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .create(contextual: false),
                       "the shown extension's global panel beside a tab without its own")
        state.shownPanel = nil
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: false), .hide, "not while hidden")
    }

    func testClosingTheShownPanelKeepsOtherTabsPanels() {
        var state = SidePanelWindowState(extensionID: "x", ownerTab: 1)
        state.adopt(panel: 10, contextual: false, owner: 1)
        state.adopt(panel: 11, contextual: true, owner: 1)
        state.adopt(panel: 12, contextual: true, owner: 2)
        state.shownPanel = 11
        XCTAssertEqual(state.closeShown(), [10, 11], "the shown panel and the window's global one")
        XCTAssertNil(state.shownPanel)
        XCTAssertEqual(state.panels, [12])
        XCTAssertEqual(state.decision(for: 2, available: true, contextual: true), .show(12), "tab 2 keeps its own")
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: false), .hide)
        XCTAssertEqual(state.forget(ownerTab: 2), 12)
        XCTAssertEqual(state.closeShown(), [])
        XCTAssertEqual(state.decision(for: 1, available: true, contextual: false), .close, "nothing kept: the pane closes")
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
