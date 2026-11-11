import AppKit
import XCTest
import SidebarModel
@testable import ReArc

final class ExtensionAlertSecurityTests: XCTestCase {
    func testAcceptanceStartsDisabledAndSensitivePromptsDefaultToCancel() {
        for kind: ExtensionPromptKind in [.install, .permissions, .reEnable, .uninstall] {
            let request = ExtensionPromptRequest(id: 1, kind: kind, extensionID: "x", name: "X")
            let alert = AlertExtensionPromptPresenter.makeAlert(request)
            alert.layout()
            XCTAssertFalse(alert.buttons[0].isEnabled)
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "\(kind)")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "\(kind)")
            XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell)
        }
    }

    /// F-10: a second request waits for the first sheet instead of queueing in AppKit armed.
    @MainActor
    func testOneSheetPerWindowAndWithdrawnRequestsLeaveTheQueue() {
        let presenter = AlertExtensionPromptPresenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let first = presenter.present(ExtensionPromptRequest(id: 1, kind: .install, extensionID: "a", name: "A"), in: window) { _ in }
        let second = presenter.present(ExtensionPromptRequest(id: 2, kind: .permissions, extensionID: "b", name: "B"), in: window) { _ in }
        XCTAssertNotNil(first)
        XCTAssertFalse(window.isVisible, "nothing on screen")
        XCTAssertEqual(presenter.queuedCount(for: window), 1)
        XCTAssertFalse(window.attachedSheet.map { $0 === (second as AnyObject) } ?? false)
        second?.close()
        XCTAssertEqual(presenter.queuedCount(for: window), 0)
        first?.close()
    }
}
