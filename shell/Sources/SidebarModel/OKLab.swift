import Foundation

/// A colour in Björn Ottosson's OKLab space: `l` is perceived lightness
/// (0 black … 1 white), `a` and `b` the green–red and blue–yellow axes. Arc
/// uploads its gradient stops as OKLab and mixes them there
/// (THEMES.md §3.2), so a cyan → violet blend stays saturated instead of
/// going grey through the middle.
public struct OKLab: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From linear-light sRGB (components may fall outside 0…1).
    public init(linear rgb: LinearRGB) {
        let l = 0.4122214708 * rgb.red + 0.5363325363 * rgb.green + 0.0514459929 * rgb.blue
        let m = 0.2119034982 * rgb.red + 0.6806995451 * rgb.green + 0.1073969566 * rgb.blue
        let s = 0.0883024619 * rgb.red + 0.2817188376 * rgb.green + 0.6299787005 * rgb.blue
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        self.init(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// From an encoded (gamma) sRGB colour.
    public init(_ color: SpaceColor) {
        self.init(linear: LinearRGB(color))
    }

    /// The shader's `OKLabToLinearSRGB` (the standard matrices).
    public var linear: LinearRGB {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        return LinearRGB(
            red: 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            green: -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            blue: -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    /// Encoded sRGB; out-of-gamut components are kept (extended sRGB).
    public var color: SpaceColor { linear.encoded }

    /// Hue in degrees, 0…360.
    public var lch: OKLCH {
        let degrees = atan2(b, a) * 180 / .pi
        return OKLCH(l: l, c: (a * a + b * b).squareRoot(), h: degrees < 0 ? degrees + 360 : degrees)
    }

    /// Straight interpolation in OKLab (0 keeps self, 1 is `other`).
    public func mixed(with other: OKLab, fraction t: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    /// Euclidean distance, Arc's ΔE_OK (THEMES.md §3.5 tolerance).
    public func distance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

/// OKLab in polar form: lightness, chroma and hue in degrees.
public struct OKLCH: Hashable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    public var lab: OKLab {
        let radians = h * .pi / 180
        return OKLab(l: l, a: c * cos(radians), b: c * sin(radians))
    }

    /// The same lightness and hue with chroma cut until it fits `gamut`
    /// (a binary search on chroma, so hue and lightness never drift).
    public func gamutMapped(to gamut: ColorGamut) -> OKLCH {
        guard c > 0, !gamut.contains(lab) else { return self }
        var low = 0.0, high = c
        for _ in 0 ..< 24 {
            let mid = (low + high) / 2
            if gamut.contains(OKLCH(l: l, c: mid, h: h).lab) { low = mid } else { high = mid }
        }
        return OKLCH(l: l, c: low, h: h)
    }

    /// The most chroma `gamut` holds at this lightness and hue.
    public func maximumChroma(in gamut: ColorGamut) -> Double {
        OKLCH(l: l, c: 0.5, h: h).gamutMapped(to: gamut).c
    }
}

/// The RGB gamuts theme colours are fitted into. Arc stores its palettes as
/// extended sRGB that may reach Display P3 (THEMES.md §2.2).
public enum ColorGamut: Sendable {
    case sRGB
    case displayP3

    func contains(_ lab: OKLab) -> Bool {
        let rgb = lab.linear
        let tolerance = 1e-5
        switch self {
        case .sRGB:
            return [rgb.red, rgb.green, rgb.blue].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        case .displayP3:
            let p3 = rgb.displayP3
            return [p3.red, p3.green, p3.blue].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
        }
    }
}

/// Linear-light RGB (sRGB primaries).
public struct LinearRGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(_ color: SpaceColor) {
        self.init(red: Self.decode(color.red), green: Self.decode(color.green), blue: Self.decode(color.blue))
    }

    /// Back to encoded sRGB with the shader's piecewise curve (sign-preserving).
    public var encoded: SpaceColor {
        SpaceColor(red: Self.encode(red), green: Self.encode(green), blue: Self.encode(blue))
    }

    /// The same colour with Display P3 primaries (still linear).
    var displayP3: LinearRGB {
        LinearRGB(
            red: 0.8224621209 * red + 0.1775378791 * green,
            green: 0.0331941989 * red + 0.9668058011 * green,
            blue: 0.0170826307 * red + 0.0723974407 * green + 0.9105199286 * blue
        )
    }

    public static func decode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let linear = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -linear : linear
    }

    public static func encode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let encoded = magnitude <= 0.0031308 ? 12.92 * magnitude : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }
}

public extension SpaceColor {
    /// `#RRGGBB` (alpha is not part of `SpaceColor`).
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB`, clamped to 0…1 and rounded to bytes.
    var hex: String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var oklab: OKLab { OKLab(self) }

    /// Straight mix in encoded sRGB (0 keeps self, 1 is `other`). Arc's
    /// semantic roles are such mixes of its primary colours (THEMES.md §3.5).
    func mixed(with other: SpaceColor, fraction t: Double) -> SpaceColor {
        SpaceColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    /// Every component multiplied by `factor` (a mix toward black).
    func scaled(by factor: Double) -> SpaceColor {
        SpaceColor(red: red * factor, green: green * factor, blue: blue * factor)
    }

    static let white = SpaceColor(red: 1, green: 1, blue: 1)
    static let black = SpaceColor(red: 0, green: 0, blue: 0)
}
