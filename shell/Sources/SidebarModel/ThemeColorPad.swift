import Foundation

/// How extra theme colours follow colour 1 on the editor's pad (Arc
/// `wheel`: `analogous` in every stored theme, or `complimentary`).
public enum ThemeHarmony: String, Codable, CaseIterable, Sendable {
    case analogous, complementary

    public var title: String { self == .analogous ? "Analogous" : "Complementary" }

    /// Hue offsets of colours 2 and 3 from colour 1. Stored analogous themes
    /// sit 22–65° either side of colour 1 (THEMES.md §1.3); ReArc adds them
    /// at ±50°.
    public var offsets: [Double] {
        switch self {
        case .analogous: return [50, -50]
        case .complementary: return [180, 150]
        }
    }
}

/// The editor's colour pad (Arc `SpaceStyleColorPadView` / `PadWheel`): a
/// point's angle round the centre is OKLCH hue, its distance from the centre
/// trades lightness for chroma, from near-white at the centre to the most
/// vivid colour the gamut holds at the rim. Arc's exact mapping is not yet
/// observed (THEMES.md §8); this one spans the stored themes' range
/// (L 0.94 / C 0.01 to L 0.64 / C 0.23).
public enum ThemeColorPad {
    /// A point on the pad: hue in degrees (counter-clockwise from east) and
    /// radius 0 (centre) … 1 (rim).
    public struct Point: Hashable, Sendable {
        public var angle: Double
        public var radius: Double

        public init(angle: Double, radius: Double) {
            self.angle = Self.normalised(angle)
            self.radius = min(max(radius, 0), 1)
        }

        static func normalised(_ degrees: Double) -> Double {
            let value = degrees.truncatingRemainder(dividingBy: 360)
            return value < 0 ? value + 360 : value
        }
    }

    static let centreLightness = 0.965
    static let rimLightness = 0.66

    public static func lightness(atRadius radius: Double) -> Double {
        centreLightness + (rimLightness - centreLightness) * radius
    }

    /// The colour at `point`, inside sRGB.
    public static func color(at point: Point) -> SpaceColor {
        let l = lightness(atRadius: point.radius)
        let edge = OKLCH(l: l, c: 0, h: point.angle).maximumChroma(in: .sRGB)
        return OKLCH(l: l, c: edge * point.radius, h: point.angle).gamutMapped(to: .sRGB).lab.color.clamped
    }

    /// Where `color` sits: its hue, and the radius whose lightness is
    /// nearest its own (greys and dark swatches land on the nearest ring).
    public static func point(of color: SpaceColor) -> Point {
        let lch = color.oklab.lch
        let byLightness = (centreLightness - lch.l) / (centreLightness - rimLightness)
        return Point(angle: lch.c < 0.002 ? 0 : lch.h, radius: byLightness)
    }

    /// Colour 1 moved to `newBase`: the other colours keep their hue offsets
    /// and radii, as Arc's handles do (`ColorWheelDriven`).
    public static func dragBase(_ points: [Point], to newBase: Point) -> [Point] {
        guard let old = points.first else { return [newBase] }
        let turn = newBase.angle - old.angle
        return [newBase] + points.dropFirst().map { Point(angle: $0.angle + turn, radius: $0.radius) }
    }

    /// One more colour placed by `harmony` from colour 1; at most three.
    public static func adding(to points: [Point], harmony: ThemeHarmony) -> [Point] {
        guard let base = points.first, points.count < SpaceTheme.maxGradientColors else { return points }
        let offset = harmony.offsets[points.count - 1]
        return points + [Point(angle: base.angle + offset, radius: base.radius)]
    }

    /// `theme` with its stops set from `points` (the rest of its style kept).
    public static func theme(_ theme: SpaceTheme, with points: [Point]) -> SpaceTheme {
        let colors = points.prefix(SpaceTheme.maxGradientColors).map(color(at:))
        guard let first = colors.first else { return theme }
        var next = theme.withBaseColor(SpaceTheme(red: first.red, green: first.green, blue: first.blue))
        next.gradientColors = Array(colors.dropFirst())
        return next
    }
}
