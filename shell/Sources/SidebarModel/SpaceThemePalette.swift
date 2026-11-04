import Foundation

public extension SpaceTheme {
    static let white = SpaceTheme(red: 1, green: 1, blue: 1)
    static let black = SpaceTheme(red: 0, green: 0, blue: 0)

    /// Straight RGB interpolation toward `other` (0 keeps self, 1 is other).
    func mixed(with other: SpaceTheme, fraction: Double) -> SpaceTheme {
        let t = min(max(fraction, 0), 1)
        return SpaceTheme(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    /// The theme with stop `index` (0 is the base colour) set to `color`'s RGB.
    func settingStop(_ index: Int, to color: SpaceTheme) -> SpaceTheme {
        var theme = self
        if index == 0 {
            return withBaseColor(color)
        }
        guard gradientColors.indices.contains(index - 1) else { return self }
        theme.gradientColors[index - 1] = SpaceColor(red: color.red, green: color.green, blue: color.blue)
        return theme
    }

    /// One more stop, the last one turned 60° round the colour wheel; a
    /// theme with three stops is unchanged.
    func addingStop() -> SpaceTheme {
        guard stops.count < SpaceTheme.maxGradientColors, let last = stops.last else { return self }
        let next = last.rotatingHue(by: 1.0 / 6.0)
        var theme = self
        theme.gradientColors.append(SpaceColor(red: next.red, green: next.green, blue: next.blue))
        return theme
    }

    /// Without stop `index`; removing the base colour makes the next stop the base.
    func removingStop(_ index: Int) -> SpaceTheme {
        var remaining = stops
        guard remaining.count > 1, remaining.indices.contains(index) else { return self }
        remaining.remove(at: index)
        var theme = withBaseColor(remaining[0])
        theme.gradientColors = remaining.dropFirst().map { SpaceColor(red: $0.red, green: $0.green, blue: $0.blue) }
        return theme
    }

    /// The colour with its hue turned by `turns` (1 is a full turn).
    func rotatingHue(by turns: Double) -> SpaceTheme {
        let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
        guard delta > 0.0001 else { return self }
        var hue: Double
        if maxC == red { hue = (green - blue) / delta }
        else if maxC == green { hue = (blue - red) / delta + 2 }
        else { hue = (red - green) / delta + 4 }
        hue = (hue / 6 + turns).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        let saturation = delta / maxC, value = maxC
        let sector = hue * 6, f = sector - floor(sector)
        let p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f))
        switch Int(sector) % 6 {
        case 0: return SpaceTheme(red: value, green: t, blue: p)
        case 1: return SpaceTheme(red: q, green: value, blue: p)
        case 2: return SpaceTheme(red: p, green: value, blue: t)
        case 3: return SpaceTheme(red: p, green: q, blue: value)
        case 4: return SpaceTheme(red: t, green: p, blue: value)
        default: return SpaceTheme(red: value, green: p, blue: q)
        }
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The window colours one space theme expands to (Arc `WindowTheme`,
/// `BlendedSingleColor` / `BlendedGradient`, SIDEBAR-SPEC §4.8): the
/// gradient behind the sidebar and around the page, its grain, and whether
/// text on it should be light. Arc computes its blend at runtime
/// (DESIGN-TOKENS §2.1, values UN); these ratios are ReArc's: bold in light
/// mode, deep in dark mode. A single colour runs top to bottom from a lighter
/// to a deeper shade; a gradient runs through its stops corner to corner.
public struct SpaceThemePalette: Equatable, Sendable {
    /// Two or three colours, drawn in order.
    public var colors: [SpaceTheme]
    /// The accent used for selection and icons on this background.
    public var accent: SpaceTheme
    /// Grain over the background, 0 to 1.
    public var noise: Double
    /// True when `colors` runs corner to corner (a gradient theme).
    public var isDiagonal: Bool

    public var top: SpaceTheme { colors[0] }
    public var bottom: SpaceTheme { colors[colors.count - 1] }

    public init(top: SpaceTheme, bottom: SpaceTheme, accent: SpaceTheme, noise: Double = 0) {
        self.init(colors: [top, bottom], accent: accent, noise: noise, isDiagonal: false)
    }

    public init(colors: [SpaceTheme], accent: SpaceTheme, noise: Double, isDiagonal: Bool) {
        self.colors = colors.isEmpty ? [accent, accent] : (colors.count == 1 ? colors + colors : colors)
        self.accent = accent
        self.noise = noise
        self.isDiagonal = isDiagonal
    }

    /// `darkAppearance` is the window's resolved appearance (see
    /// `SpaceAppearance.isDark(systemDark:)`).
    public init(theme: SpaceTheme, darkAppearance: Bool) {
        let accent = theme.baseColor
        if theme.isGradient {
            let shade: (SpaceTheme) -> SpaceTheme = darkAppearance
                ? { $0.mixed(with: .black, fraction: 0.55) }
                : { $0.mixed(with: .white, fraction: 0.3) }
            self.init(colors: theme.stops.map(shade), accent: accent, noise: theme.noise, isDiagonal: true)
        } else if darkAppearance {
            self.init(colors: [accent.mixed(with: .black, fraction: 0.52), accent.mixed(with: .black, fraction: 0.68)],
                      accent: accent, noise: theme.noise, isDiagonal: false)
        } else {
            self.init(colors: [accent.mixed(with: .white, fraction: 0.42), accent.mixed(with: .white, fraction: 0.22)],
                      accent: accent, noise: theme.noise, isDiagonal: false)
        }
    }

    /// Light (white) sidebar text reads better on this background.
    public var prefersLightForeground: Bool {
        average.relativeLuminance < 0.36
    }

    /// The colours' straight average.
    public var average: SpaceTheme {
        let n = Double(colors.count)
        return SpaceTheme(
            red: colors.reduce(0) { $0 + $1.red } / n,
            green: colors.reduce(0) { $0 + $1.green } / n,
            blue: colors.reduce(0) { $0 + $1.blue } / n
        )
    }

    /// The colour at `position` (0...1) along the stops.
    public func color(at position: Double) -> SpaceTheme {
        let t = min(max(position, 0), 1) * Double(colors.count - 1)
        let index = min(Int(t), colors.count - 2)
        return colors[index].mixed(with: colors[index + 1], fraction: t - Double(index))
    }

    /// The palette part-way to `other`, for a swipe between two spaces. Both
    /// sides are sampled at the same stops, so a two-colour theme blends into
    /// a three-colour one.
    public func mixed(with other: SpaceThemePalette, fraction: Double) -> SpaceThemePalette {
        let count = max(colors.count, other.colors.count)
        let positions = (0 ..< count).map { Double($0) / Double(count - 1) }
        let t = min(max(fraction, 0), 1)
        if t == 0 { return self }
        if t == 1 { return other }
        return SpaceThemePalette(
            colors: positions.map { color(at: $0).mixed(with: other.color(at: $0), fraction: t) },
            accent: accent.mixed(with: other.accent, fraction: t),
            noise: noise + (other.noise - noise) * t,
            isDiagonal: t < 0.5 ? isDiagonal : other.isDiagonal
        )
    }
}
