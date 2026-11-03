import CoreGraphics
import Foundation

/// Browser page zoom (1.0 = 100%), shared by both engines. Chromium's range
/// is [0.25, 5.0] (C-ABI.md "Page zoom"); the presets match Chrome's menu steps.
enum PageZoom {
    static let range: ClosedRange<Double> = 0.25...5.0
    static let presets: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
    /// Factors closer than this are the same preset (engines round-trip through zoom levels).
    static let tolerance = 0.005

    enum Step {
        case zoomIn, zoomOut, reset
    }

    static func isValid(_ factor: Double) -> Bool {
        factor.isFinite && range.contains(factor)
    }

    static func isDefault(_ factor: Double) -> Bool {
        abs(factor - 1.0) < tolerance
    }

    /// The next preset strictly above (zoomIn) or below (zoomOut) `current`; reset is 1.0.
    static func factor(after step: Step, from current: Double) -> Double {
        let base = isValid(current) ? current : 1.0
        switch step {
        case .reset:
            return 1.0
        case .zoomIn:
            return presets.first { $0 > base + tolerance } ?? range.upperBound
        case .zoomOut:
            return presets.last { $0 < base - tolerance } ?? range.lowerBound
        }
    }

    static func percent(_ factor: Double) -> Int {
        Int((factor * 100).rounded())
    }

    /// View points (DIPs, top-left origin) to the page's viewport CSS pixels.
    static func cssPoint(fromViewPoint point: CGPoint, zoom factor: Double) -> CGPoint {
        let zoom = isValid(factor) ? factor : 1.0
        return CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    static func viewPoint(fromCSSPoint point: CGPoint, zoom factor: Double) -> CGPoint {
        let zoom = isValid(factor) ? factor : 1.0
        return CGPoint(x: point.x * zoom, y: point.y * zoom)
    }
}
