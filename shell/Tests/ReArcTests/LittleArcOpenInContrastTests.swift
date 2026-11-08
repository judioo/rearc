import AppKit
import XCTest
@testable import ReArc
import SidebarModel

/// Break check 2026-11-08 (426), issue 19: Little Arc's "Open in <Space>"
/// drew the space's name in its theme colour, barely legible on the default
/// lavender. The words must read at WCAG AA, 4.5:1, on the toolbar in light
/// and dark, whatever the space's colour; the colour stays as a dot.
final class LittleArcOpenInContrastTests: XCTestCase {
    /// The bar material over a band of greys, as in `DownloadsTrayContrastTests`.
    private let lightBar: [CGFloat] = stride(from: 0xD0, through: 0xFC, by: 4).map { CGFloat($0) / 255 }
    private let darkBar: [CGFloat] = stride(from: 0x1A, through: 0x4E, by: 4).map { CGFloat($0) / 255 }
    /// The toolbar's tint toward the target space: its gradient's strong end.
    private let tint = 0.22

    private var themes: [SpaceTheme] {
        SpaceTheme.presets + SpaceTheme.gradientPresets.map(\.baseColor) + [.white, .black]
    }

    func testTheWordsReadOnTheTintedToolbarInLightAndDark() throws {
        for (name, greys) in [(NSAppearance.Name.aqua, lightBar), (.darkAqua, darkBar)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var label: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                label = LittleArcWindowView.labelColor.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(label)
            for grey in greys {
                for theme in themes {
                    let ratio = Self.contrast(of: color, over: background(grey: grey, theme: theme))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue), grey \(Int(grey * 255)), theme \(theme.baseColor): \(ratio)")
                }
            }
        }
    }

    /// The old label, the default lavender itself, fails on the light bar.
    func testTheThemeColourAsTextFails() {
        let lavender = SpaceTheme.default
        let color = NSColor(srgbRed: lavender.red, green: lavender.green, blue: lavender.blue, alpha: 1)
        XCTAssertLessThan(Self.contrast(of: color, over: background(grey: 0xE6 / 255, theme: lavender)), 4.5)
    }

    private func background(grey: CGFloat, theme: SpaceTheme) -> (CGFloat, CGFloat, CGFloat) {
        func mix(_ channel: Double) -> CGFloat { grey * (1 - tint) + CGFloat(channel * tint) }
        return (mix(theme.red), mix(theme.green), mix(theme.blue))
    }

    private static func contrast(of color: NSColor, over bg: (CGFloat, CGFloat, CGFloat)) -> Double {
        let alpha = color.alphaComponent
        func over(_ channel: CGFloat, _ base: CGFloat) -> CGFloat { channel * alpha + base * (1 - alpha) }
        let fg = DownloadsTrayContrastTests.luminance(over(color.redComponent, bg.0), over(color.greenComponent, bg.1),
                                                      over(color.blueComponent, bg.2))
        let back = DownloadsTrayContrastTests.luminance(bg.0, bg.1, bg.2)
        return (max(fg, back) + 0.05) / (min(fg, back) + 0.05)
    }
}
