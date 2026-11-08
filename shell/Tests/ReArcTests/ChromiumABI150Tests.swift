import XCTest
@testable import ReArc

/// ABI 1.50 extension tab groups and 1.51 page theme colour.
final class ChromiumABI150Tests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    func testTabGroupsNeedABI50ItsFeatureAndExtensionWindows() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 49, hasFeature: all).extensionTabGroups)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 50, hasFeature: all).extensionTabGroups)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 50, hasFeature: { $0 != "extension_tab_groups" }).extensionTabGroups)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 50, hasFeature: { $0 != "extension_windows" }).extensionTabGroups)
    }

    func testPageThemeColourNeedsABI51AndItsFeature() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 50, hasFeature: all).pageThemeColor)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 51, hasFeature: all).pageThemeColor)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 51, hasFeature: { $0 != "page_theme_color" }).pageThemeColor)
        XCTAssertFalse(ChromiumCapabilities.none.pageThemeColor)
    }

    func testSummaryListsBothFlags() {
        let summary = ChromiumCapabilities(abiMinorVersion: 51, hasFeature: all).summary
        XCTAssertTrue(summary.contains("extension_tab_groups=1"))
        XCTAssertTrue(summary.contains("page_theme_color=1"))
    }

    func testPageEdgePNGDecodesToItsColour() throws {
        // A 40×4 PNG strip of PAN Home's black, with an orange box, as the engine returns it.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0x1F / 255, green: 0x20 / 255, blue: 0x23 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 4))
        context.setFillColor(CGColor(srgbRed: 0xF5 / 255, green: 0x5A / 255, blue: 0x2A / 255, alpha: 1))
        context.fill(CGRect(x: 15, y: 0, width: 10, height: 4))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let color = try XCTUnwrap(PageEdgeImage.dominantColor(png: png))
        XCTAssertEqual(color.red, 0x1F / 255, accuracy: 2 / 255)
        XCTAssertEqual(color.blue, 0x23 / 255, accuracy: 2 / 255)
        XCTAssertTrue(color.prefersLightInk)
        XCTAssertNil(PageEdgeImage.dominantColor(png: Data("not a png".utf8)))
    }
}
