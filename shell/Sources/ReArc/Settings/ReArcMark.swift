import AppKit
import SwiftUI

/// ReArc's sunrise mark (brand/logo.svg, brand/logo-mono.svg) as paths: the
/// sun above the horizon circle and the two strokes of the arc in front of
/// it. In the SVGs' 512 pt box; `paths(in:)` scales them to a rect.
enum ReArcMark {
    struct Paths {
        var sun: CGPath
        var navy: CGPath
        var blue: CGPath
        /// Where the blue stroke passes under the navy one (drawn deeper).
        var deep: CGPath
        /// One shape for a single colour: the sun with a gap round the arc.
        var mono: CGPath
    }

    static let sunColor = Color(red: 1, green: 0x5B / 255, blue: 0x3A / 255)
    static let navyColor = Color(red: 0x19 / 255, green: 0x0C / 255, blue: 0x99 / 255)
    static let blueColor = Color(red: 0x27 / 255, green: 0x40 / 255, blue: 1)
    static let deepColor = Color(red: 0x16 / 255, green: 0x27 / 255, blue: 0xC8 / 255)

    /// `translate(256 256) scale(0.64) translate(-512 -493)` in a 512 box.
    private static func base() -> Paths {
        let horizon = CGPoint(x: 512, y: 900)
        func arc(from start: CGPoint, to end: CGPoint) -> CGPath {
            let path = CGMutablePath()
            let a0 = atan2(start.y - horizon.y, start.x - horizon.x)
            let a1 = atan2(end.y - horizon.y, end.x - horizon.x)
            path.addArc(center: horizon, radius: 380, startAngle: a0, endAngle: a1, clockwise: false)
            return path
        }
        let navyArc = arc(from: CGPoint(x: 212.6, y: 666), to: CGPoint(x: 485.5, y: 520.9))
        let blueArc = arc(from: CGPoint(x: 420.1, y: 531.3), to: CGPoint(x: 811.4, y: 666))
        let stroke = { (path: CGPath, width: CGFloat) in
            path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let sunDisc = CGPath(ellipseIn: CGRect(x: 512 - 225, y: 480 - 225, width: 450, height: 450), transform: nil)
        let horizonDisc = CGPath(ellipseIn: CGRect(x: 512 - 380, y: 900 - 380, width: 760, height: 760), transform: nil)
        let sun = sunDisc.subtracting(horizonDisc)
        let navy = stroke(navyArc, 130)
        let blue = stroke(blueArc, 130)
        let gap = stroke(navyArc, 226).union(stroke(blueArc, 226))
        let mono = sun.subtracting(gap).union(navy).union(blue)
        var transform = CGAffineTransform(translationX: 256, y: 256).scaledBy(x: 0.64, y: 0.64).translatedBy(x: -512, y: -493)
        func moved(_ path: CGPath) -> CGPath { path.copy(using: &transform) ?? path }
        return Paths(sun: moved(sun), navy: moved(navy), blue: moved(blue), deep: moved(blue.intersection(navy)), mono: moved(mono))
    }

    private static let unit = base()

    /// The mark fitted to `rect` (the SVG's 512 box, its own margins kept).
    static func paths(in rect: CGRect) -> Paths {
        let scale = min(rect.width, rect.height) / 512
        var transform = CGAffineTransform(translationX: rect.midX - 256 * scale, y: rect.midY - 256 * scale).scaledBy(x: scale, y: scale)
        func moved(_ path: CGPath) -> CGPath { path.copy(using: &transform) ?? path }
        return Paths(sun: moved(unit.sun), navy: moved(unit.navy), blue: moved(unit.blue), deep: moved(unit.deep), mono: moved(unit.mono))
    }

    /// The Icon toolbar item's glyph: the mark redrawn in line, like the SF
    /// Symbols beside it: the sun's ring rising behind the horizon's arc, with
    /// the mark's gap between them. In a 20 pt box.
    static func glyphPath() -> CGPath {
        let horizon = CGPoint(x: 10, y: 21.5), radius: CGFloat = 11, gap: CGFloat = 2
        let arc = CGMutablePath()
        arc.addArc(center: horizon, radius: radius, startAngle: -152 * .pi / 180, endAngle: -28 * .pi / 180, clockwise: false)
        let sun = CGPath(ellipseIn: CGRect(x: 10 - 4.4, y: 7.6 - 4.4, width: 8.8, height: 8.8), transform: nil)
            .copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 4)
        let clearance = CGPath(ellipseIn: CGRect(x: horizon.x - radius - gap, y: horizon.y - radius - gap,
                                                 width: 2 * (radius + gap), height: 2 * (radius + gap)), transform: nil)
        return sun.subtracting(clearance).union(arc.copy(strokingWithWidth: 1.8, lineCap: .round, lineJoin: .round, miterLimit: 4))
    }

    static func templateImage(pointSize: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 20, y: rect.height / 20)
            context.addPath(glyphPath())
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Icon"
        return image
    }
}

/// The colour mark in SwiftUI (the card's wordmark).
struct ReArcMarkView: View {
    var body: some View {
        Canvas { context, size in
            let paths = ReArcMark.paths(in: CGRect(origin: .zero, size: size))
            context.fill(Path(paths.sun), with: .color(ReArcMark.sunColor))
            context.fill(Path(paths.navy), with: .color(ReArcMark.navyColor))
            context.fill(Path(paths.blue), with: .color(ReArcMark.blueColor))
            context.fill(Path(paths.deep), with: .color(ReArcMark.deepColor))
        }
        .accessibilityHidden(true)
    }
}
