import CoreGraphics
import Foundation

/// How the onboarding lets go when the person chooses "Onboard later": the
/// act on screen steps back first, then the sky itself closes.
public enum SunriseClosing: String, CaseIterable, Sendable {
    /// The sun sinks behind the mark, the sky warms and dims to night, the
    /// stars come out, and the night lifts off the desktop.
    case sunset
    /// Everything gently fades away.
    case fade
    /// The sunrise plays backwards: the arch unbends into the horizon and the
    /// sun goes back under it, into the dark it rose from.
    case nightfall

    public var title: String {
        switch self {
        case .sunset: "Sunset"
        case .fade: "Fade"
        case .nightfall: "Nightfall"
        }
    }

    /// Seconds from "Onboard later" until the overlay is gone.
    public var duration: Double {
        switch self {
        case .sunset: 3.8
        case .fade: 1.5
        case .nightfall: 4.2
        }
    }

    /// Reduce Motion closes with the plain fade, whatever was chosen.
    public func resolved(reduced: Bool) -> SunriseClosing { reduced ? .fade : self }
}

/// Where a closing is: which one, how far through (0 to 1), and the Act 0
/// time it started from (Nightfall runs Act 0 back from there).
public struct SunriseClosingFrame: Equatable, Sendable {
    public var style: SunriseClosing
    public var progress: Double
    public var from: Double

    public init(style: SunriseClosing, progress: Double, from: Double) {
        self.style = style; self.progress = progress; self.from = from
    }

    /// The act's own drawing and controls are gone in the first part.
    public var actsOut: Double {
        Ease.smooth(Ease.progress(progress, 0, style == .fade ? 0.45 : 0.3))
    }

    /// The Act 0 time to draw: Nightfall winds it back to the dark.
    public func act0Time(_ time: Double) -> Double {
        style == .nightfall ? from * (1 - Ease.inOut(Ease.progress(progress, 0.05, 0.95))) : time
    }

    /// Act 0's frame, closing.
    public func apply(_ frame: SunriseFrame) -> SunriseFrame {
        var f = frame
        let p = progress
        switch style {
        case .sunset:
            let sink = Ease.inOut(Ease.progress(p, 0.08, 0.8))
            f.sun.center.y += f.sun.radius * 2.4 * sink
            f.sun.opacity *= 1 - Ease.smooth(Ease.progress(p, 0.42, 0.76))
            f.sun.glow *= 1 - sink
            f.arch.glow *= 1 - sink
            f.arch.rim *= 1 - sink
            f.lightReach = nil
            f.dawn *= 1 - Ease.inOut(Ease.progress(p, 0.22, 0.88))
            f.stars = max(f.stars, 0.85 * Ease.smooth(Ease.progress(p, 0.5, 0.92)))
            f.text *= 1 - actsOut
            f.veil *= 1 - Ease.smooth(Ease.progress(p, 0.74, 1))
        case .fade:
            f.text *= 1 - actsOut
            f.veil *= 1 - Ease.inOut(Ease.progress(p, 0.1, 1))
        case .nightfall:
            // The rewound frame ends at night with no veil; this only makes sure.
            f.veil *= 1 - Ease.smooth(Ease.progress(p, 0.88, 1))
        }
        f.button *= 1 - actsOut
        return f
    }

    /// What the closing sounds like, from `start` (scene time). The score
    /// fades under it over the closing's length.
    public static func hits(_ style: SunriseClosing, start s: Double) -> [SunriseScore.Hit] {
        switch style {
        case .sunset:
            // The light's notes, stepping down as the sun sinks: D5 A4 F#4 D4.
            return [(587.33, 0.018, 0.35), (440.0, 0.016, 0.15), (369.99, 0.014, -0.1), (293.66, 0.013, -0.35)]
                .enumerated().map { k, n in SunriseScore.Hit(s + 0.15 + Double(k) * 0.42, n.0, n.1, pan: n.2) }
                + [SunriseScore.Hit(s + 2.1, 146.83, 0.012, .pluck)]
        case .fade:
            return [SunriseScore.Hit(s + 0.05, 880.0, 0.01, pan: 0.15, .glass),
                    SunriseScore.Hit(s + 0.3, 587.33, 0.012, pan: -0.1)]
        case .nightfall:
            // The chime that formed the mark, in reverse, then the stars coming back.
            let stars = [2349.32, 1975.53, 1760.0, 1479.98, 1318.51]
            return [SunriseScore.Hit(s + 0.1, 1318.5, 0.03, pan: 0.3), SunriseScore.Hit(s + 0.32, 880.0, 0.04, pan: -0.25)]
                + stars.enumerated().map { k, f in
                    SunriseScore.Hit(s + 1.6 + Double(k) * 0.37, f, 0.01, pan: Double(k) * 0.4 - 0.8, .glass)
                }
        }
    }
}
