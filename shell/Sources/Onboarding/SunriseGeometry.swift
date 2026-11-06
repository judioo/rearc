import CoreGraphics
import Foundation

/// Where the ReArc "Sunrise" mark sits on a canvas, in the construction of
/// brand/CONCEPTS.md §4: a 1024-unit grid, arch circle r 380 centred at
/// (512, 900) with a 130-unit stroke, sun r 225 at (512, 480).
public struct MarkLayout: Equatable, Sendable {
    public let size: CGSize
    /// Canvas points per grid unit.
    public let scale: CGFloat
    /// Canvas point of the grid's visual centre, (512, 493).
    public let origin: CGPoint

    public init(size: CGSize) {
        self.size = size
        // The mark is 476 units tall (sun top 255 to cap bottom 731) and
        // 730 wide (caps included).
        scale = min(size.height * 0.30 / 476, size.width * 0.42 / 730)
        origin = CGPoint(x: size.width / 2, y: size.height * 0.43)
    }

    public func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (x - 512) * scale, y: origin.y + (y - 493) * scale)
    }

    public var archCenter: CGPoint { point(512, 900) }
    public var archRadius: CGFloat { 380 * scale }
    public var archWidth: CGFloat { 130 * scale }
    public var archTop: CGFloat { archCenter.y - archRadius }
    public var sunCenter: CGPoint { point(512, 480) }
    public var sunRadius: CGFloat { 225 * scale }
    /// Bottom of the arch's round caps.
    public var markBottom: CGFloat { point(0, 731).y }
    /// The sun's centre lies on this circle around the arch centre (r 420).
    public var sunOrbit: CGFloat { 420 * scale }
}

/// Angles in degrees on the canvas (y down, so -90 is straight up).
public enum MarkAngles {
    public static let navy: ClosedRange<Double> = -142.0 ... -94.0
    public static let blue: ClosedRange<Double> = -104.0 ... -38.0
    public static let halfSpan: Double = 52
}

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public func mix(_ other: RGBA, _ p: Double) -> RGBA {
        RGBA(Ease.mix(r, other.r, p), Ease.mix(g, other.g, p), Ease.mix(b, other.b, p), Ease.mix(a, other.a, p))
    }
    public func alpha(_ a: Double) -> RGBA { RGBA(r, g, b, self.a * a) }
}

public enum MarkPalette {
    public static let sun = RGBA(hex: 0xFF5B3A)
    public static let sunCore = RGBA(hex: 0xFF9A6E)
    public static let navy = RGBA(hex: 0x190C99)
    public static let blue = RGBA(hex: 0x2740FF)
    public static let deep = RGBA(hex: 0x1627C8)
    /// The hairline horizon and the sun's trail before they take the mark's colours.
    public static let light = RGBA(hex: 0xFFEBDC, alpha: 0.96)
    public static let silhouette = RGBA(hex: 0x05060F)
    public static let ink = RGBA(hex: 0x1D2160)
}

/// The sky from night (0) through blue hour and golden hour to morning (1).
public enum SkyPalette {
    struct Stop { let at: Double; let top, mid, bottom: RGBA }
    static let stops: [Stop] = [
        Stop(at: 0.00, top: RGBA(hex: 0x020309), mid: RGBA(hex: 0x05071A), bottom: RGBA(hex: 0x0A0E2E)),
        Stop(at: 0.30, top: RGBA(hex: 0x080D33), mid: RGBA(hex: 0x1D2366), bottom: RGBA(hex: 0x553F86)),
        Stop(at: 0.62, top: RGBA(hex: 0x3443A6), mid: RGBA(hex: 0xC9708A), bottom: RGBA(hex: 0xFFA877)),
        Stop(at: 1.00, top: RGBA(hex: 0xD9E0FF), mid: RGBA(hex: 0xFFF0E8), bottom: RGBA(hex: 0xFFD9C4)),
    ]

    public static func colors(_ dawn: Double) -> (top: RGBA, mid: RGBA, bottom: RGBA) {
        let d = min(max(dawn, 0), 1)
        for i in 1 ..< stops.count where d <= stops[i].at {
            let a = stops[i - 1], b = stops[i]
            let p = Ease.smooth((d - a.at) / (b.at - a.at))
            return (a.top.mix(b.top, p), a.mid.mix(b.mid, p), a.bottom.mix(b.bottom, p))
        }
        let last = stops[stops.count - 1]
        return (last.top, last.mid, last.bottom)
    }
}

public enum Ease {
    /// 0 before `a`, 1 after `b`, linear between.
    public static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double {
        if t <= a { return 0 }
        if t >= b { return 1 }
        return (t - a) / (b - a)
    }
    /// Exact at both ends, so a finished animation lands on its target.
    public static func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a * (1 - p) + b * p }
    public static func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a * CGFloat(1 - p) + b * CGFloat(p) }
    public static func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }
    public static func smooth(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
    public static func inOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    public static func out(_ x: Double) -> Double { let x = min(max(x, 0), 1); return 1 - pow(1 - x, 3) }
    public static func inOutSine(_ x: Double) -> Double { let x = min(max(x, 0), 1); return -(cos(.pi * x) - 1) / 2 }
    /// A soft bump peaking at `center`, `width` seconds wide.
    public static func bump(_ t: Double, _ center: Double, _ width: Double) -> Double {
        let x = (t - center) / (width / 2)
        return abs(x) >= 1 ? 0 : 0.5 * (1 + cos(.pi * x))
    }
}
