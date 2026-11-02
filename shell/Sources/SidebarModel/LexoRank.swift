import Foundation

/// Fractional string indexing for zero-rewrite sidebar ordering (sync design §5.2).
public enum LexoRank: Equatable, Sendable {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let minDigit = digits[0]
    private static let maxDigit = digits[digits.count - 1]
    /// Rebalance when rank strings exceed this length or keys collide.
    public static let rebalanceLengthThreshold = 48

    /// Midpoint rank for an empty list or seed value.
    public static let initial: String = "U"

    /// Generates `count` evenly spaced ranks for migration from legacy array order.
    public static func initialSequence(count: Int) -> [String] {
        guard count > 0 else { return [] }
        if count == 1 { return [initial] }
        var result: [String] = [initial]
        while result.count < count {
            result.append(after(result.last))
        }
        return result
    }

    /// Rank strictly after `rank`, or the first rank when `rank` is nil.
    public static func after(_ rank: String?) -> String {
        guard let rank, !rank.isEmpty else { return initial }
        var chars = Array(rank)
        var index = chars.count - 1
        while index >= 0 {
            if let next = digit(after: chars[index]) {
                chars[index] = next
                return String(chars)
            }
            chars[index] = minDigit
            index -= 1
        }
        return String(repeating: String(minDigit), count: rank.count + 1) + initial
    }

    /// Rank strictly before `rank`, or the first rank when `rank` is nil.
    public static func before(_ rank: String?) -> String {
        guard let rank, !rank.isEmpty else { return initial }
        var chars = Array(rank)
        var index = chars.count - 1
        while index >= 0 {
            if let previous = digit(before: chars[index]) {
                chars[index] = previous
                return String(chars)
            }
            chars[index] = maxDigit
            index -= 1
        }
        return rank + String(minDigit)
    }

    /// Rank strictly between `left` and `right` (exclusive). Either bound may be nil (open end).
    public static func between(_ left: String?, _ right: String?) -> String {
        switch (left, right) {
        case (nil, nil):
            return initial
        case (nil, let right?):
            return before(right)
        case (let left?, nil):
            return after(left)
        case (let left?, let right?):
            precondition(left < right, "LexoRank.between requires left < right")
            if left.count >= rebalanceLengthThreshold || right.count >= rebalanceLengthThreshold {
                return after(left)
            }
            var leftChars = Array(left)
            var rightChars = Array(right)
            var index = 0
            while index < leftChars.count && index < rightChars.count && leftChars[index] == rightChars[index] {
                index += 1
            }
            if index >= leftChars.count {
                if let extensionRank = midpointChar(between: minDigit, and: rightChars[index]) {
                    return left + String(extensionRank)
                }
                return left + String(minDigit)
            }
            let leftChar = leftChars[index]
            let rightChar = rightChars[index]
            if let mid = midpointChar(between: leftChar, and: rightChar) {
                return String(leftChars.prefix(index)) + String(mid)
            }
            return String(leftChars.prefix(index + 1)) + String(midpointChar(between: minDigit, and: maxDigit)!)
        }
    }

    public static func needsRebalance(_ ranks: [String]) -> Bool {
        let sorted = ranks.filter { !$0.isEmpty }
        guard !sorted.isEmpty else { return false }
        if Set(sorted).count != sorted.count { return true }
        return sorted.contains { $0.count >= rebalanceLengthThreshold }
    }

    /// Re-spreads ranks evenly; preserves relative order of input ids by rank sort.
    public static func rebalance(_ ranks: [String]) -> [String] {
        let ordered = ranks.sorted()
        return initialSequence(count: ordered.count)
    }

    private static func digit(after char: Character) -> Character? {
        guard let index = digits.firstIndex(of: char), index + 1 < digits.count else { return nil }
        return digits[index + 1]
    }

    private static func digit(before char: Character) -> Character? {
        guard let index = digits.firstIndex(of: char), index > 0 else { return nil }
        return digits[index - 1]
    }

    private static func midpointChar(between left: Character, and right: Character) -> Character? {
        guard let leftIndex = digits.firstIndex(of: left),
              let rightIndex = digits.firstIndex(of: right),
              rightIndex - leftIndex > 1 else { return nil }
        return digits[(leftIndex + rightIndex) / 2]
    }
}
