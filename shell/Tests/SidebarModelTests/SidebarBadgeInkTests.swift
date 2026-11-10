import XCTest
@testable import SidebarModel

/// The profile badge and New Tab row must stay legible on every space theme,
/// in light and dark, whatever colour the profile itself has.
final class SidebarBadgeInkTests: XCTestCase {
    private let themes: [(String, SpaceTheme)] = {
        var themes = SpaceTheme.presets.enumerated().map { ("preset \($0.offset)", $0.element) }
        themes += SpaceTheme.gradientPresets.enumerated().map { ("gradient \($0.offset)", $0.element) }
        themes += [
            ("saturated blue", SpaceTheme(red: 0.10, green: 0.35, blue: 0.95)),
            ("navy", SpaceTheme(red: 0.05, green: 0.08, blue: 0.30)),
            ("black", SpaceTheme(red: 0, green: 0, blue: 0)),
            ("white", SpaceTheme(red: 1, green: 1, blue: 1)),
            ("yellow", SpaceTheme(red: 0.98, green: 0.90, blue: 0.20)),
            ("legacy", .legacyDefault),
        ]
        return themes
    }()

    private func contrast(_ a: SpaceColor, _ b: SpaceColor) -> Double {
        PageColor(red: a.red, green: a.green, blue: a.blue).contrast(with: PageColor(red: b.red, green: b.green, blue: b.blue))
    }

    private func luminance(_ c: SpaceColor) -> Double { PageColor(red: c.red, green: c.green, blue: c.blue).luminance }

    /// Sidebar samples: the left fifth of the window, top to bottom.
    private func sidebarSamples(_ theme: SpaceTheme, windowDark: Bool) -> [SpaceColor] {
        let gradient = ThemeGradient(theme: theme, dark: windowDark)
        return stride(from: 0.0, through: 1.0, by: 0.25).flatMap { v in
            [0.02, 0.1, 0.2].map { gradient.color(u: $0, v: v) }
        }
    }

    func testBadgeGlyphAndEdgeReadOnEveryThemeAndAppearance() {
        for (name, theme) in themes {
            for windowDark in [false, true] {
                let chromeDark = ThemeGradient.usesDarkChrome(theme: theme, dark: windowDark)
                let ink = SidebarBadgeInk(chrome: SpaceThemeRoles(theme: theme).chrome(dark: chromeDark), dark: chromeDark)
                for background in sidebarSamples(theme, windowDark: windowDark) {
                    let disc = ink.disc(over: background)
                    let label = "\(name) \(windowDark ? "dark" : "light") on \(background.hex)"
                    XCTAssertGreaterThanOrEqual(contrast(ink.glyph, disc), 4.5, "glyph on disc, \(label)")
                    XCTAssertGreaterThanOrEqual(max(contrast(disc, background), contrast(ink.outline(over: background), background)),
                                                1.8, "badge edge, \(label)")
                }
            }
        }
    }

    func testBadgeIgnoresProfileColour() {
        let chrome = SpaceThemeRoles(theme: SpaceTheme.presets[1]).chrome(dark: false)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: false).glyph, chrome.glyph)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: false).disc, .white)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: true).disc, .black)
    }

    /// New Tab uses the secondary role (the space name's). Tertiary was the
    /// faint row in the report: about 1.1:1 on a coloured sidebar. Where the
    /// sidebar is lighter than both light-chrome greys (or darker than both
    /// dark-chrome ones) secondary always reads better. Mid-tone sidebars sit
    /// between the greys and are weak for every role; that is the theme
    /// roles' business, not the row's.
    func testNewTabRowUsesTheReadableRole() {
        var compared = 0
        for (name, theme) in themes {
            for windowDark in [false, true] {
                let chromeDark = ThemeGradient.usesDarkChrome(theme: theme, dark: windowDark)
                let chrome = SpaceThemeRoles(theme: theme).chrome(dark: chromeDark)
                for background in sidebarSamples(theme, windowDark: windowDark)
                where chromeDark ? luminance(background) < 0.19 : luminance(background) > 0.35 {
                    compared += 1
                    XCTAssertGreaterThan(contrast(chrome.secondaryText, background), contrast(chrome.tertiaryText, background),
                                         "\(name) \(windowDark ? "dark" : "light") on \(background.hex)")
                }
            }
        }
        XCTAssertGreaterThan(compared, 100)
        let sky = SpaceTheme.presets[1]
        let chrome = SpaceThemeRoles(theme: sky).chrome(dark: false)
        let background = ThemeGradient(theme: sky, dark: false).color(u: 0.1, v: 0.25)
        XCTAssertLessThan(contrast(chrome.tertiaryText, background), 1.3, "the reported faint row")
        XCTAssertGreaterThan(contrast(chrome.secondaryText, background), 2.0)
    }
}
