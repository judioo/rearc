import Foundation

/// One captured frame of the target window: 8-bit BGRA, rows top to bottom.
/// Frames live in memory only; the harness keeps numbers, not pixels
/// (docs/ARC-VS-REARC-BENCH.md §Privacy).
public struct Frame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) {
        precondition(bytesPerRow >= width * 4 && pixels.count >= bytesPerRow * height, "frame buffer too small")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// A frame of one colour (tests and synthetic sequences).
    public static func solid(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) -> Frame {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = b
            pixels[index + 1] = g
            pixels[index + 2] = r
        }
        return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
    }

    /// Paints `rect` (pixels, clipped) one colour.
    public mutating func fill(x: Range<Int>, y: Range<Int>, b: UInt8, g: UInt8, r: UInt8) {
        for row in max(0, y.lowerBound) ..< min(height, y.upperBound) {
            for column in max(0, x.lowerBound) ..< min(width, x.upperBound) {
                let index = row * bytesPerRow + column * 4
                pixels[index] = b
                pixels[index + 1] = g
                pixels[index + 2] = r
            }
        }
    }
}

/// A part of the window as fractions of its width and height, origin top left.
public struct Region: Equatable, Codable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public static let window = Region(x0: 0, y0: 0, x1: 1, y1: 1)
    /// The sidebar column (leading edge), `fraction` of the window wide.
    public static func sidebar(_ fraction: Double) -> Region { Region(x0: 0, y0: 0, x1: fraction, y1: 1) }
    /// Everything right of the sidebar column: the page card.
    public static func content(_ fraction: Double) -> Region { Region(x0: fraction, y0: 0, x1: 1, y1: 1) }

    /// `window`, `sidebar`, `content` or `x0,y0,x1,y1` (fractions, x0 < x1, y0 < y1).
    public static func parse(_ text: String, sidebarFraction: Double) -> Region? {
        switch text {
        case "window": return .window
        case "sidebar": return .sidebar(sidebarFraction)
        case "content": return .content(sidebarFraction)
        default:
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts.allSatisfy({ (0 ... 1).contains($0) }), parts[0] < parts[2], parts[1] < parts[3] else {
                return nil
            }
            return Region(x0: parts[0], y0: parts[1], x1: parts[2], y1: parts[3])
        }
    }

    /// Pixel ranges of this region in a `width` × `height` frame (never empty for a non-empty frame).
    public func pixelRanges(width: Int, height: Int) -> (x: Range<Int>, y: Range<Int>) {
        func range(_ a: Double, _ b: Double, _ size: Int) -> Range<Int> {
            let lower = min(size - 1, max(0, Int((a * Double(size)).rounded(.down))))
            let upper = max(lower + 1, min(size, Int((b * Double(size)).rounded(.up))))
            return lower ..< upper
        }
        return (range(x0, x1, width), range(y0, y1, height))
    }
}

/// When two frames count as different.
public struct DiffSettings: Equatable, Codable, Sendable {
    /// A pixel changed when its largest B, G or R difference exceeds this (0–255).
    public var channelThreshold: Int
    /// Compare every `stride`-th pixel in each direction.
    public var stride: Int
    /// Frames differ when more than this fraction of the compared pixels changed.
    public var areaThreshold: Double

    public init(channelThreshold: Int = 24, stride: Int = 2, areaThreshold: Double = 0.002) {
        self.channelThreshold = channelThreshold
        self.stride = max(1, stride)
        self.areaThreshold = areaThreshold
    }

    public func differs(_ fraction: Double) -> Bool { fraction > areaThreshold }
}

public enum FrameDiff {
    /// The fraction (0–1) of compared pixels in `region` whose largest
    /// channel difference exceeds `settings.channelThreshold`. Frames of
    /// different sizes (a resized window) count as wholly changed.
    public static func changedFraction(_ a: Frame, _ b: Frame, in region: Region = .window, settings: DiffSettings = DiffSettings()) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        guard a.width > 0, a.height > 0 else { return 0 }
        let (xs, ys) = region.pixelRanges(width: a.width, height: a.height)
        let step = settings.stride
        let threshold = settings.channelThreshold
        var compared = 0
        var changed = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                var row = ys.lowerBound
                while row < ys.upperBound {
                    let ra = row * a.bytesPerRow
                    let rb = row * b.bytesPerRow
                    var column = xs.lowerBound
                    while column < xs.upperBound {
                        let ia = ra + column * 4
                        let ib = rb + column * 4
                        let db = abs(Int(pa[ia]) - Int(pb[ib]))
                        let dg = abs(Int(pa[ia + 1]) - Int(pb[ib + 1]))
                        let dr = abs(Int(pa[ia + 2]) - Int(pb[ib + 2]))
                        if max(db, dg, dr) > threshold { changed += 1 }
                        compared += 1
                        column += step
                    }
                    row += step
                }
            }
        }
        return compared == 0 ? 0 : Double(changed) / Double(compared)
    }
}
