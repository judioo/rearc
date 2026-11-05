import Foundation

/// A colour in HSB (hue in degrees, saturation and brightness 0…1), the
/// space Arc's colour pad works in (ARC-RECORDING-ANALYSIS.md §2.3: the
/// fit is 4° rms against HSB hue and 11° against OKLCH hue).
public struct HSBColor: Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = ThemeColorPad.Point.normalised(hue)
        self.saturation = min(max(saturation, 0), 1)
        self.brightness = min(max(brightness, 0), 1)
    }

    public init(_ color: SpaceColor) {
        let c = color.clamped
        let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            switch high {
            case c.red: hue = 60 * ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6)
            case c.green: hue = 60 * ((c.blue - c.red) / delta + 2)
            default: hue = 60 * ((c.red - c.green) / delta + 4)
            }
        }
        self.init(hue: hue, saturation: high > 0 ? delta / high : 0, brightness: high)
    }

    public var color: SpaceColor {
        let h = hue / 60, c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = brightness - c
        return SpaceColor(red: r + m, green: g + m, blue: b + m)
    }
}

/// The theme editor's colour pad (Arc `SpaceStyleColorPadView` / `PadWheel`),
/// as the user's recording measured it (ARC-RECORDING-ANALYSIS.md §2.3–§2.4):
///
/// - A point's **screen angle round the centre is HSB hue**: red at 3 o'clock,
///   increasing clockwise (yellow ≈ 5, green ≈ 7, cyan 9, blue ≈ 11).
/// - Its **distance from the centre lowers saturation**, S = min(1, 1.15 − 2r)
///   with r in pad widths. The centre is the vivid end and the rim pastel.
/// - Brightness is not on the pad (≈ 0.95). A stored colour keeps its own
///   brightness, so a dark preset stays dark when its handle moves.
/// - + adds the complement; a second + splits it into +150° / +210°.
///   Dragging any handle turns and scales the whole set together.
public enum ThemeColorPad {
    /// A handle: its screen angle in degrees, clockwise from 3 o'clock, and
    /// its distance from the centre in pad widths (0 … `maxRadius`).
    public struct Point: Hashable, Sendable {
        public var angle: Double
        public var radius: Double

        public init(angle: Double, radius: Double) {
            self.angle = Self.normalised(angle)
            self.radius = min(max(radius.isFinite ? radius : 0, 0), ThemeColorPad.maxRadius)
        }

        static func normalised(_ degrees: Double) -> Double {
            guard degrees.isFinite else { return 0 }
            let value = degrees.truncatingRemainder(dividingBy: 360)
            return value < 0 ? value + 360 : value
        }

        /// Offset from the pad's centre in pad widths, y down (screen).
        public var offset: (x: Double, y: Double) {
            let theta = angle * .pi / 180
            return (radius * cos(theta), radius * sin(theta))
        }

        /// The point at a screen offset from the centre in pad widths, y down.
        public init(offsetX x: Double, y: Double) {
            self.init(angle: atan2(y, x) * 180 / .pi, radius: (x * x + y * y).squareRoot())
        }
    }

    /// The inscribed circle; no handle in the recording went past r 0.42.
    public static let maxRadius = 0.5
    /// S = min(1, saturationAtCentre − saturationSlope · r).
    public static let saturationAtCentre = 1.15
    public static let saturationSlope = 2.0
    /// The pad's own brightness (measured 0.89–0.96).
    public static let brightness = 0.95

    public static func saturation(atRadius radius: Double) -> Double {
        min(1, max(0, saturationAtCentre - saturationSlope * radius))
    }

    /// The radius whose saturation is `saturation` (fully saturated colours
    /// sit where S first reaches 1).
    public static func radius(forSaturation saturation: Double) -> Double {
        min(max((saturationAtCentre - min(max(saturation, 0), 1)) / saturationSlope, 0), maxRadius)
    }

    /// The colour at `point`, at `brightness` (the pad's own by default).
    public static func color(at point: Point, brightness: Double = ThemeColorPad.brightness) -> SpaceColor {
        HSBColor(hue: point.angle, saturation: saturation(atRadius: point.radius), brightness: brightness).color
    }

    /// Where `color`'s handle sits: its hue and saturation. Its brightness is
    /// not on the pad (Arc puts a preset's handle only by hue and saturation).
    public static func point(of color: SpaceColor) -> Point {
        let hsb = HSBColor(color)
        return Point(angle: hsb.hue, radius: radius(forSaturation: hsb.saturation))
    }

    // MARK: Stops

    /// + : one colour gains its complement (+180°, same radius); two split
    /// the complement into +150° and +210° (frames 803→804, 1124→1128).
    public static func adding(to points: [Point]) -> [Point] {
        guard let base = points.first else { return points }
        switch points.count {
        case 1: return [base, Point(angle: base.angle + 180, radius: base.radius)]
        case 2: return [base, Point(angle: base.angle + 150, radius: base.radius),
                        Point(angle: base.angle + 210, radius: base.radius)]
        default: return points
        }
    }

    /// − : the reverse of +. The recording never used it, so this is inferred.
    public static func removing(from points: [Point]) -> [Point] {
        guard let base = points.first else { return points }
        switch points.count {
        case 3: return [base, Point(angle: base.angle + 180, radius: base.radius)]
        case 2: return [base]
        default: return points
        }
    }

    /// Handle `index` moved to `target`: every handle turns by the same angle
    /// and scales its radius by the same factor, so the set moves rigidly
    /// (frames 825–832, 1141–1150). Dragging a secondary drags colour 1 too.
    public static func dragging(_ points: [Point], handle index: Int, to target: Point) -> [Point] {
        guard points.indices.contains(index) else { return points }
        let old = points[index]
        let turn = target.angle - old.angle
        let scale = old.radius > 0.005 ? target.radius / old.radius : nil
        return points.enumerated().map { offset, point in
            if offset == index { return target }
            return Point(angle: point.angle + turn, radius: scale.map { point.radius * $0 } ?? target.radius)
        }
    }

    // MARK: Themes

    /// A space on Arc's built-in theme has no colour yet: the pad is empty
    /// and says "Tap to pick a color for this space".
    public static func isUnset(_ theme: SpaceTheme) -> Bool {
        theme.stops.map(\.spaceColor) == SpaceTheme.arcDefault.stops.map(\.spaceColor)
    }

    /// The theme's handles, colour 1 first (none on the built-in theme).
    public static func points(of theme: SpaceTheme) -> [Point] {
        isUnset(theme) ? [] : theme.stops.map { point(of: $0.spaceColor) }
    }

    /// `theme` with its colours set from `points`, the rest of its style
    /// kept. A handle that did not move keeps its colour exactly (a pale
    /// preset can sit past the rim's saturation). A moved one keeps its own
    /// brightness; new colours take colour 1's, or the pad's own on the
    /// built-in theme.
    public static func theme(_ theme: SpaceTheme, with points: [Point]) -> SpaceTheme {
        guard !points.isEmpty else { return theme }
        let unset = isUnset(theme)
        let old = unset ? [] : theme.stops.map(\.spaceColor)
        let baseBrightness = old.first.map { HSBColor($0).brightness } ?? brightness
        let colors = points.prefix(SpaceTheme.maxGradientColors).enumerated().map { index, point -> SpaceColor in
            guard old.indices.contains(index) else { return color(at: point, brightness: baseBrightness) }
            if Self.point(of: old[index]) == point { return old[index] }
            return color(at: point, brightness: HSBColor(old[index]).brightness)
        }
        var next = theme.withBaseColor(SpaceTheme(red: colors[0].red, green: colors[0].green, blue: colors[0].blue))
        next.gradientColors = Array(colors.dropFirst())
        return next
    }

    /// A preset swatch: the theme reset to that one colour, exactly.
    public static func theme(_ theme: SpaceTheme, preset: SpaceTheme) -> SpaceTheme {
        var next = theme.withBaseColor(preset.baseColor)
        next.gradientColors = []
        return next
    }
}
