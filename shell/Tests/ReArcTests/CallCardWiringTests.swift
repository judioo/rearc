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

    /// P3.28: the card's end button. The page's own hang-up when its PiP video
    /// offers one; else ⌘W's close, which ends the page and its streams.
    func testTheEndButtonHangsUpWhenThePageCanElseClosesTheTab() {
        typealias End = BrowserViewModel.CallEndAction
        XCTAssertEqual(End.resolve(canHangUp: true, kind: .pinned, inSplit: false), .hangUp)
        XCTAssertEqual(End.resolve(canHangUp: false, kind: .today, inSplit: false), .closeTab)
        XCTAssertEqual(End.resolve(canHangUp: false, kind: .pinned, inSplit: false), .unloadTab, "a pinned tab keeps its row")
        XCTAssertEqual(End.resolve(canHangUp: false, kind: .pinned, inSplit: true), .closeTab, "⌘W closes a pinned tab in a split")
        XCTAssertEqual(End.resolve(canHangUp: false, kind: .favorite, inSplit: false), .unloadTab)
        XCTAssertNil(End.resolve(canHangUp: false, kind: nil, inSplit: false), "no tab, no button")
        XCTAssertEqual(End.hangUp.title, "Leave Call")
        XCTAssertEqual(End.closeTab.title, "End Call (Close Tab)")
    }

    func testEndingACallInATodayTabClosesItToTheArchive() {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let meet = store.addTab(kind: .today, title: "Meet", url: URL(string: "https://meet.test")!)
        let other = store.addTab(kind: .today, title: "Other", url: URL(string: "https://other.test")!)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file))
        model.captureStateByTab[meet.id] = MediaCaptureState(isCapturingAudio: true)
        store.selectTab(other.id)

        XCTAssertEqual(model.callEndAction(for: meet.id), .closeTab, "no PiP video, so no hang-up")
        model.endCall(meet.id)
        XCTAssertNil(store.tab(withID: meet.id))
        XCTAssertNil(model.captureStateByTab[meet.id], "the call's state goes with the page")
        XCTAssertEqual(model.callCards(in: nil), [])
    }
}
