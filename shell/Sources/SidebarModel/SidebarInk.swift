import Foundation

/// The contrast floors for chrome drawn on the sidebar (WCAG 2 ratios).
public enum SidebarContrast {
    /// Text people read: tab and folder titles, the space name, subtitles.
    public static let text = 4.5
    /// Glyphs and quieter text: New Tab's plus, toolbar and bottom-bar
    /// icons, space dots, folder glyphs, the rename placeholder.
    public static let glyph = 3.0
    /// Moved inks aim this far above their floor, so rounding to 8-bit
    /// colour on screen never lands them below it.
    static let margin = 0.08
}

/// What the sidebar's text sits on for one theme in one appearance: the
/// darkest and lightest colours the theme draws under it. The window
/// gradient is in UV space, so the sidebar covers its left edge from top to
/// bottom, out to `span`: the standard 228 pt sidebar on the 760 pt
/// minimum window. A texture only darkens; it counts at its mean.
public struct SidebarBackdrop: Hashable, Sendable {
    public var darkest: SpaceColor
    public var lightest: SpaceColor

    public init(darkest: SpaceColor, lightest: SpaceColor) {
        self.darkest = darkest
        self.lightest = lightest
    }

    public static let span = 0.3

    /// `rows` and `columns` set how finely the sidebar is sampled.
    public init(theme: SpaceTheme, dark: Bool, span: Double = Self.span, rows: Int = 8, columns: Int = 4) {
        let gradient = ThemeGradient(theme: theme, dark: dark)
        let samples = stride(from: 0.0, through: 1.0, by: 1 / Double(rows)).flatMap { v in
            stride(from: 0.0, through: span, by: span / Double(columns)).map { u in
                Self.textured(gradient.color(u: u, v: v).clamped, theme: theme)
            }
        }
        self.init(darkest: samples.min { $0.luminance < $1.luminance }!,
                  lightest: samples.max { $0.luminance < $1.luminance }!)
    }

    /// The colour with the theme's texture at its mean: the grain is far
    /// finer than a glyph, so text reads against its average.
    public static func textured(_ color: SpaceColor, theme: SpaceTheme) -> SpaceColor {
        guard theme.noise > 0 else { return color }
        return ThemeTextureBlend.multiply(color, texel: theme.texture.meanTexel, alpha: theme.texture.meanAlpha * theme.noise)
    }

    /// The best contrast any dark ink (black) can reach on every sample.
    public var darkInkReach: Double { (darkest.luminance + 0.05) / 0.05 }
    /// The best contrast any light ink (white) can reach on every sample.
    public var lightInkReach: Double { 1.05 / (lightest.luminance + 0.05) }

    /// Light text reads better than dark here, so the chrome takes its dark
    /// roles. A pale theme keeps Arc's dark tints and a dark or deep
    /// saturated one takes the light ones, whatever the appearance.
    public var prefersLightInk: Bool { lightInkReach > darkInkReach }

    /// `ink`'s contrast on the side of the backdrop it must clear: the
    /// darkest sample for dark ink, the lightest for light ink. Below 1 the
    /// ink is on the wrong side of that sample.
    public func contrast(of ink: SpaceColor, lightInk: Bool) -> Double {
        lightInk
            ? (ink.luminance + 0.05) / (lightest.luminance + 0.05)
            : (darkest.luminance + 0.05) / (ink.luminance + 0.05)
    }

    /// `ink` unchanged when it clears `floor` here; otherwise moved in OKLab
    /// lightness, at its own hue and chroma, just far enough toward black
    /// (dark ink) or white (light ink) to clear it. When even black or white
    /// cannot (a gradient spanning both), it ends at black or white.
    public func legible(_ ink: SpaceColor, floor: Double, lightInk: Bool) -> SpaceColor {
        guard contrast(of: ink, lightInk: lightInk) < floor else { return ink }
        let target = floor + SidebarContrast.margin
        let lch = ink.oklab.lch
        func at(_ l: Double) -> SpaceColor { OKLCH(l: l, c: lch.c, h: lch.h).gamutMapped(to: .sRGB).lab.color.clamped }
        // Contrast rises monotonically as the ink moves away from the backdrop.
        var near = lch.l, far = lightInk ? 1.0 : 0.0
        guard contrast(of: at(far), lightInk: lightInk) >= target else { return lightInk ? .white : .black }
        for _ in 0 ..< 24 {
            let mid = (near + far) / 2
            if contrast(of: at(mid), lightInk: lightInk) >= target { far = mid } else { near = mid }
        }
        return at(far)
    }
}

public extension ThemeChromePalette {
    /// Each role moved only as far as its floor needs on `backdrop`: the
    /// recorded tints stay where they already read (the default theme's
    /// navy title, the bottom-bar glyph) and mid-tone themes get darker
    /// (or lighter) tints of their own hue.
    func legible(on backdrop: SidebarBackdrop, lightInk: Bool) -> ThemeChromePalette {
        func fit(_ ink: SpaceColor, _ floor: Double) -> SpaceColor { backdrop.legible(ink, floor: floor, lightInk: lightInk) }
        var palette = self
        palette.title = fit(title, SidebarContrast.text)
        palette.secondaryText = fit(secondaryText, SidebarContrast.text)
        palette.tertiaryText = fit(tertiaryText, SidebarContrast.glyph)
        palette.glyph = fit(glyph, SidebarContrast.glyph)
        palette.accent = fit(accent, SidebarContrast.glyph)
        return palette
    }
}

public extension SpaceThemeRoles {
    /// The chrome for `theme`'s sidebar in one appearance: the ink side the
    /// backdrop prefers, each role fitted to its floor there.
    static func sidebarChrome(theme: SpaceTheme, windowDark: Bool) -> (lightInk: Bool, chrome: ThemeChromePalette) {
        let backdrop = SidebarBackdrop(theme: theme, dark: windowDark)
        let lightInk = backdrop.prefersLightInk
        return (lightInk, SpaceThemeRoles(theme: theme).chrome(dark: lightInk).legible(on: backdrop, lightInk: lightInk))
    }
}

/// The selected and hovered rows: the theme's `backgroundExtra` washed over
/// the sidebar (near-white in the light roles, a dark veil in the dark ones).
public enum SidebarRowWash {
    public static func selectedAlpha(lightInk: Bool) -> Double { lightInk ? 0.16 : 0.92 }
    public static func hoverAlpha(lightInk: Bool) -> Double { lightInk ? 0.08 : 0.42 }

    /// The other rows of a multi-row selection (`SidebarMultiSelection`):
    /// the way Arc greys them, a veil over the sidebar (#D1CBC8 on #E9E4E0,
    /// about 10 % black, 2026-11-11 recording), unlike the active row's pill
    /// and the hover wash. The veil is of the ink's own side (black under
    /// dark ink, white under light ink), so the title is fitted again on it.
    /// Where even black or white cannot read on it, the row takes a veil of
    /// the other side instead, which only adds contrast.
    public struct MultiSelected: Equatable, Sendable {
        public var veil: SpaceColor
        public var alpha: Double
        /// The row's title, moved only as far as its floor needs.
        public var title: SpaceColor
    }

    public static let multiSelectedAlpha = 0.10
    /// The other side's veil, where the ink's own cannot keep the title legible.
    public static let multiSelectedFallbackAlpha = 0.22

    /// On `theme`'s sidebar, sampled finely: the veil can take a title to
    /// its floor, so the fit must see the lightest and darkest spots.
    public static func multiSelected(title: SpaceColor, theme: SpaceTheme, windowDark: Bool, lightInk: Bool) -> MultiSelected {
        multiSelected(title: title, backdrop: SidebarBackdrop(theme: theme, dark: windowDark, rows: 20, columns: 10), lightInk: lightInk)
    }

    public static func multiSelected(title: SpaceColor, backdrop: SidebarBackdrop, lightInk: Bool) -> MultiSelected {
        func veiled(_ veil: SpaceColor, _ alpha: Double) -> SidebarBackdrop {
            SidebarBackdrop(darkest: backdrop.darkest.mixed(with: veil, fraction: alpha),
                            lightest: backdrop.lightest.mixed(with: veil, fraction: alpha))
        }
        let own: SpaceColor = lightInk ? .white : .black
        let row = veiled(own, multiSelectedAlpha)
        let fitted = row.legible(title, floor: SidebarContrast.text, lightInk: lightInk)
        if row.contrast(of: fitted, lightInk: lightInk) >= SidebarContrast.text {
            return MultiSelected(veil: own, alpha: multiSelectedAlpha, title: fitted)
        }
        return MultiSelected(veil: lightInk ? .black : .white, alpha: multiSelectedFallbackAlpha, title: title)
    }
}

public extension SpaceTexture {
    /// The tile's mean grey and alpha (`ThemeTextureGenerator`'s targets).
    var meanTexel: SpaceColor {
        let grey: Double = switch self {
        case .grain: 0.73
        case .sand: 0.66
        case .denim: 0.84
        case .tweed: 0.71
        }
        return SpaceColor(red: grey, green: grey, blue: grey)
    }

    var meanAlpha: Double { self == .grain ? 0.26 : 1 }
}

public extension SpaceColor {
    /// WCAG 2 relative luminance of the clamped colour.
    var luminance: Double { PageColor(red: clamped.red, green: clamped.green, blue: clamped.blue).luminance }

    /// WCAG contrast ratio against another colour.
    func contrast(with other: SpaceColor) -> Double {
        let (a, b) = (luminance + 0.05, other.luminance + 0.05)
        return max(a, b) / min(a, b)
    }
}
