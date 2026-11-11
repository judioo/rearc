import Foundation

/// Arc's four primary theme colours (`primaryColorPalette`, THEMES.md §2.2),
/// all derived from colour 1 of the theme.
public struct ThemePrimaryPalette: Hashable, Sendable {
    public var tintedLight: SpaceColor
    public var midTone: SpaceColor
    public var shaded: SpaceColor
    public var shadedDark: SpaceColor

    public init(tintedLight: SpaceColor, midTone: SpaceColor, shaded: SpaceColor, shadedDark: SpaceColor) {
        self.tintedLight = tintedLight
        self.midTone = midTone
        self.shaded = shaded
        self.shadedDark = shadedDark
    }

    /// Fitted to the 13 themes stored in the user's Arc data (THEMES.md §3.5):
    /// fixed OKLab lightness targets at the base hue, chroma raised toward the
    /// sRGB edge. Within ΔE_OK 0.02 (tinted light), 0.05 (shaded dark) and
    /// 0.09 (mid tone, whose stored P3 values are clamped in the samples).
    public init(base: SpaceColor) {
        let lch = base.oklab.lch
        func fitted(l: Double, c: Double) -> SpaceColor {
            OKLCH(l: l, c: c, h: lch.h).gamutMapped(to: .sRGB).lab.color.clamped
        }
        func edge(_ l: Double) -> Double { OKLCH(l: l, c: 0, h: lch.h).maximumChroma(in: .sRGB) }

        let lightL = max(lch.l, 0.95)
        tintedLight = lch.l > 0.95 && lch.c <= 0.06
            ? base
            : fitted(l: lightL, c: min(0.8 * edge(lightL), max(0.2 * lch.c, 0.06)))

        let midL = min(max(lch.l, 0.70), 0.795)
        midTone = (0.70 ... 0.795).contains(lch.l) ? base : fitted(l: midL, c: min(edge(midL), 5 * lch.c))
        shaded = (0.60 ... 0.795).contains(lch.l) ? base : midTone
        shadedDark = fitted(l: 0.46, c: min(edge(0.46), 3 * lch.c))
    }
}

/// One appearance's twelve semantic colours (`semanticColorPalette`),
/// plus the alpha Arc gives hover and focus in dark mode.
public struct ThemeSemanticPalette: Hashable, Sendable {
    public var background: SpaceColor
    public var backgroundExtra: SpaceColor
    public var cutoutColor: SpaceColor
    public var focus: SpaceColor
    public var focusAlpha: Double
    public var foregroundPrimary: SpaceColor
    public var foregroundSecondary: SpaceColor
    public var foregroundTertiary: SpaceColor
    public var hover: SpaceColor
    public var hoverAlpha: Double
    public var maxContrastColor: SpaceColor
    public var minContrastColor: SpaceColor
    public var subtitle: SpaceColor
    public var title: SpaceColor
}

/// Text and glyph colours for chrome drawn on the theme: titles, subtitles,
/// the space name, the New Tab row, bottom-bar glyphs and separators
/// (THEMES.md §4.6, §4.7). Arc's greys are near-neutral with a hint of the
/// theme's hue, so they are fixed OKLab lightnesses at the base hue rather
/// than black or white at an opacity. These are the recorded values; the
/// sidebar draws them fitted to its backdrop (`legible(on:lightInk:)`).
public struct ThemeChromePalette: Hashable, Sendable {
    /// Tab and folder titles (the semantic `title`).
    public var title: SpaceColor
    /// Folder glyphs, the space icon and the active space dot (`foregroundPrimary`).
    public var accent: SpaceColor
    /// "3 Recent", the space name (`#6D6D79`, `#787886` on the default theme).
    public var secondaryText: SpaceColor
    /// "New Tab", space dots (`#9F9BA7`, `#AEA8B1`).
    public var tertiaryText: SpaceColor
    /// Bottom-bar glyphs and the sidebar toggle (`#666267`, `#5F5E6A`).
    public var glyph: SpaceColor
    /// The Pinned / Today divider (`#C0BDCC`).
    public var separator: SpaceColor
}

/// Everything a window needs to draw one theme's chrome: Arc's primary and
/// per-appearance semantic palettes and ReArc's chrome greys. Text never
/// switches to plain black or white: it is a fixed-lightness tint of the
/// base hue (THEMES.md §3.6 contrast rule).
public struct SpaceThemeRoles: Hashable, Sendable {
    public var primary: ThemePrimaryPalette
    public var light: ThemeSemanticPalette
    public var dark: ThemeSemanticPalette
    public var lightChrome: ThemeChromePalette
    public var darkChrome: ThemeChromePalette

    public func semantic(dark isDark: Bool) -> ThemeSemanticPalette { isDark ? dark : light }
    public func chrome(dark isDark: Bool) -> ThemeChromePalette { isDark ? darkChrome : lightChrome }

    /// Roles for `theme`. Arc's palette depends on colour 1 only, so themes
    /// that share it share their roles (THEMES.md §2.2). The built-in default
    /// is the exception: Arc derives it from the profile colour, so it uses
    /// the measured navy title and blue-violet accent (§4.2).
    public init(theme: SpaceTheme) {
        let base = theme.baseColor.spaceColor
        if base == SpaceTheme.arcDefault.baseColor.spaceColor {
            self.init(primary: SpaceThemeRoles.arcDefaultPrimary, hueOf: base)
        } else {
            self.init(primary: ThemePrimaryPalette(base: base), hueOf: base)
        }
    }

    /// Semantic roles from a primary palette. Each is a straight sRGB mix of
    /// the primaries, fitted to the 13 stored themes within ΔE_OK 0.017.
    public init(primary p: ThemePrimaryPalette, hueOf base: SpaceColor) {
        primary = p
        let sd = p.shadedDark, tl = p.tintedLight
        light = ThemeSemanticPalette(
            background: SpaceColor.white.mixed(with: sd, fraction: 0.105),
            backgroundExtra: SpaceColor.white.mixed(with: sd, fraction: 0.01),
            cutoutColor: tl,
            focus: SpaceColor.white.mixed(with: sd, fraction: 0.52),
            focusAlpha: 1,
            foregroundPrimary: p.shaded,
            foregroundSecondary: p.midTone,
            foregroundTertiary: tl,
            hover: SpaceColor.white.mixed(with: sd, fraction: 0.21),
            hoverAlpha: 1,
            maxContrastColor: sd,
            minContrastColor: tl,
            subtitle: SpaceColor.white.mixed(with: sd, fraction: 0.42),
            title: sd.scaled(by: 0.3)
        )
        dark = ThemeSemanticPalette(
            background: sd.scaled(by: 0.3),
            backgroundExtra: sd.scaled(by: 0.15),
            cutoutColor: sd,
            focus: sd.mixed(with: tl, fraction: 0.2),
            focusAlpha: 0.8075,
            foregroundPrimary: tl,
            foregroundSecondary: p.midTone,
            foregroundTertiary: p.shaded,
            hover: sd.mixed(with: tl, fraction: 0.275),
            hoverAlpha: 0.48,
            maxContrastColor: tl,
            minContrastColor: sd,
            subtitle: tl.scaled(by: 0.5),
            title: SpaceColor.white.mixed(with: sd, fraction: 0.155)
        )
        let hue = base.oklab.lch.h
        func grey(_ l: Double, _ c: Double) -> SpaceColor { OKLCH(l: l, c: c, h: hue).gamutMapped(to: .sRGB).lab.color.clamped }
        lightChrome = ThemeChromePalette(
            title: light.title, accent: light.foregroundPrimary, secondaryText: grey(0.545, 0.016), tertiaryText: grey(0.70, 0.016),
            glyph: grey(0.50, 0.010), separator: grey(0.80, 0.020)
        )
        darkChrome = ThemeChromePalette(
            title: dark.title, accent: dark.foregroundPrimary, secondaryText: grey(0.72, 0.016), tertiaryText: grey(0.58, 0.016),
            glyph: grey(0.76, 0.010), separator: grey(0.36, 0.020)
        )
    }

    /// The default theme's primaries (THEMES.md §4.2, §3.6): folder glyphs
    /// and accents `#2731FF`, so the title (shaded dark × 0.3) is the
    /// measured navy `#0B0F4D` ≈ `#090D4F`.
    public static let arcDefaultPrimary = ThemePrimaryPalette(
        tintedLight: SpaceColor(hex: "#ECEDFF")!,
        midTone: SpaceColor(hex: "#2731FF")!,
        shaded: SpaceColor(hex: "#2731FF")!,
        shadedDark: SpaceColor(hex: "#2731FF")!
    )
}

public extension SpaceColor {
    /// Each component clamped to 0…1.
    var clamped: SpaceColor {
        SpaceColor(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1))
    }
}

public extension SpaceTheme {
    var spaceColor: SpaceColor { SpaceColor(red: red, green: green, blue: blue) }
    var roles: SpaceThemeRoles { SpaceThemeRoles(theme: self) }
}
