import Foundation

/// Horizontal paging between the spaces of one profile (Arc
/// `SidebarPagingContainer`, SIDEBAR-SPEC §4.7). Positions are in pages: 1.4
/// shows 60% of page 1 and 40% of page 2. A two-finger swipe tracks the
/// fingers, rubber-bands past the first and last space, and on release
/// settles on a damped spring that keeps the release velocity. Any new swipe
/// grabs the page where it is, mid-spring. Time is passed in, so the whole
/// motion is a pure function of its inputs.
public struct SpacePaging: Sendable {

    /// SwiftUI-style spring parameters (response in seconds).
    public struct Spring: Equatable, Sendable {
        public var response: Double
        public var dampingFraction: Double

        public init(response: Double, dampingFraction: Double) {
            self.response = response
            self.dampingFraction = dampingFraction
        }

        /// Placeholder for Arc's paging spring (DESIGN-TOKENS §4.2 values are UN):
        /// quick, with a trace of overshoot after a fast flick.
        public static let page = Spring(response: 0.42, dampingFraction: 0.86)

        /// A clicked or shortcut switch. Arc settles ≈ 200–300 ms after the
        /// click with no visible overshoot, and barely moves in the first
        /// frame (ARC-RECORDING-ANALYSIS.md §4). Critically damped from rest
        /// starts slowly and is within 2 % of the page at ≈ 230 ms.
        public static let click = Spring(response: 0.25, dampingFraction: 1)
    }

    public private(set) var pageCount: Int
    /// The page the sidebar rests on, or springs toward.
    public private(set) var targetPage: Int
    public private(set) var isTracking = false
    public var spring: Spring
    /// Springs a clicked or shortcut switch (`go(to:)`).
    public var clickSpring: Spring
    /// The spring now running: `spring` after a swipe, `clickSpring` after `go(to:)`.
    private var running: Spring

    /// Rest state or the spring's start: offset from the target and velocity
    /// (pages per second) at `springStart`.
    private var springOffset: Double = 0
    private var springVelocity: Double = 0
    private var springStart: TimeInterval = 0
    /// Raw (un-rubber-banded) position while tracking, and the page it began on.
    private var trackedPosition: Double = 0
    private var trackingOrigin = 0
    private var samples: [(time: TimeInterval, position: Double)] = []

    /// How far a release projects at its velocity (UIScrollView-style
    /// deceleration, about 0.2 s of travel at the release speed).
    static let projectionSeconds = 0.2
    /// Past this offset the spring counts as settled.
    static let restThreshold = 0.0005

    public init(pageCount: Int, page: Int, spring: Spring = .page, clickSpring: Spring = .click) {
        self.pageCount = max(pageCount, 1)
        self.targetPage = Self.clamp(page, count: max(pageCount, 1))
        self.spring = spring
        self.clickSpring = clickSpring
        self.running = spring
    }

    // MARK: Reading

    /// Displayed position at `time`, rubber-banding included.
    public func position(at time: TimeInterval) -> Double {
        if isTracking { return Self.rubberBand(trackedPosition, count: pageCount) }
        return Double(targetPage) + springState(at: time).offset
    }

    public func velocity(at time: TimeInterval) -> Double {
        isTracking ? 0 : springState(at: time).velocity
    }

    /// True while the page moves under a finger or a spring.
    public func isAnimating(at time: TimeInterval) -> Bool {
        if isTracking { return true }
        let state = springState(at: time)
        return abs(state.offset) > Self.restThreshold || abs(state.velocity) > Self.restThreshold * 10
    }

    /// When the current spring comes to rest (nil while tracking): its
    /// envelope then stays under `restThreshold`.
    public var restTime: TimeInterval? {
        if isTracking { return nil }
        if springOffset == 0, springVelocity == 0 { return springStart }
        let omega = 2 * Double.pi / max(running.response, 0.01)
        let zeta = min(max(running.dampingFraction, 0.05), 1)
        let omegaD = zeta < 1 ? omega * (1 - zeta * zeta).squareRoot() : omega
        let b = (springVelocity + zeta * omega * springOffset) / omegaD
        let amplitude = (springOffset * springOffset + b * b).squareRoot() * (zeta >= 1 ? 2 : 1)
        guard amplitude > Self.restThreshold else { return springStart }
        return springStart + log(amplitude / Self.restThreshold) / (zeta * omega)
    }

    /// The two pages visible at `time` (equal when it rests on one) and how
    /// far the view is from the first to the second, 0…1.
    public func visiblePages(at time: TimeInterval) -> (from: Int, to: Int, fraction: Double) {
        let p = min(max(position(at: time), 0), Double(pageCount - 1))
        let from = Int(p.rounded(.down))
        let to = min(from + 1, pageCount - 1)
        return (from, to, p - Double(from))
    }

    // MARK: Gestures

    /// Fingers touch down: stop the spring where it is.
    public mutating func beginTracking(at time: TimeInterval) {
        let now = position(at: time)
        trackedPosition = Self.unRubberBand(now, count: pageCount)
        trackingOrigin = Self.clamp(Int(now.rounded()), count: pageCount)
        isTracking = true
        samples = [(time, trackedPosition)]
    }

    /// Fingers moved by `pages` (positive shows the next space).
    public mutating func track(by pages: Double, at time: TimeInterval) {
        guard isTracking else { return }
        trackedPosition += pages
        samples.append((time, trackedPosition))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Fingers lifted. Returns the page it settles on, at most one page from
    /// where the swipe started (Arc pages one space per swipe).
    @discardableResult
    public mutating func endTracking(at time: TimeInterval) -> Int {
        guard isTracking else { return targetPage }
        let release = Self.rubberBand(trackedPosition, count: pageCount)
        let velocity = trackingVelocity()
        let projected = release + velocity * Self.projectionSeconds
        var target = Int(projected.rounded())
        target = min(max(target, trackingOrigin - 1), trackingOrigin + 1)
        target = Self.clamp(target, count: pageCount)
        isTracking = false
        samples = []
        running = spring
        startSpring(to: target, from: release, velocity: velocity, at: time)
        return target
    }

    /// A swipe the system cancelled: spring back to where it began.
    public mutating func cancelTracking(at time: TimeInterval) {
        guard isTracking else { return }
        let release = Self.rubberBand(trackedPosition, count: pageCount)
        isTracking = false
        samples = []
        running = spring
        startSpring(to: trackingOrigin, from: release, velocity: 0, at: time)
    }

    /// The space changed some other way (click, Ctrl+N, Cmd+Opt+arrows): spring
    /// there from wherever the page is, or jump when `animated` is false
    /// (Reduce Motion, a profile change).
    public mutating func go(to page: Int, pageCount count: Int, animated: Bool, at time: TimeInterval) {
        let count = max(count, 1)
        let page = Self.clamp(page, count: count)
        if !animated || count != pageCount {
            pageCount = count
            isTracking = false
            samples = []
            targetPage = page
            springOffset = 0
            springVelocity = 0
            springStart = time
            return
        }
        guard !isTracking, page != targetPage else { return }
        let from = position(at: time), velocity = velocity(at: time)
        running = clickSpring
        startSpring(to: page, from: from, velocity: velocity, at: time)
    }

    // MARK: Physics

    private mutating func startSpring(to page: Int, from position: Double, velocity: Double, at time: TimeInterval) {
        targetPage = page
        springOffset = position - Double(page)
        springVelocity = velocity
        springStart = time
    }

    private func trackingVelocity() -> Double {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }

    /// Closed-form damped harmonic oscillator, so any frame (and any
    /// interruption) reads exact position and velocity.
    private func springState(at time: TimeInterval) -> (offset: Double, velocity: Double) {
        let t = max(0, time - springStart)
        let x0 = springOffset
        let v0 = springVelocity
        if x0 == 0, v0 == 0 { return (0, 0) }
        let omega = 2 * Double.pi / max(running.response, 0.01)
        let zeta = min(max(running.dampingFraction, 0), 1)
        if zeta >= 1 {
            let c = v0 + omega * x0
            let e = exp(-omega * t)
            let x = (x0 + c * t) * e
            let v = (c - omega * (x0 + c * t)) * e
            return (x, v)
        }
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let a = x0
        let b = (v0 + zeta * omega * x0) / omegaD
        let e = exp(-zeta * omega * t)
        let cosT = cos(omegaD * t)
        let sinT = sin(omegaD * t)
        let x = e * (a * cosT + b * sinT)
        let v = e * ((b * omegaD - zeta * omega * a) * cosT - (a * omegaD + zeta * omega * b) * sinT)
        return (x, v)
    }

    // MARK: Rubber band

    /// Apple's rubber-band curve: past the ends the page moves less and less,
    /// never more than one page.
    static func rubberBand(_ position: Double, count: Int) -> Double {
        let upper = Double(count - 1)
        if position < 0 { return -band(-position) }
        if position > upper { return upper + band(position - upper) }
        return position
    }

    static func unRubberBand(_ position: Double, count: Int) -> Double {
        let upper = Double(count - 1)
        if position < 0 { return -unBand(-position) }
        if position > upper { return upper + unBand(position - upper) }
        return position
    }

    private static let bandCoefficient = 0.55
    /// Limit of the overshoot, in pages.
    private static let bandLimit = 0.35

    private static func band(_ overshoot: Double) -> Double {
        (1 - 1 / (overshoot * bandCoefficient / bandLimit + 1)) * bandLimit
    }

    private static func unBand(_ shown: Double) -> Double {
        let s = min(shown, bandLimit * 0.999)
        return (1 / (1 - s / bandLimit) - 1) * bandLimit / bandCoefficient
    }

    private static func clamp(_ page: Int, count: Int) -> Int {
        min(max(page, 0), count - 1)
    }
}

/// Decides whether a two-finger scroll on the sidebar is a horizontal space
/// swipe or ordinary vertical scrolling, from its first few points of travel.
public struct SwipeAxisLock: Equatable, Sendable {
    /// A horizontal scroll delta as content travel (negative shows the next
    /// space). The page follows the fingers whatever the scroll direction
    /// setting, as macOS's page swipes do: only natural scrolling
    /// (`invertedFromDevice`) already reports the fingers' way.
    public static func contentDelta(_ scrollingDeltaX: Double, invertedFromDevice: Bool) -> Double {
        invertedFromDevice ? scrollingDeltaX : -scrollingDeltaX
    }

    public enum Axis: Equatable, Sendable { case undecided, horizontal, vertical }

    public private(set) var axis: Axis = .undecided
    /// Travel so far; a horizontal lock replays it so no motion is lost.
    public private(set) var dx: Double = 0
    public private(set) var dy: Double = 0

    /// Travel (points) before the axis is decided.
    static let decisionDistance = 6.0

    public init() {}

    public mutating func add(dx: Double, dy: Double) -> Axis {
        guard axis == .undecided else { return axis }
        self.dx += dx
        self.dy += dy
        guard abs(self.dx) + abs(self.dy) >= Self.decisionDistance else { return axis }
        axis = abs(self.dx) > abs(self.dy) * 1.3 ? .horizontal : .vertical
        return axis
    }
}
