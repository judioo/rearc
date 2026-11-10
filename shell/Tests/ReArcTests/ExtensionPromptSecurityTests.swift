import AppKit
import XCTest
import SidebarModel
@testable import ReArc

final class ExtensionAlertSecurityTests: XCTestCase {
    func testAcceptanceStartsDisabledAndSensitivePromptsDefaultToCancel() {
        for kind: ExtensionPromptKind in [.install, .permissions, .reEnable] {
            let request = ExtensionPromptRequest(id: 1, kind: kind, extensionID: "x", name: "X")
            let alert = AlertExtensionPromptPresenter.makeAlert(request)
            alert.layout()
            XCTAssertFalse(alert.buttons[0].isEnabled)
            if kind == .permissions || kind == .reEnable {
                XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
                XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
                XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell)
            }
        }
    }
}
