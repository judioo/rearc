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
            return Update(consumes: consumes, progress: 0)
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
                          commit: available && distance >= Self.threshold ? direction : nil)
        }
        return Update(consumes: true, direction: direction, progress: min(distance / Self.threshold, 1))
    }
}
