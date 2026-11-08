import XCTest
@testable import SidebarModel

/// The toolbar's page colour: theme colour first, the top edge's one colour
/// second, and ink that reads on it.
final class PageToolbarColorTests: XCTestCase {
    private func strip(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0 ..< height { for x in 0 ..< width { let p = pixel(x, y); bytes += [p.0, p.1, p.2, p.3] } }
        return bytes
    }

    func testSkColorUnpacksAndCompositesOverWhite() {
        XCTAssertEqual(PageColor(argb: 0xFF1F_2023), PageColor(red: 31 / 255, green: 32 / 255, blue: 35 / 255))
        let half = PageColor(argb: 0x8000_0000)
        XCTAssertEqual(half.red, 1 - 128 / 255, accuracy: 1e-9)
    }

    func testPanHomesBlackBarTakesLightInkAndWhiteTakesDark() {
        XCTAssertTrue(PageColor(argb: 0xFF1F_2023).prefersLightInk)
        XCTAssertFalse(PageColor.white.prefersLightInk)
        XCTAssertFalse(PageColor(argb: 0xFFF5_5A2A).prefersLightInk) // PAN's orange box is light enough for black
    }

    func testTheStripsMainColourWinsOverItsTextAndBox() {
        // PAN Home's top bar: black, an orange box in the middle third, a little white text.
        let width = 300, height = 4
        let bytes = strip(width: width, height: height) { x, y in
            if (100 ..< 200).contains(x) { return (0xF5, 0x5A, 0x2A, 255) }
            if x % 25 == 0, y == 2 { return (255, 255, 255, 255) }
            return (0x1F, 0x20, 0x23, 255)
        }
        let color = PageEdgeSample.dominantColor(rgba: bytes, width: width, height: height, bytesPerRow: width * 4)
        XCTAssertEqual(color, PageColor(red: 31 / 255, green: 32 / 255, blue: 35 / 255))
    }

    func testABusyStripHasNoColour() {
        let width = 100, height = 2
        let halves = strip(width: width, height: height) { x, _ in x < 50 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        XCTAssertNotNil(PageEdgeSample.dominantColor(rgba: halves, width: width, height: height, bytesPerRow: width * 4),
                        "exactly half still counts")
        let thirds = strip(width: width, height: height) { x, _ in
            x < 34 ? (0, 0, 0, 255) : x < 67 ? (255, 255, 255, 255) : (200, 0, 0, 255)
        }
        XCTAssertNil(PageEdgeSample.dominantColor(rgba: thirds, width: width, height: height, bytesPerRow: width * 4))
        XCTAssertNil(PageEdgeSample.dominantColor(rgba: [], width: 0, height: 0, bytesPerRow: 0))
        XCTAssertNil(PageEdgeSample.dominantColor(rgba: [0, 0, 0], width: 1, height: 1, bytesPerRow: 4), "short buffer")
    }

    func testTransparentPixelsReadAsWhite() {
        let bytes = strip(width: 10, height: 1) { _, _ in (0, 0, 0, 0) }
        XCTAssertEqual(PageEdgeSample.dominantColor(rgba: bytes, width: 10, height: 1, bytesPerRow: 40), .white)
    }

    func testThemeColourWinsAndAnOldSampleIsDropped() {
        var state = PageToolbarColorState()
        state.documentChanged(to: 1)
        XCTAssertTrue(state.needsEdgeSample)
        state.setEdgeColor(.black, document: 1)
        XCTAssertEqual(state.color, .black)
        XCTAssertFalse(state.needsEdgeSample)

        // The next page keeps the old colour until its own sample arrives.
        state.documentChanged(to: 2)
        XCTAssertEqual(state.color, .black)
        state.setEdgeColor(.white, document: 1)
        XCTAssertEqual(state.color, .black, "a sample of the previous document is stale")
        state.setEdgeColor(.white, document: 2)
        XCTAssertEqual(state.color, .white)

        let blue = PageColor(argb: 0xFF33_67D6)
        state.setThemeColor(blue)
        XCTAssertEqual(state.color, blue)
        XCTAssertFalse(state.needsEdgeSample)
        state.setThemeColor(nil)
        XCTAssertEqual(state.color, .white)

        state.documentChanged(to: 3)
        state.clear()
        XCTAssertNil(state.color)
        XCTAssertFalse(state.needsEdgeSample, "a blank page isn't sampled")
    }

    func testInkReadsOnEveryPageColour() {
        // Enabled glyphs and the address reach 3:1 (WCAG non-text) on any page colour.
        var worst = Double.infinity
        for r in stride(from: 0.0, through: 1, by: 1 / 16) {
            for g in stride(from: 0.0, through: 1, by: 1 / 16) {
                for b in stride(from: 0.0, through: 1, by: 1 / 16) {
                    let background = PageColor(red: r, green: g, blue: b)
                    let ink = PageColorInk(on: background)
                    worst = min(worst, ink.blended(ink.inkOpacity, over: background).contrast(with: background))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(worst, 3)
        let black = PageColor(argb: 0xFF1F_2023)
        let ink = PageColorInk(on: black)
        XCTAssertTrue(ink.isLight)
        XCTAssertGreaterThanOrEqual(ink.blended(ink.inkOpacity, over: black).contrast(with: black), 12)
    }

    func testPreferenceIsOnByDefaultAndOnlyWebPagesHaveAColour() {
        let defaults = UserDefaults(suiteName: "PageToolbarColorTests")!
        defaults.removePersistentDomain(forName: "PageToolbarColorTests")
        XCTAssertTrue(ToolbarPageColorPreference.isEnabled(in: defaults))
        defaults.set(false, forKey: ToolbarPageColorPreference.key)
        XCTAssertFalse(ToolbarPageColorPreference.isEnabled(in: defaults))
        defaults.removePersistentDomain(forName: "PageToolbarColorTests")
        XCTAssertTrue(ToolbarPageColorPreference.pageHasColor(URL(string: "https://www.panhomestores.com/")))
        XCTAssertFalse(ToolbarPageColorPreference.pageHasColor(URL(string: "about:blank")))
        XCTAssertFalse(ToolbarPageColorPreference.pageHasColor(URL(string: "chrome://settings")))
        XCTAssertFalse(ToolbarPageColorPreference.pageHasColor(nil))
    }
}
