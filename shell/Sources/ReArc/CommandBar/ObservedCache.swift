import Observation

/// A main-thread derived value, rebuilt once after one of the properties it
/// actually read changes. Cache hits register readers too, so a SwiftUI view
/// or a second derived cache still gets invalidated after a warm read.
@Observable
final class ObservedCache<Value> {
    private var generation = 0
    @ObservationIgnored private var cached: Value?
    @ObservationIgnored private(set) var buildCount = 0

    func value(_ build: () -> Value) -> Value {
        _ = generation
        if let cached { return cached }
        let value = withObservationTracking(build) { [weak self] in
            self?.cached = nil
            self?.generation &+= 1
        }
        cached = value
        buildCount += 1
        return value
    }
}
