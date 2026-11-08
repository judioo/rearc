import XCTest
@testable import SidebarModel

final class PageCardLayoutTests: XCTestCase {
    func testNativeFullscreenRemovesCardForEverySidebarAndToolbarPlacement() {
        let layout = PageCardLayout(isNativeFullscreen: true, isPageFullscreen: false)
        XCTAssertEqual(layout.inset, 0)
        XCTAssertEqual(layout.radius, 0)
        XCTAssertFalse(layout.showsDecoration)
        XCTAssertEqual(layout.splitGap, 10, "native fullscreen preserves the gaps between panes")
        for toolbar in [false, true] {
            for sidebar in [false, true] {
                XCTAssertEqual(layout.topInset(showsToolbar: toolbar, trafficLightsInSidebar: sidebar,
                                               trafficLightClearance: 40), 0)
            }
        }
    }

    func testLeavingFullscreenRestoresWindowedCardIncludingTrafficLightClearance() {
        let layout = PageCardLayout(isNativeFullscreen: false, isPageFullscreen: false)
        XCTAssertEqual(layout.inset, 10)
        XCTAssertEqual(layout.radius, 8)
        XCTAssertTrue(layout.showsDecoration)
        XCTAssertEqual(layout.splitGap, 10)
        XCTAssertEqual(layout.topInset(showsToolbar: true, trafficLightsInSidebar: false, trafficLightClearance: 40), 10)
        XCTAssertEqual(layout.topInset(showsToolbar: false, trafficLightsInSidebar: true, trafficLightClearance: 40), 10)
        XCTAssertEqual(layout.topInset(showsToolbar: false, trafficLightsInSidebar: false, trafficLightClearance: 40), 40)
    }

    func testHTMLFullscreenStillRemovesCard() {
        for native in [false, true] {
            let layout = PageCardLayout(isNativeFullscreen: native, isPageFullscreen: true)
            XCTAssertEqual(layout.inset, 0)
            XCTAssertEqual(layout.radius, 0)
            XCTAssertFalse(layout.showsDecoration)
            XCTAssertEqual(layout.splitGap, 5)
        }
    }
}
