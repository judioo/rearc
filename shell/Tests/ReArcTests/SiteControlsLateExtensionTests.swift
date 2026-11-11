import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Answers at once with the extensions loaded so far, as the engine answers
/// a tab's action query.
private final class LoadingBackend: ExtensionToolbarBackend {
    weak var controller: ExtensionsController?
    var loaded: [ExtensionActionItem] = []
    var asked = 0
    func refreshActions(for engine: any WebEngine, scale: CGFloat) {
        asked += 1
        controller?.setActions(loaded, for: engine)
    }
    func runAction(_ extensionID: String, for engine: any WebEngine, anchor: NSView?) {}
    func selectedEngineChanged(_ engine: (any WebEngine)?) {}
}

/// Break check 2026-11-08 (426), issue 20: a tab open before an extension
/// loaded kept its empty list, so its site controls showed only +. The grid
/// asks for the tab's actions each time it opens. Hosted in a borderless
/// window far off screen, never ordered in.
@MainActor
final class SiteControlsLateExtensionTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAnExtensionLoadedAfterTheTabAskedShowsWhenSiteControlsOpen() throws {
        let model = Perf2PipelineTests.model()
        let controller = model.extensions
        controller.defaults = UserDefaults(suiteName: "rearc-late-extension-\(UUID())")!
        controller.isAvailable = true
        let backend = LoadingBackend()
        backend.controller = controller
        controller.backend = backend
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID()))

        // The restored tab asks while nothing has loaded yet.
        controller.refresh(engine, scale: 2)
        XCTAssertTrue(controller.actions(for: engine).isEmpty)
        // The extension loads; no event reaches this tab.
        backend.loaded = [ExtensionActionItem(id: "late", name: "Late")]

        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: SiteControlsExtensionGrid(model: model, engine: engine, manage: {}, run: { _ in }, add: {}))
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        XCTAssertEqual(backend.asked, 2, "opening the grid asks again")
        XCTAssertEqual(controller.actions(for: engine).map(\.id), ["late"])
    }
}
