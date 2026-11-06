import Foundation

/// p50, p95 (nearest rank, as scripts/bench_finalize.py) and max of one metric.
public struct Summary: Equatable, Codable, Sendable {
    public var n: Int
    public var p50: Double?
    public var p95: Double?
    public var max: Double?

    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        n = sorted.count
        p50 = Summary.nearestRank(sorted, 0.5)
        p95 = Summary.nearestRank(sorted, 0.95)
        max = sorted.last
    }

    public static func nearestRank(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let k = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[Swift.min(sorted.count - 1, Swift.max(0, k))]
    }
}
