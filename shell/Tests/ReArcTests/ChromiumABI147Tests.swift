import XCTest
import SidebarModel
@testable import ReArc

/// ABI 1.47: extension side panels (chrome.sidePanel beside the page).
final class ChromiumABI147Tests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    func testSidePanelsNeedABI47TheirFeatureAndToolbarActions() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: all).extensionSidePanels)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: all).extensionSidePanels)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: { $0 != "extension_side_panels" }).extensionSidePanels)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: { $0 != "extension_actions" }).extensionSidePanels,
                       "the toolbar click that opens a panel is an extension action")
        XCTAssertFalse(ChromiumCapabilities.none.extensionSidePanels)
    }

    func testSummaryListsTheFlag() {
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: all).summary.contains("extension_side_panels=1"))
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: all).summary.contains("extension_side_panels=0"))
    }

    func testControllerKeepsOnePanelPerWindowAndPersistsTheWidth() throws {
        let suite = "ChromiumABI147Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ExtensionSidePanelController(defaults: defaults)
        XCTAssertEqual(controller.width, SidePanelWidth.standard)
        let first = SidebarWindowID(), second = SidebarWindowID()
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID()))
        controller.setShown(.init(extensionID: "claude", title: "Claude", iconPNG: nil, engine: engine, panelID: 7), in: first)
        XCTAssertTrue(controller.isOpen("claude", in: first))
        XCTAssertFalse(controller.isOpen("claude", in: second), "a panel belongs to its window")
        XCTAssertNil(controller.panel(in: nil))
        controller.commitWidth(500, available: 1400)
        XCTAssertEqual(ExtensionSidePanelController(defaults: defaults).width, 500, "the width is saved")
        controller.commitWidth(900, available: 1000)
        XCTAssertEqual(controller.width, 1000 - SidePanelWidth.minimumPageWidth, "the page keeps its minimum")
    }

    func testCloseGoesToTheBackend() {
        final class Backend: ExtensionSidePanelBackend {
            var closed: [SidebarWindowID] = []
            func closeSidePanel(in window: SidebarWindowID) { closed.append(window) }
        }
        let backend = Backend()
        let controller = ExtensionSidePanelController(defaults: UserDefaults(suiteName: "ChromiumABI147Tests.close")!)
        controller.backend = backend
        let window = SidebarWindowID()
        controller.close(in: window)
        XCTAssertEqual(backend.closed, [window])
    }
}
