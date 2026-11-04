import Foundation

/// One window theme as Arc's Metal pass draws it (`gradientFragment`,
/// THEMES.md §3.2): a base gradient between colours 1 and 2 along the
/// top-left → bottom-right diagonal, reaching colour 2 at 75 % of the line;
/// colour 3 as a second gradient from clear along the other diagonal,
/// composited on top; both mixed in OKLab, scaled by the intensity and laid
/// over a light (or dark) underlay. `color(u:v:)` is the shader's per-pixel
/// formula, in UV space where (0, 0) is the top-left of the window.
public struct ThemeGradient: Hashable, Sendable {
    /// Colours 1 and 2 (one entry: a flat colour).
    public var base: [OKLab]
    /// Colour 3, faded in from clear along the overlay line.
    public var overlay: OKLab?
    /// `layer.alpha`, from the theme's intensity.
    public var alpha: Double
    /// Encoded sRGB, opaque.
    public var underlay: SpaceColor

    public static let baseStart = (u: 0.0, v: 0.0), baseEnd = (u: 1.0, v: 1.0)
    public static let overlayStart = (u: 1.0, v: 0.0), overlayEnd = (u: 0.0, v: 1.0)

    public init(base: [OKLab], overlay: OKLab?, alpha: Double, underlay: SpaceColor) {
        self.base = base.isEmpty ? [OKLab(SpaceColor.white)] : Array(base.prefix(2))
        self.overlay = overlay
        self.alpha = min(max(alpha, 0), 1)
        self.underlay = underlay
    }

    /// The theme in one appearance. Light draws the stops over white, as the
    /// shader does with `translucencyStyle: light`. Arc's dark treatment is
    /// not known (THEMES.md §8); ReArc darkens each stop to a third of its
    /// OKLab lightness, keeps (and lifts) its chroma so the hue survives, and
    /// lays it over the theme's dark `background` role instead of black.
    public init(theme: SpaceTheme, dark: Bool) {
        let stops = theme.stops.map { stop -> OKLab in
            let lab = stop.spaceColor.oklab
            return dark ? OKLab(l: lab.l * 0.33, a: lab.a * 1.4, b: lab.b * 1.4) : lab
        }
        self.init(
            base: Array(stops.prefix(2)),
            overlay: stops.count > 2 ? stops[2] : nil,
            alpha: theme.intensity,
            underlay: dark ? SpaceThemeRoles(theme: theme).dark.background : .white
        )
    }

    /// `tBase`: projection onto the base line, 0…1.
    static func baseT(u: Double, v: Double) -> Double {
        project(u: u, v: v, start: baseStart, end: baseEnd)
    }

    static func overlayT(u: Double, v: Double) -> Double {
        project(u: u, v: v, start: overlayStart, end: overlayEnd)
    }

    private static func project(u: Double, v: Double, start: (u: Double, v: Double), end: (u: Double, v: Double)) -> Double {
        let du = end.u - start.u, dv = end.v - start.v
        let lengthSquared = du * du + dv * dv
        guard lengthSquared > 0 else { return 0 }
        return min(max(((u - start.u) * du + (v - start.v) * dv) / lengthSquared, 0), 1)
    }

    /// The encoded sRGB colour at `(u, v)`, opaque (the underlay is).
    public func color(u: Double, v: Double) -> SpaceColor {
        // Base layer: colour 2 is reached at 75 % of the line (t · 4/3).
        let lab0 = base.count == 1 ? base[0] : base[0].mixed(with: base[1], fraction: min(Self.baseT(u: u, v: v) * 4 / 3, 1))
        var rgb = lab0.linear
        var a = alpha
        if let overlay {
            // Clear (OKLab 0, alpha 0) → colour 3, alpha mixed with it.
            let t = Self.overlayT(u: u, v: v)
            let c1 = OKLab(l: 0, a: 0, b: 0).mixed(with: overlay, fraction: t).linear
            let a0 = alpha, a1 = t * alpha
            a = a1 + a0 * (1 - a1)
            if a > 0 {
                rgb = LinearRGB(
                    red: (c1.red * a1 + rgb.red * a0 * (1 - a1)) / a,
                    green: (c1.green * a1 + rgb.green * a0 * (1 - a1)) / a,
                    blue: (c1.blue * a1 + rgb.blue * a0 * (1 - a1)) / a
                )
            }
        }
        // Over the underlay in encoded sRGB.
        let encoded = rgb.encoded
        return SpaceColor(
            red: encoded.red * a + underlay.red * (1 - a),
            green: encoded.green * a + underlay.green * (1 - a),
            blue: encoded.blue * a + underlay.blue * (1 - a)
        )
    }

    /// Opaque RGBA rows, top row first, sampled at pixel centres. The theme
    /// is defined in UV space, so one small render stretched to any window
    /// size is exact up to the interpolation between samples.
    public func rgba(width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0 ..< height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0 ..< width {
                let c = color(u: (Double(x) + 0.5) / Double(width), v: v)
                let i = (y * width + x) * 4
                pixels[i] = Float(c.red)
                pixels[i + 1] = Float(c.green)
                pixels[i + 2] = Float(c.blue)
            }
        }
        return pixels
    }

    /// Two rendered themes mixed per pixel (`layerCount == 2`, `progress`):
    /// a space switch dissolves one finished theme into the other (§3.7).
    public static func crossfade(_ from: SpaceColor, _ to: SpaceColor, progress: Double) -> SpaceColor {
        from.mixed(with: to, fraction: min(max(progress, 0), 1))
    }
}

/// The texture laid over a theme (`modifiers.overlay`, THEMES.md §3.3).
public enum SpaceTexture: String, Codable, CaseIterable, Sendable {
    case grain, sand, denim, tweed

    public var title: String { rawValue.capitalized }
}

/// The multiply blend Arc's `renderFragment` uses: the texture only ever
/// darkens. `texel` is the texture's grey and `alpha` its alpha times the
/// theme's grain amount.
public enum ThemeTextureBlend {
    public static func multiply(_ color: SpaceColor, texel: SpaceColor, alpha: Double) -> SpaceColor {
        SpaceColor(
            red: color.red * (1 + (texel.red - 1) * alpha),
            green: color.green * (1 + (texel.green - 1) * alpha),
            blue: color.blue * (1 + (texel.blue - 1) * alpha)
        )
    }
}

/// Procedural, tileable stand-ins for Arc's four textures, generated to the
/// statistics measured from Arc's bitmaps (THEMES.md §3.3; the bitmaps are
/// not shipped). Each tile is `side` × `side` pixels of grey + alpha.
public enum ThemeTextureGenerator {
    /// Interleaved grey (per channel) and alpha, 4 bytes a pixel.
    public static func rgba(_ texture: SpaceTexture, side: Int = 400) -> [UInt8] {
        var random = SplitMix(seed: 0xA7C0_5EED &+ UInt64(SpaceTexture.allCases.firstIndex(of: texture)!))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        func put(_ x: Int, _ y: Int, _ grey: Double, alpha: Double, jitter: Double = 0, random: inout SplitMix) {
            let i = (y * side + x) * 4
            let channels = [grey + jitter * random.signed(), grey + jitter * random.signed(), grey + jitter * random.signed()]
            for c in 0 ..< 3 { pixels[i + c] = UInt8((min(max(channels[c], 0), 1) * 255).rounded()) }
            pixels[i + 3] = UInt8((min(max(alpha, 0), 1) * 255).rounded())
        }
        switch texture {
        case .grain:
            // Fine noise: grey mean 0.73, SD 0.12, faint chroma, alpha mean 0.26.
            for y in 0 ..< side {
                for x in 0 ..< side {
                    put(x, y, 0.73 + 0.12 * random.gaussian(), alpha: 0.26 + 0.12 * random.gaussian(), jitter: 0.03, random: &random)
                }
            }
        case .sand:
            // Coarse speckle: mean 0.66, SD ≈ 0.17, opaque.
            let field = smoothNoise(side: side, cell: 3, random: &random)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    put(x, y, 0.66 + 0.2 * field[y * side + x] + 0.14 * random.gaussian(), alpha: 1, random: &random)
                }
            }
        case .denim:
            // Diagonal twill: mean 0.84, SD ≈ 0.04, opaque.
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let twill = sin(Double(x + y) * 2 * .pi / 8)
                    put(x, y, 0.84 + 0.035 * twill + 0.015 * random.gaussian(), alpha: 1, random: &random)
                }
            }
        case .tweed:
            // Woven cross-hatch: mean 0.71, SD ≈ 0.045, opaque.
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let warp = sin(Double(x) * 2 * .pi / 10), weft = sin(Double(y) * 2 * .pi / 10)
                    let weave = (x / 5 + y / 5) % 2 == 0 ? warp : weft
                    put(x, y, 0.71 + 0.04 * weave + 0.02 * random.gaussian(), alpha: 1, random: &random)
                }
            }
        }
        return pixels
    }

    /// Value noise in −1…1 on a `cell`-pixel lattice that wraps at `side`.
    static func smoothNoise(side: Int, cell: Int, random: inout SplitMix) -> [Double] {
        let lattice = max(side / cell, 1)
        let points = (0 ..< lattice * lattice).map { _ in random.signed() }
        var field = [Double](repeating: 0, count: side * side)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let fx = Double(x) / Double(cell), fy = Double(y) / Double(cell)
                let x0 = Int(fx) % lattice, y0 = Int(fy) % lattice
                let x1 = (x0 + 1) % lattice, y1 = (y0 + 1) % lattice
                let tx = fx - floor(fx), ty = fy - floor(fy)
                let top = points[y0 * lattice + x0] * (1 - tx) + points[y0 * lattice + x1] * tx
                let bottom = points[y1 * lattice + x0] * (1 - tx) + points[y1 * lattice + x1] * tx
                field[y * side + x] = top * (1 - ty) + bottom * ty
            }
        }
        return field
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func signed() -> Double { unit() * 2 - 1 }
        /// Approximately normal (Irwin–Hall, 4 terms), SD 1.
        mutating func gaussian() -> Double {
            (unit() + unit() + unit() + unit() - 2) * 1.7320508
        }
    }
}
