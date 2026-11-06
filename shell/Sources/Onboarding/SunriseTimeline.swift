import CoreGraphics
import Foundation

/// Three takes on Act 0. All of them end on the same frame: the mark on a
/// morning sky, the one spoken line, and Begin.
public enum SunriseVariant: String, CaseIterable, Sendable {
    /// A hairline horizon draws across the dark, the sun rises behind it, and
    /// the horizon bends and thickens into the arch.
    case horizon
    /// Darkness and one breathing ember; its light spills out and finds the
    /// arch standing in front of it.
    case ember
    /// Stars; the sun climbs along an arc and leaves its path behind: navy for
    /// where it has been, blue for where it is going.
    case path

    public var title: String {
        switch self {
        case .horizon: "Horizon"
        case .ember: "Ember"
        case .path: "The Sun's Path"
        }
    }
}

/// Times (seconds from the start) the score and the voice follow.
public struct SunriseCues: Equatable, Sendable {
    public var chime: Double
    public var voice: Double
    public var text: Double
    public var button: Double
    /// Everything is at rest from here on.
    public var end: Double
    public var heartbeats: [Double] = []
    public var riser: ClosedRange<Double>?
    public var sparkles: Bool = false

    public static func of(_ variant: SunriseVariant) -> SunriseCues {
        switch variant {
        case .horizon:
            SunriseCues(chime: 7.0, voice: 9.3, text: 9.2, button: 10.4, end: 11.2, riser: 1.2 ... 3.8)
        case .ember:
            SunriseCues(chime: 7.6, voice: 9.3, text: 9.2, button: 10.4, end: 11.2,
                        heartbeats: [2.0, 3.2, 4.4], riser: 4.8 ... 7.6)
        case .path:
            SunriseCues(chime: 7.2, voice: 9.5, text: 9.4, button: 10.6, end: 11.4, sparkles: true)
        }
    }

    /// Reduce Motion: a crossfade from night to the final frame.
    public static let reduced = SunriseCues(chime: 2.6, voice: 3.0, text: 2.8, button: 3.6, end: 4.2)
}

public struct ArchState: Equatable {
    public var center: CGPoint
    public var radius: CGFloat
    public var width: CGFloat
    /// Drawn in `base` while `colorMix` is below 1.
    public var baseRanges: [ClosedRange<Double>]
    public var base: RGBA
    public var navy: ClosedRange<Double>?
    public var blue: ClosedRange<Double>?
    /// 0 is all `base`, 1 is the mark's navy, blue and overlap.
    public var colorMix: Double
    public var glow: Double
    /// Backlight along the arch's top edge.
    public var rim: Double
    public var opacity: Double
}

public struct SunState: Equatable {
    public var center: CGPoint
    public var radius: CGFloat
    public var glow: Double
    public var opacity: Double
}

public struct SunriseFrame: Equatable {
    /// How much of the scene covers the desktop.
    public var veil: Double
    public var dawn: Double
    /// When set, the dawn sky only shows inside this radius around the sun;
    /// outside it is still night.
    public var lightReach: CGFloat?
    public var stars: Double
    /// Dark ground inside the horizon circle, so the sun rises from behind something.
    public var ground: Double
    public var arch: ArchState
    public var sun: SunState
    public var text: Double
    public var button: Double
    /// The skip hint fades once there is nothing left to skip.
    public var skip: Double
}

public enum SunriseTimeline {
    public static func dawn(_ variant: SunriseVariant, _ t: Double, reduced: Bool = false) -> Double {
        if reduced { return Ease.smooth(Ease.progress(t, 1.0, 3.2)) }
        switch variant {
        case .horizon:
            return t < 7.2 ? 0.62 * Ease.inOut(Ease.progress(t, 3.0, 7.2)) : Ease.mix(0.62, 1, Ease.inOut(Ease.progress(t, 7.2, 9.4)))
        case .ember:
            return Ease.mix(0.5, 1, Ease.inOut(Ease.progress(t, 5.4, 9.4)))
        case .path:
            return t < 7.0 ? 0.62 * Ease.inOut(Ease.progress(t, 3.4, 7.0)) : Ease.mix(0.62, 1, Ease.inOut(Ease.progress(t, 7.0, 9.4)))
        }
    }

    public static func finalFrame(_ L: MarkLayout) -> SunriseFrame {
        SunriseFrame(
            veil: 1, dawn: 1, lightReach: nil, stars: 0, ground: 0,
            arch: ArchState(center: L.archCenter, radius: L.archRadius, width: L.archWidth,
                            baseRanges: [], base: MarkPalette.light,
                            navy: MarkAngles.navy, blue: MarkAngles.blue,
                            colorMix: 1, glow: 0, rim: 0, opacity: 1),
            sun: SunState(center: L.sunCenter, radius: L.sunRadius, glow: 0, opacity: 1),
            text: 1, button: 1, skip: 0)
    }

    public static func frame(_ variant: SunriseVariant, _ t: Double, _ L: MarkLayout, reduced: Bool = false) -> SunriseFrame {
        let cues = reduced ? SunriseCues.reduced : SunriseCues.of(variant)
        if t >= cues.end { return finalFrame(L) }
        var f: SunriseFrame
        if reduced {
            f = finalFrame(L)
            f.veil = Ease.smooth(Ease.progress(t, 0, 1.0))
            f.arch.opacity = Ease.smooth(Ease.progress(t, 1.0, 2.6))
            f.sun.opacity = f.arch.opacity
        } else {
            switch variant {
            case .horizon: f = horizon(t, L)
            case .ember: f = ember(t, L)
            case .path: f = path(t, L)
            }
        }
        f.dawn = dawn(variant, t, reduced: reduced)
        f.text = Ease.out(Ease.progress(t, cues.text, cues.text + 1.2))
        f.button = Ease.smooth(Ease.progress(t, cues.button, cues.end))
        f.skip = 1 - Ease.smooth(Ease.progress(t, cues.text - 0.6, cues.text))
        return f
    }

    // MARK: Horizon

    static func horizon(_ t: Double, _ L: MarkLayout) -> SunriseFrame {
        let W = L.size.width, H = L.size.height
        var f = finalFrame(L)
        f.veil = Ease.smooth(Ease.progress(t, 0, 1.6))
        f.stars = 0.35 * (1 - Ease.smooth(Ease.progress(t, 3.5, 6.5))) * Ease.smooth(Ease.progress(t, 0.6, 2.2))

        // The horizon starts as a barely curved line across the whole screen.
        let r0 = 6 * W, top0 = 0.62 * H
        let phi0 = asin(min(0.98, Double(0.8 * W / r0))) * 180 / .pi
        let morph = Ease.inOut(Ease.progress(t, 7.0, 9.2))
        let radius = morph >= 1 ? L.archRadius : CGFloat(exp(Ease.mix(log(Double(r0)), log(Double(L.archRadius)), morph)))
        let top = Ease.mix(top0, L.archTop, morph)
        let phi = Ease.mix(phi0, MarkAngles.halfSpan, morph)
        let drawn = Ease.out(Ease.progress(t, 1.4, 3.6))
        f.arch.center = CGPoint(x: W / 2, y: top + radius)
        f.arch.radius = radius
        f.arch.width = Ease.mix(1.6, L.archWidth, Ease.inOut(Ease.progress(t, 7.2, 9.2)))
        f.arch.baseRanges = drawn > 0 ? [(-90 - phi * drawn) ... (-90 + phi * drawn)] : []
        f.arch.navy = (-90 - phi) ... (-90 - phi * 4 / 52)
        f.arch.blue = (-90 - phi * 14 / 52) ... (-90 + phi)
        f.arch.colorMix = Ease.smooth(Ease.progress(t, 7.6, 9.0))
        f.arch.glow = Ease.out(Ease.progress(t, 1.4, 3.6)) * (1 - Ease.smooth(Ease.progress(t, 7.4, 8.8)))
        f.ground = Ease.smooth(Ease.progress(t, 1.4, 3.0)) * (1 - Ease.smooth(Ease.progress(t, 6.8, 7.9)))

        // The sun rises to sit on the horizon, then settles into the mark.
        let r = 0.09 * H
        let rise = Ease.inOut(Ease.progress(t, 3.0, 7.2))
        let offsetRise = Ease.mix(-1.15 * r, 0.75 * r, rise)
        let offset = Ease.mix(offsetRise, 40 * L.scale, morph)
        f.sun.radius = Ease.mix(r, L.sunRadius, morph)
        f.sun.center = CGPoint(x: W / 2, y: top - offset)
        f.sun.glow = Ease.smooth(Ease.progress(t, 3.0, 5.0)) * (1 - Ease.smooth(Ease.progress(t, 7.2, 9.0)))
        return f
    }

    // MARK: Ember

    static func ember(_ t: Double, _ L: MarkLayout) -> SunriseFrame {
        let H = L.size.height, diag = hypot(L.size.width, L.size.height)
        var f = finalFrame(L)
        f.veil = Ease.smooth(Ease.progress(t, 0, 1.4))
        // Three breaths, then the bloom.
        let breath = [2.0, 3.2, 4.4].map { Ease.bump(t, $0, 0.9) }.max() ?? 0
        let emberRadius = 0.004 * H * CGFloat(1 + 0.9 * breath)
        let bloom = Ease.out(Ease.progress(t, 5.2, 7.4))
        f.sun.radius = Ease.mix(emberRadius, L.sunRadius, bloom)
        // The ember glows just clear of the arch, then sinks into place as it grows.
        f.sun.center = Ease.mix(L.point(512, 400), L.sunCenter, bloom)
        f.sun.opacity = Ease.smooth(Ease.progress(t, 1.6, 2.0))
        f.sun.glow = t < 5.2 ? 0.35 + 0.65 * breath : 1 - Ease.smooth(Ease.progress(t, 7.6, 9.0))
        f.lightReach = t < 5.2 ? 0 : 2 * diag * CGFloat(Ease.out(Ease.progress(t, 5.2, 8.8)))
        // The arch is there all along, black on black until the light finds it.
        f.arch.baseRanges = [MarkAngles.navy.lowerBound ... MarkAngles.blue.upperBound]
        f.arch.base = MarkPalette.silhouette
        // Unseen until the light reaches it.
        f.arch.opacity = Ease.smooth(Ease.progress(t, 5.0, 6.2))
        f.arch.colorMix = Ease.smooth(Ease.progress(t, 7.6, 9.0))
        f.arch.rim = Ease.smooth(Ease.progress(t, 5.8, 6.8)) * (1 - Ease.smooth(Ease.progress(t, 8.0, 9.0)))
        return f
    }

    // MARK: The sun's path

    static func path(_ t: Double, _ L: MarkLayout) -> SunriseFrame {
        var f = finalFrame(L)
        f.veil = Ease.smooth(Ease.progress(t, 0, 1.6))
        f.stars = Ease.smooth(Ease.progress(t, 0.6, 2.4)) * (1 - Ease.smooth(Ease.progress(t, 4.5, 7.5)))

        // The sun climbs high on a wide orbit, riding just above its own
        // trail, then both settle into the mark.
        let climb = Ease.inOutSine(Ease.progress(t, 2.4, 7.2))
        let settle = Ease.inOut(Ease.progress(t, 6.6, 8.6))
        let angle = Ease.mix(-166.0, -90.0, climb)
        let a = angle * .pi / 180
        f.sun.radius = Ease.mix(0.45 * L.sunRadius, L.sunRadius, Ease.inOut(Ease.progress(t, 2.4, 8.2)))
        let orbit = Ease.mix(546 * L.scale, L.sunOrbit, settle)
        let lift = Ease.mix(0.75 * 0.45 * L.sunRadius, 40 * L.scale, settle)
        f.sun.center = CGPoint(x: L.archCenter.x + orbit * CGFloat(cos(a)), y: L.archCenter.y + orbit * CGFloat(sin(a)))
        f.sun.opacity = Ease.smooth(Ease.progress(t, 2.4, 3.2))
        f.sun.glow = 1 - Ease.smooth(Ease.progress(t, 7.6, 8.8))

        // Behind the sun, where it has been; then ahead of it, where it is going.
        let start = Ease.mix(-166.0, MarkAngles.navy.lowerBound, settle)
        let trailEnd = min(angle, MarkAngles.navy.upperBound)
        let sweep = Ease.inOut(Ease.progress(t, 7.0, 8.4))
        let navy: ClosedRange<Double>? = trailEnd > start + 0.5 ? start ... trailEnd : nil
        let blue: ClosedRange<Double>? = sweep > 0 ? MarkAngles.blue.lowerBound ... (MarkAngles.blue.lowerBound + 66 * sweep) : nil
        f.arch.radius = orbit - lift
        f.arch.navy = navy
        f.arch.blue = blue
        f.arch.baseRanges = [navy, blue].compactMap { $0 }
        f.arch.width = Ease.mix(7 * L.scale, L.archWidth, Ease.inOut(Ease.progress(t, 6.8, 8.8)))
        f.arch.colorMix = Ease.smooth(Ease.progress(t, 7.4, 9.0))
        f.arch.glow = 1 - Ease.smooth(Ease.progress(t, 7.8, 9.0))
        return f
    }
}
