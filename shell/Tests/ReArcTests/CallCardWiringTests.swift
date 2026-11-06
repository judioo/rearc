import XCTest
import SidebarModel
@testable import ReArc

/// A tab in a call gets a call card instead of a media strip while another
/// tab is on screen, and no card while it is the tab in view.
@MainActor
final class CallCardWiringTests: XCTestCase {
    func testCallTabsGetACardOnlyWhenNotOnScreen() {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let meet = store.addTab(kind: .today, title: "Meet", url: URL(string: "https://meet.test")!)
        let other = store.addTab(kind: .today, title: "Other", url: URL(string: "https://other.test")!)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file))
        model.captureStateByTab[meet.id] = MediaCaptureState(isCapturingVideo: true, isCapturingAudio: true)

        store.selectTab(meet.id)
        XCTAssertEqual(model.callCards(in: nil), [], "the call is on screen")

        store.selectTab(other.id)
        XCTAssertEqual(model.callCards(in: nil), [meet.id])
        XCTAssertFalse(model.mediaStrips(in: nil).contains(meet.id), "the card replaces its strip")
    }
}
