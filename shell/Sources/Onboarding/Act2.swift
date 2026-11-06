import CoreGraphics
import Foundation

/// Act 2, "Where you've been": The Sun's Path, reused. You stand at the apex
/// of a great arc; your other browsers' profiles sit along its navy side, the
/// past. What you choose to bring flows along the trail into you as points of
/// light. Then "ReStored." (or "ReFocused." for a clean start), and the blue
/// sweeps ahead: where you're going, which is Act 3.
public enum ImportCategory: Int, CaseIterable, Sendable {
    case spaces, bookmarks, history, passwords, extensions

    public var title: String {
        switch self {
        case .spaces: "Spaces & tabs"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .passwords: "Passwords"
        case .extensions: "Extensions"
        }
    }
}

public struct Act2Log: Equatable, Sendable {
    public var start: Double
    public var sources: [ImportSource]
    /// Each flips one source on or off (all start on).
    public var toggles: [(time: Double, index: Int)] = []
    /// Each flips one category (all start on).
    public var categories: [(time: Double, category: ImportCategory)] = []
    /// Bring them over (true) or start fresh (false).
    public var choice: (time: Double, bring: Bool)?
    /// What the host can import (all of them in the prototype).
    public var offered: [ImportCategory] = ImportCategory.allCases
    /// What really came over, once the host's import finishes.
    public var outcome: ImportStats?

    public init(start: Double, sources: [ImportSource], offered: [ImportCategory] = ImportCategory.allCases) {
        self.start = start; self.sources = sources; self.offered = offered
    }

    public static func == (a: Act2Log, b: Act2Log) -> Bool {
        a.start == b.start && a.sources == b.sources
            && a.toggles.map(\.time) == b.toggles.map(\.time) && a.toggles.map(\.index) == b.toggles.map(\.index)
            && a.categories.map(\.time) == b.categories.map(\.time) && a.categories.map(\.category) == b.categories.map(\.category)
            && a.choice?.time == b.choice?.time && a.choice?.bring == b.choice?.bring
            && a.offered == b.offered && a.outcome == b.outcome
    }

    public func isOn(source i: Int, at t: Double) -> Bool {
        toggles.filter { $0.time <= t && $0.index == i && $0.time <= (choice?.time ?? .infinity) }.count % 2 == 0
    }

    public func isOn(_ c: ImportCategory, at t: Double) -> Bool {
        guard offered.contains(c) else { return false }
        return categories.filter { $0.time <= t && $0.category == c && $0.time <= (choice?.time ?? .infinity) }.count % 2 == 0
    }

    /// What will come over, given the choices so far; once the import is
    /// done, what really did.
    public func totals(at t: Double) -> ImportStats {
        if let outcome, let c = choice, t >= c.time { return outcome }
        var sum = ImportStats()
        for (i, s) in sources.enumerated() where isOn(source: i, at: t) {
            var st = s.stats
            if !isOn(.spaces, at: t) { st.spaces = 0; st.tabs = 0 }
            if !isOn(.bookmarks, at: t) { st.bookmarks = 0 }
            if !isOn(.history, at: t) { st.pages = 0 }
            if !isOn(.passwords, at: t) { st.passwords = 0 }
            if !isOn(.extensions, at: t) { st.extensions = 0 }
            sum = sum + st
        }
        return sum
    }

    public var bringing: Bool { choice?.bring == true && sources.indices.contains { isOn(source: $0, at: choice!.time) } }

    public var flowStart: Double? { bringing ? choice!.time + 0.6 : nil }
    /// "ReStored." or "ReFocused."
    public var done: Double? {
        guard let c = choice else { return nil }
        return bringing ? c.time + 0.6 + Act2Timeline.flow + 0.3 : c.time + 0.7
    }
    public var handOff: Double? { done.map { $0 + 4.8 } }

    /// Someone leaves Brave behind, skips extensions and brings the rest.
    public static func demo(start: Double, sources: [ImportSource] = ImportSource.demo) -> Act2Log {
        var log = Act2Log(start: start, sources: sources)
        let ready = start + Act2Timeline.ready
        if sources.count > 3 { log.toggles = [(ready + 0.8, 3)] }
        log.categories = [(ready + 1.6, .extensions)]
        log.choice = (ready + 2.6, true)
        return log
    }
}

public struct Act2Particle: Equatable {
    public var point: CGPoint
    public var radius: CGFloat
    public var alpha: Double
    public var colour: RGBA
}

public struct Act2Frame: Equatable {
    /// Act 1's closing words clear; its avatar walks to the apex.
    public var clearAct1: Double
    public var trail: Double
    public var trailWidth: CGFloat
    public var trailGlow: Double
    public var ask: Double
    public var nodes: [Double]
    public var nodeOn: [Double]
    public var chips: Double
    public var chipOn: [Double]
    public var buttons: Double
    public var bringingLine: Double
    public var flow: Double
    public var totals: ImportStats
    public var shown: ImportStats
    public var arrivals: Double
    public var restored: Double
    public var refocused: Double
    public var sweep: Double
    public var next: Double
}

public enum Act2Timeline {
    /// From the act's start until it is ready for choices.
    public static let ready = 3.4
    public static let flow = 4.0

    public static func frame(_ log: Act2Log, _ t: Double, _ A: Act2Layout) -> Act2Frame {
        let s = log.start
        let c = log.choice?.time ?? .infinity
        let done = log.done ?? .infinity
        let out = { (a: Double, b: Double) in 1 - Ease.smooth(Ease.progress(t, a, b)) }
        let ease = { (a: Double, b: Double) in Ease.out(Ease.progress(t, a, b)) }
        let flowStart = log.flowStart ?? .infinity
        let p = Ease.inOut(Ease.progress(t, flowStart, flowStart + flow))

        let totals = log.totals(at: t)
        let scaled = { (n: Int) in Int((Double(n) * p).rounded()) }
        let shown = ImportStats(spaces: scaled(totals.spaces), tabs: scaled(totals.tabs), bookmarks: scaled(totals.bookmarks),
                                pages: scaled(totals.pages), passwords: scaled(totals.passwords), extensions: scaled(totals.extensions))

        // The avatar brightens with each arrival.
        var arrivals = 0.0
        for (i, _) in log.sources.enumerated() where log.bringing && log.isOn(source: i, at: c) {
            for j in 0 ..< particlesPerSource {
                let arrive = emission(i, j, flowStart) + travel
                arrivals += Ease.bump(t, arrive + 0.05, 0.25)
            }
        }

        let nodeOn = log.sources.indices.map { i -> Double in
            // Ease between on and off from the last flip.
            let flips = log.toggles.filter { $0.index == i && $0.time <= min(t, c) }
            let on = log.isOn(source: i, at: t)
            guard let last = flips.last else { return 1 }
            let k = Ease.smooth((t - last.time) / 0.3)
            return on ? k : 1 - k
        }
        let chipOn = ImportCategory.allCases.map { cat -> Double in
            let flips = log.categories.filter { $0.category == cat && $0.time <= min(t, c) }
            let on = log.isOn(cat, at: t)
            guard let last = flips.last else { return 1 }
            let k = Ease.smooth((t - last.time) / 0.25)
            return on ? k : 1 - k
        }
        let fresh = log.choice?.bring == false || (log.choice != nil && !log.bringing)
        let nodes = log.sources.indices.map { i -> Double in
            let appear = ease(s + 2.0 + Double(i) * 0.14, s + 2.6 + Double(i) * 0.14)
            let kept = log.isOn(source: i, at: c) && !fresh
            let leave = kept ? out(done, done + 0.8) : out(c, c + 0.6)
            return appear * leave
        }

        return Act2Frame(
            clearAct1: Ease.inOut(Ease.progress(t, s, s + 1.2)),
            trail: Ease.inOut(Ease.progress(t, s + 0.6, s + 2.0)) * (fresh ? Ease.mix(1, 0.25, Ease.smooth(Ease.progress(t, c, c + 0.8))) : 1),
            trailWidth: Ease.mix(A.size.height * 0.003, A.size.height * 0.016, Ease.inOut(Ease.progress(t, flowStart, flowStart + flow))),
            trailGlow: Ease.smooth(Ease.progress(t, s + 0.6, s + 1.4)) * out(done, done + 1.2),
            ask: ease(s + 1.2, s + 2.0) * out(c, c + 0.5),
            nodes: nodes,
            nodeOn: nodeOn,
            chips: ease(s + 2.6, s + 3.2) * out(c, c + 0.5),
            chipOn: chipOn,
            buttons: ease(s + 2.9, s + ready) * out(c, c + 0.4),
            bringingLine: log.bringing ? ease(c + 0.5, c + 1.2) * out(done - 0.2, done + 0.3) : 0,
            flow: p,
            totals: totals,
            shown: shown,
            arrivals: min(1, arrivals),
            restored: log.bringing ? ease(done, done + 0.9) * out(done + 2.6, done + 3.2) : 0,
            refocused: fresh ? ease(done, done + 0.9) * out(done + 2.6, done + 3.2) : 0,
            sweep: Ease.inOut(Ease.progress(t, done + 1.4, done + 2.8)),
            next: ease(done + 3.2, done + 4.0))
    }

    static let particlesPerSource = 34

    /// When each point of light reaches you (every fourth one rings).
    public static func arrivalTimes(_ log: Act2Log) -> [(Double, Int)] {
        guard let flowStart = log.flowStart, let c = log.choice?.time else { return [] }
        var times: [(Double, Int)] = []
        for i in log.sources.indices where log.isOn(source: i, at: c) {
            for j in stride(from: 0, to: particlesPerSource, by: 4) {
                times.append((emission(i, j, flowStart) + travel, i * 3 + j / 4))
            }
        }
        return times.sorted { $0.0 < $1.0 }
    }
    static let travel = 1.2

    static func emission(_ source: Int, _ j: Int, _ flowStart: Double) -> Double {
        var h = UInt64(source * 977 + j * 131 + 17)
        h = h &* 6364136223846793005 &+ 1442695040888963407
        let jitter = Double(h >> 11) / Double(1 << 53)
        return flowStart + (Double(j) / Double(particlesPerSource)) * (flow - travel) + jitter * 0.12 + Double(source) * 0.05
    }

    public static func particles(_ log: Act2Log, _ t: Double, _ A: Act2Layout) -> [Act2Particle] {
        guard let flowStart = log.flowStart, let c = log.choice?.time else { return [] }
        var result: [Act2Particle] = []
        let H = A.size.height
        for (i, source) in log.sources.enumerated() where log.isOn(source: i, at: c) {
            let from = A.nodeAngle(i, of: log.sources.count)
            for j in 0 ..< particlesPerSource {
                let e = emission(i, j, flowStart)
                let q = (t - e) / travel
                guard q > 0, q < 1 else { continue }
                let a = Ease.mix(from, -90, Ease.inOut(q)) * .pi / 180
                let wobble = CGFloat(sin(Double(j) * 2.3 + q * 7)) * H * 0.006 * CGFloat(1 - q)
                let r = A.radius + wobble
                result.append(Act2Particle(
                    point: CGPoint(x: A.center.x + r * CGFloat(cos(a)), y: A.center.y + r * CGFloat(sin(a))),
                    radius: H * (0.0028 + 0.0022 * CGFloat((j * 7) % 5) / 4),
                    alpha: sin(.pi * q) * 0.95,
                    colour: source.colour.mix(RGBA(1, 0.97, 0.92), 0.55)))
            }
        }
        return result
    }
}

public struct Act2Layout {
    public let size: CGSize
    public init(size: CGSize) { self.size = size }
    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    public var apex: CGPoint { CGPoint(x: W / 2, y: H * 0.7) }
    public var radius: CGFloat { H * 0.6 }
    public var center: CGPoint { CGPoint(x: W / 2, y: apex.y + radius) }
    public var avatarRadius: CGFloat { H * 0.045 }
    public var nodeRadius: CGFloat { H * 0.026 }
    public var line: CGFloat { H * 0.36 }
    public var subline: CGFloat { H * 0.405 }
    public var chips: CGFloat { H * 0.475 }
    public var buttons: CGFloat { H * 0.555 }
    /// Past on the left: the trail runs from here to the apex.
    public static let trailStart = -156.0

    public func nodeAngle(_ i: Int, of n: Int) -> Double {
        guard n > 1 else { return -126 }
        let span = min(46.0, Double(n - 1) * 12)
        return -150 + span * Double(i) / Double(n - 1) + (46 - span) / 2
    }

    public func point(_ angle: Double, _ r: CGFloat? = nil) -> CGPoint {
        let a = angle * .pi / 180, r = r ?? radius
        return CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
    }
}
