import Foundation

/// History navigation only claims gestures that began at an unconsumed edge.
public struct HistorySwipe {
    public enum Direction: Equatable { case back, forward }
    public enum Phase { case began, changed, ended, cancelled, momentum, unphased }
    public struct Edges: Equatable {
        public var back: Bool
        public var forward: Bool
        public init(back: Bool, forward: Bool) { self.back = back; self.forward = forward }
    }
    public struct Update: Equatable {
        public var consumes: Bool
        public var direction: Direction? = nil
        public var progress: Double
        public var commit: Direction? = nil
        /// The fingers left a tracked swipe; the indicator fades out (`commit` picks which fade).
        public var released = false
    }

    public static let threshold = 100.0
    private enum State { case idle, deciding, rejected, tracking(Direction), finished }
    private var state: State = .idle
    private var distance = 0.0
    private var edges = Edges(back: false, forward: false)
    public init() {}

    public mutating func handle(phase: Phase, x: Double, y: Double,
                                edges: Edges, canGoBack: Bool, canGoForward: Bool) -> Update {
        if phase == .began {
            state = .deciding
            distance = 0
            self.edges = edges
        }
        if phase == .momentum {
            switch state {
            case .tracking, .finished: return Update(consumes: true, progress: 0)
            default: return Update(consumes: false, progress: 0)
            }
        }
        if phase == .unphased { return Update(consumes: false, progress: 0) }
        if phase == .cancelled {
            let consumes: Bool
            if case .tracking = state { consumes = true } else { consumes = false }
            state = consumes ? .finished : .idle
            return Update(consumes: consumes, progress: 0, released: consumes)
        }
        if case .deciding = state, x != 0 || y != 0 {
            let direction: Direction = x > 0 ? .back : .forward
            let available = direction == .back ? self.edges.back && canGoBack : self.edges.forward && canGoForward
            if abs(x) > abs(y) * 1.5, available { state = .tracking(direction) }
            else { state = .rejected }
        }
        guard case .tracking(let direction) = state else {
            if phase == .ended { state = .idle }
            return Update(consumes: false, progress: 0)
        }
        distance = max(0, distance + (direction == .back ? x : -x))
        if phase == .ended {
            state = .finished
            let available = direction == .back ? canGoBack : canGoForward
            return Update(consumes: true, progress: 0,
                          commit: available && distance >= Self.threshold ? direction : nil, released: true)
        }
        return Update(consumes: true, direction: direction, progress: min(distance / Self.threshold, 1))
    }
}

/// Arc's edge disc, measured from a 60 fps capture (docs/arc-recordings/2026-11-06-history-swipe.md).
/// Lengths are points inward from the page edge the disc hangs off; negative is past the edge.
public extension HistorySwipe {
    struct Indicator: Equatable {
        public var radius: Double
        public var centre: Double
        public var arrowCentre: Double
        /// Alpha of the black disc; the arrow stays opaque white.
        public var opacity: Double
        public var armed: Bool
    }

    /// The disc's furthest reach into the page, reached exactly at the threshold.
    static let reach = 70.0
    static let radius = 70.0
    /// The disc swells by 6 pt in one frame when a release would navigate.
    static let armedRadius = 76.0
    static let armedOpacity = 0.79
    /// A white, round-capped arrow, 43 × 40 pt overall.
    static let arrowWidth = 43.0
    static let arrowHeight = 40.0
    static let arrowStroke = 9.5
    /// The disc's tone trails the fingers by this ease-out.
    static let opacityDuration = 0.2
    static let commitFadeDuration = 0.28
    static let cancelFadeDuration = 0.22

    /// Arc slides the disc out from behind the edge at a fixed size. Reduce
    /// Motion parks it at its resting place and keeps only the tone and the swell.
    static func indicator(progress: Double, reduceMotion: Bool) -> Indicator {
        let p = min(max(progress, 0), 1)
        let armed = p >= 1
        let radius = armed ? armedRadius : radius
        let bulge = reduceMotion || armed ? reach : reach * p
        // The arrow rides with the disc, so it starts out clipped by the edge.
        return Indicator(radius: radius, centre: bulge - radius, arrowCentre: bulge - reach / 2,
                         opacity: armed ? armedOpacity : min(0.2 + 0.6 * p, 0.7), armed: armed)
    }
}
