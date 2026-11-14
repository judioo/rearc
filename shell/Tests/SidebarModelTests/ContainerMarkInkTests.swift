import XCTest
@testable import SidebarModel

/// A container's ring and badge must read on every space theme, in light
/// and dark, whatever colour the container has: most of all its space's
/// own, which it takes when it is made.
final class ContainerMarkInkTests: XCTestCase {
    private static func color(_ hex: String) -> SpaceColor { SpaceColor(hex: hex)! }

    /// The themes of `SidebarBadgeInkTests`, without the gradients no single ink reads on.
    private static var cases: [(label: String, theme: SpaceTheme, windowDark: Bool)] {
        SidebarBadgeInkTests.themes.flatMap { name, theme in
            [false, true].map { (label: "\(name) \($0 ? "dark" : "light")", theme: theme, windowDark: $0) }
        }
        .filter { !SidebarBadgeInkTests.straddling.contains($0.label) }
    }

    /// The sidebar finer than the backdrop the ink was fitted on.
    private func sidebarSamples(_ theme: SpaceTheme, windowDark: Bool) -> [SpaceColor] {
        let gradient = ThemeGradient(theme: theme, dark: windowDark)
        return stride(from: 0.0, through: 1.0, by: 0.05).flatMap { v in
            stride(from: 0.0, through: SidebarBackdrop.span, by: SidebarBackdrop.span / 10).map { u in
                SidebarBackdrop.textured(gradient.color(u: u, v: v).clamped, theme: theme)
            }
        }
    }

    private func ink(_ container: SpaceColor, on theme: SpaceTheme, windowDark: Bool) -> ContainerMarkInk {
        let backdrop = SidebarBackdrop(theme: theme, dark: windowDark)
        return ContainerMarkInk(container: container, backdrop: backdrop, lightInk: backdrop.prefersLightInk)
    }

    func testRingAndBadgeReadOnEveryThemeInAnyContainerColour() {
        var checked = 0
        for (label, theme, windowDark) in Self.cases {
            let backdrop = SidebarBackdrop(theme: theme, dark: windowDark)
            // Its space's own colour first, then the profile colours and the extremes.
            let containers = [theme.spaceColor] + (SidebarBadgeInkTests.onboardingSkies + ["#FFFFFF", "#000000", "#FFFF00", "#808080"]).map(Self.color)
            // A gradient no ink clears 3:1 on gets the best there is, as its text does.
            let floor = min(SidebarContrast.glyph, max(backdrop.darkInkReach, backdrop.lightInkReach) - 0.02)
            for container in containers {
                let ink = ink(container, on: theme, windowDark: windowDark)
                let worst = sidebarSamples(theme, windowDark: windowDark).map { ink.tint.contrast(with: $0) }.min()!
                XCTAssertGreaterThanOrEqual(worst, floor, "ring \(ink.tint.hex) of container \(container.hex), \(label)")
                XCTAssertGreaterThanOrEqual(ink.glyph.contrast(with: ink.tint), SidebarContrast.glyph, "badge glyph on \(ink.tint.hex), \(label)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1500)
    }

    /// The report: a container made on the default theme has the theme's own
    /// pale colour, about 1.1:1 on the sidebar. Fitted, it is a darker tint
    /// of the same hue.
    func testTheReportedPaleContainerReads() {
        let container = SpaceTheme.arcDefault.spaceColor
        let sidebar = ThemeGradient(theme: .arcDefault, dark: false).color(u: 0.1, v: 0.25).clamped
        XCTAssertLessThan(container.contrast(with: sidebar), 1.3, "the reported invisible badge")
        let ink = ink(container, on: .arcDefault, windowDark: false)
        XCTAssertGreaterThanOrEqual(ink.tint.contrast(with: sidebar), SidebarContrast.glyph)
        XCTAssertLessThan(ink.tint.luminance, container.luminance, "darker, with the sidebar's dark ink")
        XCTAssertEqual(ink.tint.oklab.lch.h, container.oklab.lch.h, accuracy: 15, "still the container's hue")
        XCTAssertEqual(ink.glyph, .white)
        // In dark the same container goes lighter instead.
        let dark = self.ink(container, on: .arcDefault, windowDark: true)
        let darkSidebar = ThemeGradient(theme: .arcDefault, dark: true).color(u: 0.1, v: 0.25).clamped
        XCTAssertGreaterThanOrEqual(dark.tint.contrast(with: darkSidebar), SidebarContrast.glyph)
        XCTAssertGreaterThan(dark.tint.luminance, darkSidebar.luminance)
    }

    /// A colour that already reads stays the container's own, as its chip
    /// shows it: on either side of the sidebar, not only its ink's.
    func testAColourThatReadsIsKept() {
        let navy = Self.color("#101040"), yellow = Self.color("#FFE030"), red = Self.color("#D0261A")
        let mint = SpaceTheme(red: 0.365, green: 0.722, blue: 0.518)
        XCTAssertEqual(ink(navy, on: mint, windowDark: false).tint, navy)
        XCTAssertEqual(ink(red, on: .arcDefault, windowDark: false).tint, red)
        XCTAssertEqual(ink(yellow, on: .arcDefault, windowDark: true).tint, yellow)
        // Dark ink on a saturated blue sidebar, and a yellow far lighter than it.
        var ultramarine = SpaceTheme(red: 0.153, green: 0.251, blue: 1)
        ultramarine.intensity = SpaceTheme.defaultIntensity
        XCTAssertFalse(SidebarBackdrop(theme: ultramarine, dark: false).prefersLightInk)
        XCTAssertEqual(ink(yellow, on: ultramarine, windowDark: false).tint, yellow)
    }

    func testBadgeGlyphIsWhiteWhereItReads() {
        XCTAssertEqual(ink(Self.color("#D0261A"), on: .arcDefault, windowDark: false).glyph, .white)
        XCTAssertEqual(ink(Self.color("#2740FF"), on: .arcDefault, windowDark: false).glyph, .white)
        XCTAssertEqual(ink(Self.color("#FFE030"), on: .arcDefault, windowDark: true).glyph, .black)
        XCTAssertEqual(ink(.white, on: .black, windowDark: true).glyph, .black)
    }

    /// Settings, the Spaces list and Little ReArc's toolbar: a window's own background.
    func testMarkReadsOnAWindowInBothAppearances() {
        for hex in SidebarBadgeInkTests.onboardingSkies + ["#DFDBF1", "#FFFFFF", "#000000"] {
            for dark in [false, true] {
                let ink = ContainerMarkInk(container: Self.color(hex), windowDark: dark)
                let window = ContainerMarkInk.window(dark: dark)
                for background in [window.darkest, window.lightest] {
                    XCTAssertGreaterThanOrEqual(ink.tint.contrast(with: background), SidebarContrast.glyph, "\(hex) \(dark ? "dark" : "light")")
                }
            }
        }
    }
}
