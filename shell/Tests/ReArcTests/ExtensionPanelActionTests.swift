import Foundation
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct ExtensionPanelActionTests {
    @Test func panelHighlightsOnlyItsWindowAndPinningPersistsWithoutClosing() throws {
        let name = "rearc-panel-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let extensions = ExtensionsController(defaults: defaults)
        let first = SidebarWindowID(), second = SidebarWindowID()
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID()))
        extensions.sidePanels.setShown(.init(extensionID: "a", title: "A", engine: engine, panelID: 1), in: first)
        #expect(extensions.isActionHighlighted("a", in: first))
        #expect(!extensions.isActionHighlighted("a", in: second))
        #expect(!extensions.isActionHighlighted("b", in: first))
        extensions.togglePin("a")
        #expect(ExtensionPins.load(from: defaults).pinnedIDs == ["a"])
        #expect(extensions.sidePanels.isOpen("a", in: first))
        extensions.togglePin("a")
        #expect(ExtensionPins.load(from: defaults).pinnedIDs.isEmpty)
        #expect(extensions.sidePanels.isOpen("a", in: first))
        extensions.sidePanels.setShown(nil, in: first)
        #expect(!extensions.isActionHighlighted("a", in: first))
        extensions.openPopupExtensionID = "b"
        #expect(extensions.isActionHighlighted("b", in: first))
    }
}
