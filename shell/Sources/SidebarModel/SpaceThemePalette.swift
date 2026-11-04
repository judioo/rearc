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

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The window colours one space theme expands to (Arc `WindowTheme`,
/// `BlendedSingleColor`, SIDEBAR-SPEC §4.8): a vertical gradient behind the
/// sidebar and around the page, and whether text on it should be light. Arc
/// computes its blend at runtime (DESIGN-TOKENS §2.1, values UN); these
/// ratios are ReArc's: bold in light mode, deep in dark mode.
public struct SpaceThemePalette: Equatable, Sendable {
    public var top: SpaceTheme
    public var bottom: SpaceTheme
    /// The accent used for selection and icons on this background.
    public var accent: SpaceTheme

    public init(top: SpaceTheme, bottom: SpaceTheme, accent: SpaceTheme) {
        self.top = top
        self.bottom = bottom
        self.accent = accent
    }

    public init(theme: SpaceTheme, darkAppearance: Bool) {
        if darkAppearance {
            top = theme.mixed(with: .black, fraction: 0.52)
            bottom = theme.mixed(with: .black, fraction: 0.68)
        } else {
            top = theme.mixed(with: .white, fraction: 0.42)
            bottom = theme.mixed(with: .white, fraction: 0.22)
        }
        accent = theme
    }

    /// Light (white) sidebar text reads better on this background.
    public var prefersLightForeground: Bool {
        top.mixed(with: bottom, fraction: 0.5).relativeLuminance < 0.36
    }

    /// The palette part-way to `other`, for a swipe between two spaces.
    public func mixed(with other: SpaceThemePalette, fraction: Double) -> SpaceThemePalette {
        SpaceThemePalette(
            top: top.mixed(with: other.top, fraction: fraction),
            bottom: bottom.mixed(with: other.bottom, fraction: fraction),
            accent: accent.mixed(with: other.accent, fraction: fraction)
        )
    }
}
