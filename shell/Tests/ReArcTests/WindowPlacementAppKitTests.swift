import AppKit
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct WindowPlacementAppKitTests {
    private final class ArchivedFrameWindow: NSWindow {
        var restoredFrame = CGRect(x: 52, y: 165, width: 900, height: 700)
        override func restoreState(with coder: NSCoder) { setFrame(restoredFrame, display: false) }
    }

    @Test func archivedFrameIsOverriddenByResolvedPlacementWithoutOrderingWindow() throws {
        _ = NSApplication.shared
        let window = ArchivedFrameWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let display = DisplayDescriptor(uuid: "built-in", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084))
        let frame = CGRect(x: 300, y: 100, width: 900, height: 700)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.finishEncoding()
        let saved = SavedBrowserWindow(frame: frame, display: SavedDisplay(uuid: display.uuid, frame: display.frame, visibleFrame: display.visibleFrame),
                                       isKey: false, appKitState: archive.encodedData)
        var traces: [String] = []
        window.applySavedPlacement(saved, displays: [display]) { traces.append($0) }
        #expect(window.frame == frame)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(traces.contains { $0.contains("afterRestoreState=") && $0.contains("52.0") })
        #expect(traces.last?.contains("finalPlacement=") == true)
    }
}
