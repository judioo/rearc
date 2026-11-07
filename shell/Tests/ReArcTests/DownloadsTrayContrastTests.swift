import AppKit
import XCTest
@testable import ReArc

/// Break check 2026-11-07 night, issue 10: the tray's folder menu
/// ("synthfiles ⌄" beside Clear) was light lavender on the tray's grey. Its
/// label must read at WCAG AA, 4.5:1, on the tray in either appearance.
final class DownloadsTrayContrastTests: XCTestCase {
    /// The popover material's grey takes some colour from what's behind it,
    /// so each appearance is checked over a wide band of greys around it.
    private let lightTray: [CGFloat] = stride(from: 0xD0, through: 0xFC, by: 4).map { CGFloat($0) / 255 }
    private let darkTray: [CGFloat] = stride(from: 0x1A, through: 0x4E, by: 4).map { CGFloat($0) / 255 }

    func testTheFolderLabelReadsOnTheTrayInLightAndDark() throws {
        for (name, greys) in [(NSAppearance.Name.aqua, lightTray), (.darkAqua, darkTray)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var label: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                label = DownloadsTrayView.folderLabelColor.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(label)
            for grey in greys {
                let ratio = Self.contrast(of: color, over: grey)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue) over grey \(Int(grey * 255)): \(ratio)")
            }
        }
    }

    /// A lavender like the old label's (estimated from the break check's
    /// capture) fails, so the check can tell.
    func testTheOldLavenderFails() throws {
        let lavender = NSColor(srgbRed: 0xB8 / 255, green: 0xB4 / 255, blue: 0xE0 / 255, alpha: 1)
        XCTAssertLessThan(Self.contrast(of: lavender, over: 0xE6 / 255), 4.5)
    }

    /// WCAG 2 contrast of a colour, composited with its alpha, over an
    /// opaque grey.
    static func contrast(of color: NSColor, over grey: CGFloat) -> Double {
        let alpha = color.alphaComponent
        func over(_ channel: CGFloat) -> CGFloat { channel * alpha + grey * (1 - alpha) }
        let fg = luminance(over(color.redComponent), over(color.greenComponent), over(color.blueComponent))
        let bg = luminance(grey, grey, grey)
        return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
    }

    static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
