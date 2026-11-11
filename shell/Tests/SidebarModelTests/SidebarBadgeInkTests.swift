import XCTest
@testable import SidebarModel

/// Every text and glyph role on the sidebar, the profile badge and the New
/// Tab row must stay legible on every space theme, in light and dark,
/// whatever colour the profile itself has.
final class SidebarBadgeInkTests: XCTestCase {
    private static func theme(_ hex: String, intensity: Double = SpaceTheme.defaultIntensity) -> SpaceTheme {
        let color = SpaceColor(hex: hex)!
        var theme = SpaceTheme(red: color.red, green: color.green, blue: color.blue)
        theme.intensity = intensity
        return theme
    }

    /// The onboarding sky colours (`ProfilePalette.colours`): the first
    /// space takes the one picked.
    static let onboardingSkies = ["#FF5B3A", "#F5A524", "#5DB884", "#1BA9B5", "#3B8AF6", "#2740FF", "#8B5CF6", "#EC4F99"]

    /// Gradients that cross the black/white midpoint (luminance ≈ 0.18)
    /// under the sidebar: no single ink reaches 4.5:1 on all of it, so the
    /// text gets the best there is (black or white). Shipped presets reach
    /// it everywhere except gradient 4 in dark (4.42:1).
    static let straddling: Set<String> = [
        "gradient 4 dark",
        "black → white light", "black → white dark", "white → black light", "white → black dark",
        "ultramarine → sky dark", "navy → violet → teal light", "navy → violet → teal dark",
    ]

    static let themes: [(String, SpaceTheme)] = {
        var themes = SpaceTheme.presets.enumerated().map { ("preset \($0.offset)", $0.element) }
        themes += SpaceTheme.gradientPresets.enumerated().map { ("gradient \($0.offset)", $0.element) }
        themes += onboardingSkies.map { ("sky \($0)", theme($0)) }
        themes += SpaceTheme.editorSwatchPages.flatMap { $0 }.map { ("swatch \($0.spaceColor.hex)", $0) }
        themes += [
            ("saturated blue", SpaceTheme(red: 0.10, green: 0.35, blue: 0.95)),
            ("navy", SpaceTheme(red: 0.05, green: 0.08, blue: 0.30)),
            ("black", SpaceTheme(red: 0, green: 0, blue: 0)),
            ("white", SpaceTheme(red: 1, green: 1, blue: 1)),
            ("yellow", SpaceTheme(red: 0.98, green: 0.90, blue: 0.20)),
            ("legacy", .legacyDefault),
        ]
        // Custom colours at the extremes, at full and lowest intensity.
        for hex in ["#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#00FFFF", "#FF00FF", "#2740FF", "#3B8AF6", "#767676", "#808080", "#8A8A8A", "#000000"] {
            themes.append(("\(hex) full", theme(hex, intensity: 1)))
            themes.append(("\(hex) faint", theme(hex, intensity: SpaceTheme.intensityRange.lowerBound)))
        }
        // Textures darken the sidebar.
        for texture in SpaceTexture.allCases {
            var textured = theme("#3B8AF6")
            textured.texture = texture
            textured.noise = 1
            themes.append(("sky \(texture.rawValue)", textured))
        }
        // Gradients across the lightness range.
        func gradient(_ a: String, _ b: String, _ more: [String] = [], intensity: Double = 1) -> SpaceTheme {
            var theme = theme(a, intensity: intensity)
            theme.gradientColors = ([b] + more).map { SpaceColor(hex: $0)! }
            return theme
        }
        themes += [
            ("black → white", gradient("#000000", "#FFFFFF")),
            ("white → black", gradient("#FFFFFF", "#000000")),
            ("ultramarine → sky", gradient("#2740FF", "#3B8AF6", intensity: 0.8)),
            ("navy → violet → teal", gradient("#101040", "#8B5CF6", ["#1BA9B5"])),
            ("marigold → rose", gradient("#F5A524", "#EC4F99")),
        ]
        return themes
    }()

    private func contrast(_ a: SpaceColor, _ b: SpaceColor) -> Double { a.contrast(with: b) }

    /// Sidebar samples, finer than the backdrop's own: the sidebar's part of
    /// the window, top to bottom, with the texture at its mean.
    private func sidebarSamples(_ theme: SpaceTheme, windowDark: Bool) -> [SpaceColor] {
        let gradient = ThemeGradient(theme: theme, dark: windowDark)
        return stride(from: 0.0, through: 1.0, by: 0.05).flatMap { v in
            stride(from: 0.0, through: SidebarBackdrop.span, by: SidebarBackdrop.span / 10).map { u in
                SidebarBackdrop.textured(gradient.color(u: u, v: v).clamped, theme: theme)
            }
        }
    }

    private struct Role {
        var name: String
        var floor: Double
        var ink: KeyPath<ThemeChromePalette, SpaceColor>
    }

    /// Tab and folder titles, the space name (and with it New Tab, "…" and
    /// the section labels) at 4.5:1; quieter text and glyphs at 3:1.
    private let roles = [
        Role(name: "title", floor: SidebarContrast.text, ink: \.title),
        Role(name: "space name / New Tab", floor: SidebarContrast.text, ink: \.secondaryText),
        Role(name: "tertiary", floor: SidebarContrast.glyph, ink: \.tertiaryText),
        Role(name: "glyph", floor: SidebarContrast.glyph, ink: \.glyph),
        Role(name: "accent", floor: SidebarContrast.glyph, ink: \.accent),
    ]

    private static func label(_ name: String, _ windowDark: Bool) -> String { "\(name) \(windowDark ? "dark" : "light")" }

    private static var legibleCases: [(String, SpaceTheme, Bool)] {
        themes.flatMap { name, theme in [false, true].map { (name, theme, $0) } }
            .filter { !straddling.contains(label($0.0, $0.2)) }
    }

    func testEveryRoleClearsItsFloorOnEveryThemeAndAppearance() {
        var checked = 0
        for (name, theme) in Self.themes {
            for windowDark in [false, true] {
                let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: theme, windowDark: windowDark)
                let backdrop = SidebarBackdrop(theme: theme, dark: windowDark)
                let reach = max(backdrop.darkInkReach, backdrop.lightInkReach)
                let label = Self.label(name, windowDark)
                XCTAssertEqual(reach < SidebarContrast.text, Self.straddling.contains(label), "\(label): best reach \(reach)")
                XCTAssertEqual(lightInk, ThemeGradient.usesDarkChrome(theme: theme, dark: windowDark), label)
                let samples = sidebarSamples(theme, windowDark: windowDark)
                for role in roles {
                    let ink = chrome[keyPath: role.ink]
                    let worst = samples.map { contrast(ink, $0) }.min()!
                    let floor = min(role.floor, reach - 0.02)
                    XCTAssertGreaterThanOrEqual(worst, floor, "\(role.name) \(ink.hex), \(label)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 800)
    }

    /// The selected row and the hover wash only ever add contrast for the
    /// ink: a near-white pill under dark ink, a dark veil under light ink.
    func testSelectedAndHoveredRowsStayLegible() {
        for (name, theme, windowDark) in Self.legibleCases {
            let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: theme, windowDark: windowDark)
            let fill = SpaceThemeRoles(theme: theme).semantic(dark: lightInk).backgroundExtra
            for alpha in [SidebarRowWash.selectedAlpha(lightInk: lightInk), SidebarRowWash.hoverAlpha(lightInk: lightInk)] {
                for background in sidebarSamples(theme, windowDark: windowDark) {
                    let row = background.mixed(with: fill, fraction: alpha)
                    XCTAssertGreaterThanOrEqual(contrast(chrome.title, row), SidebarContrast.text,
                                                "\(Self.label(name, windowDark)) row at \(alpha) on \(background.hex)")
                }
            }
        }
    }

    func testBadgeGlyphAndEdgeReadOnEveryThemeAndAppearance() {
        for (name, theme, windowDark) in Self.legibleCases {
            let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: theme, windowDark: windowDark)
            let ink = SidebarBadgeInk(chrome: chrome, dark: lightInk)
            for background in sidebarSamples(theme, windowDark: windowDark) {
                let disc = ink.disc(over: background)
                let label = "\(Self.label(name, windowDark)) on \(background.hex)"
                XCTAssertGreaterThanOrEqual(contrast(ink.glyph, disc), 4.5, "glyph on disc, \(label)")
                XCTAssertGreaterThanOrEqual(max(contrast(disc, background), contrast(ink.outline(over: background), background)),
                                            1.8, "badge edge, \(label)")
            }
        }
    }

    /// The mini sidebar's corner marks (mute, Picture in Picture, a split)
    /// sit over favicons of any colour, on the badge's disc made opaque.
    func testMiniCornerMarksReadOnTheirOwnDisc() {
        for (name, theme, windowDark) in Self.legibleCases {
            let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: theme, windowDark: windowDark)
            let ink = SidebarBadgeInk(chrome: chrome, dark: lightInk)
            // Opaque, so nothing under it enters the ratio.
            XCTAssertGreaterThanOrEqual(contrast(ink.glyph, ink.cornerDisc), SidebarContrast.text, "corner mark, \(Self.label(name, windowDark))")
        }
    }

    func testBadgeIgnoresProfileColour() {
        let chrome = SpaceThemeRoles(theme: SpaceTheme.presets[1]).chrome(dark: false)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: false).glyph, chrome.glyph)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: false).disc, .white)
        XCTAssertEqual(SidebarBadgeInk(chrome: chrome, dark: true).disc, .black)
    }

    /// The report: the Ultramarine sky picked in onboarding, in light. The
    /// space name and New Tab took the fixed L 0.545 grey, about 1.2:1 on
    /// the #5266FF sidebar; fitted, they are a near-black tint of the hue.
    func testTheReportedBlueSpaceReads() {
        let sky = Self.theme("#2740FF")
        let background = ThemeGradient(theme: sky, dark: false).color(u: 0.1, v: 0.25)
        XCTAssertEqual(background.hex, "#5266FF")
        let recorded = SpaceThemeRoles(theme: sky).chrome(dark: false)
        XCTAssertLessThan(contrast(recorded.secondaryText, background), 1.3, "the reported faint space name")
        let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: sky, windowDark: false)
        XCTAssertFalse(lightInk, "black reaches further than white on #5266FF")
        XCTAssertGreaterThanOrEqual(contrast(chrome.secondaryText, background), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(chrome.title, background), 4.5)
        let hue = chrome.secondaryText.oklab.lch
        XCTAssertEqual(hue.h, recorded.secondaryText.oklab.lch.h, accuracy: 15, "still a tint of the theme's hue")
    }

    /// Where Arc's recorded tints already read they are kept as they are.
    func testRecordedTintsStayOnPaleThemes() {
        let roles = SpaceThemeRoles(theme: .arcDefault)
        let (lightInk, chrome) = SpaceThemeRoles.sidebarChrome(theme: .arcDefault, windowDark: false)
        XCTAssertFalse(lightInk)
        XCTAssertEqual(chrome.title, roles.lightChrome.title, "the measured navy")
        XCTAssertEqual(chrome.glyph, roles.lightChrome.glyph)
        XCTAssertEqual(chrome.accent, roles.light.foregroundPrimary, "#2731FF")
        XCTAssertEqual(chrome.separator, roles.lightChrome.separator)
        let dark = SpaceThemeRoles.sidebarChrome(theme: .arcDefault, windowDark: true)
        XCTAssertTrue(dark.lightInk, "light text on the navy default")
        XCTAssertEqual(dark.chrome.title, roles.darkChrome.title)
    }

    /// Dark or deep saturated themes take the light roles even in light
    /// appearance; pale ones keep dark ink in dark appearance, as Arc does.
    func testInkSideFollowsTheSidebarNotTheAppearance() {
        XCTAssertTrue(ThemeGradient.usesDarkChrome(theme: Self.theme("#000000"), dark: false))
        XCTAssertTrue(ThemeGradient.usesDarkChrome(theme: Self.theme("#2740FF", intensity: 1), dark: false))
        XCTAssertTrue(ThemeGradient.usesDarkChrome(theme: SpaceTheme.gradientPresets[5], dark: false))
        XCTAssertFalse(ThemeGradient.usesDarkChrome(theme: Self.theme("#F5A524"), dark: true))
        XCTAssertFalse(ThemeGradient.usesDarkChrome(theme: Self.theme("#FFFFFF"), dark: true))
    }
}
