import Foundation

/// Work that arrives in bursts, applied on the main thread a turn at a time:
/// each turn takes items until it has spent `budget` seconds (at least one
/// slice), and the rest wait for the next turn. Chromium hands the shell a
/// slice of its download history in one main-thread task; applied in one go
/// with the SwiftUI update after it, a slice showed as a 17–57 ms stall.
public struct BudgetedQueue<Element> {
    private var items: [Element] = []
    private var head = 0

    public init() {}

    public var isEmpty: Bool { head == items.count }
    public var count: Int { items.count - head }

    public mutating func append(_ item: Element) {
        items.append(item)
    }

    /// Hands `apply` slices of up to `stride` items, oldest first, until
    /// `now()` is `budget` past the start or the queue is empty. Returns how
    /// many items were applied.
    @discardableResult
    public mutating func drain(budget: TimeInterval, stride: Int = 64, now: () -> TimeInterval,
                               apply: (ArraySlice<Element>) -> Void) -> Int {
        guard !isEmpty else { return 0 }
        let start = now()
        var taken = 0
        repeat {
            let end = min(head + max(stride, 1), items.count)
            let slice = items[head ..< end]
            head = end
            taken += slice.count
            apply(slice)
        } while !isEmpty && now() - start < budget
        if isEmpty {
            items.removeAll(keepingCapacity: items.count <= 4_096)
            head = 0
        } else if head > 4_096, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return taken
    }

    /// Everything still queued, oldest first; the queue is left empty.
    public mutating func removeAll() -> [Element] {
        let rest = Array(items[head...])
        items.removeAll()
        head = 0
        return rest
    }
}
