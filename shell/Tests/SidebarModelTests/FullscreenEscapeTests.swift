import XCTest
@testable import SidebarModel

final class FullscreenEscapeTests: XCTestCase {
    func testEntryHintOncePerEntryAndNoWindowedPress() {
        var state = FullscreenEscape()
        XCTAssertEqual(state.press(at: 0, consumed: false), .none)
        XCTAssertEqual(state.setFullscreen(true), .showHint)
        XCTAssertEqual(state.setFullscreen(true), .none)
        XCTAssertEqual(state.setFullscreen(false), .none)
        XCTAssertEqual(state.setFullscreen(true), .showHint)
    }

    func testSinglePressThenPairInsideWindow() {
        var state = FullscreenEscape()
        _ = state.setFullscreen(true)
        XCTAssertEqual(state.press(at: 10, consumed: false), .showHint)
        XCTAssertEqual(state.press(at: 11.5, consumed: false), .exit)
    }

    func testPairOutsideWindowStartsAgain() {
        var state = FullscreenEscape()
        _ = state.setFullscreen(true)
        XCTAssertEqual(state.press(at: 10, consumed: false), .showHint)
        XCTAssertEqual(state.press(at: 11.6, consumed: false), .showHint)
        XCTAssertEqual(state.press(at: 12, consumed: false), .exit)
    }

    func testConsumedEscapeBreaksPair() {
        var state = FullscreenEscape()
        _ = state.setFullscreen(true)
        XCTAssertEqual(state.press(at: 10, consumed: false), .showHint)
        XCTAssertEqual(state.press(at: 10.1, consumed: true), .none)
        XCTAssertEqual(state.press(at: 10.2, consumed: false), .showHint)
    }

    func testExitClearsArmedPress() {
        var state = FullscreenEscape()
        _ = state.setFullscreen(true)
        _ = state.press(at: 10, consumed: false)
        _ = state.setFullscreen(false)
        _ = state.setFullscreen(true)
        XCTAssertEqual(state.press(at: 10.2, consumed: false), .showHint)
    }
}
