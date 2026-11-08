import Foundation

/// The colour the page card's toolbar strip and a split pane's row take from
/// the page, as in Arc: the page's `<meta name="theme-color">`, else the
/// colour along the top edge of what it shows (PAN Home declares none; Arc
/// still draws its strip in the site's black top bar). sRGB, 0…1.
public struct PageColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Chromium's SkColor (0xAARRGGBB). A translucent theme colour is drawn
    /// over white, as a page's own background would be.
    public init(argb: UInt32) {
        let alpha = Double((argb >> 24) & 0xFF) / 255
        func channel(_ shift: UInt32) -> Double {
            Double((argb >> shift) & 0xFF) / 255 * alpha + (1 - alpha)
        }
        self.init(red: channel(16), green: channel(8), blue: channel(0))
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// White text contrasts more than black: below about 0.179 luminance,
    /// where the two contrast ratios meet.
    public var prefersLightInk: Bool {
        let l = luminance
        return (1.05 / (l + 0.05)) > ((l + 0.05) / 0.05)
    }

    /// WCAG contrast ratio against another colour.
    public func contrast(with other: PageColor) -> Double {
        let (a, b) = (luminance + 0.05, other.luminance + 0.05)
        return max(a, b) / min(a, b)
    }

    public static let white = PageColor(red: 1, green: 1, blue: 1)
    public static let black = PageColor(red: 0, green: 0, blue: 0)
}

/// Settings › Advanced › "Match toolbar to website colours". On by default,
/// as Arc's toolbar follows the page.
public enum ToolbarPageColorPreference {
    public static let key = "rearc.matchToolbarToWebsite"
    public static let defaultValue = true

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Web pages have a colour; blank and internal pages keep the toolbar's own.
    public static func pageHasColor(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}

/// The top-edge fallback: the strip's one colour, when it has one.
public enum PageEdgeSample {
    /// Pixels must share a colour this much for the strip to have one; a
    /// photo or a busy header gives none, and the toolbar keeps its own look.
    public static let minimumShare = 0.5

    /// The most common colour of an RGBA8 strip (unpremultiplied or opaque),
    /// pixels bucketed to 4 bits a channel and the winning bucket averaged.
    /// Nil when no bucket holds `minimumShare` of the pixels or the strip is
    /// empty. Translucent pixels are drawn over white first.
    public static func dominantColor(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> PageColor? {
        guard width > 0, height > 0, bytesPerRow >= width * 4, rgba.count >= bytesPerRow * (height - 1) + width * 4 else {
            return nil
        }
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Double>](repeating: .zero, count: 4096)
        for y in 0 ..< height {
            var i = y * bytesPerRow
            for _ in 0 ..< width {
                let a = Double(rgba[i + 3]) / 255
                let pixel = SIMD3(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])) * a + SIMD3(repeating: 255 * (1 - a))
                let bucket = (Int(pixel.x) >> 4) << 8 | (Int(pixel.y) >> 4) << 4 | Int(pixel.z) >> 4
                counts[bucket] += 1
                sums[bucket] += pixel
                i += 4
            }
        }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }),
              Double(counts[best]) >= minimumShare * Double(width * height) else { return nil }
        let mean = sums[best] / Double(counts[best]) / 255
        return PageColor(red: mean.x, green: mean.y, blue: mean.z)
    }
}

/// What a page's toolbar colour is, from the two sources: its theme colour
/// wins; the sampled top edge is the fallback.
public struct PageToolbarColorState: Equatable, Sendable {
    public private(set) var themeColor: PageColor?
    public private(set) var edgeColor: PageColor?
    /// The document the edge colour was sampled from.
    public private(set) var edgeDocument: UInt64?
    public private(set) var document: UInt64 = 0

    public init() {}

    /// The toolbar's colour: the theme colour, else the last edge sample,
    /// kept across a navigation until the new page's sample replaces it, so a
    /// site's pages don't flash the default strip between them.
    public var color: PageColor? { themeColor ?? edgeColor }

    /// The page needs an edge sample: it declares no theme colour and this
    /// document has none yet.
    public var needsEdgeSample: Bool { themeColor == nil && edgeDocument != document }

    public mutating func documentChanged(to generation: UInt64) {
        document = generation
    }

    public mutating func setThemeColor(_ color: PageColor?) {
        themeColor = color
    }

    /// A sample of `document`; a stale one (an older document) is dropped.
    /// Nil: the strip had no one colour, so the toolbar keeps its own look.
    public mutating func setEdgeColor(_ color: PageColor?, document sampled: UInt64) {
        guard sampled == document else { return }
        edgeColor = color
        edgeDocument = sampled
    }

    /// A page with no colour of its own (blank, internal): the toolbar's own look.
    public mutating func clear() {
        themeColor = nil
        edgeColor = nil
        edgeDocument = document
    }
}

/// Glyphs and text on a page-coloured toolbar: white or black, whichever
/// contrasts more, at three strengths (the address and enabled glyphs, the
/// address's path and right-hand icons, disabled glyphs).
public struct PageColorInk: Equatable, Sendable {
    public let isLight: Bool

    public init(on background: PageColor) {
        isLight = background.prefersLightInk
    }

    public var base: PageColor { isLight ? .white : .black }
    public var inkOpacity: Double { isLight ? 0.9 : 0.72 }
    public var quietOpacity: Double { isLight ? 0.62 : 0.5 }
    public var disabledOpacity: Double { isLight ? 0.36 : 0.26 }

    /// The ink as drawn: `base` at `opacity` over the background.
    public func blended(_ opacity: Double, over background: PageColor) -> PageColor {
        func mix(_ a: Double, _ b: Double) -> Double { a * opacity + b * (1 - opacity) }
        return PageColor(red: mix(base.red, background.red), green: mix(base.green, background.green),
                         blue: mix(base.blue, background.blue))
    }
}
