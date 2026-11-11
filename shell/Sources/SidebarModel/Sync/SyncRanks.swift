import Foundation

/// Rank repair for synced lists. Each synced row carries its own `sortRank`
/// (SYNC-DESIGN §5.2), and a list is ordered by (rank, record name). Before a
/// list is uploaded its ranks are made strictly increasing in display order,
/// keeping as many existing ranks as possible, so a reorder rewrites only the
/// rows that moved and two devices repairing the same merged list compute the
/// same ranks.
public enum SyncRanks {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A rank strictly between `left` and `right` in String order (nil = open
    /// end), or nil when none exists (`right` is `left` + "0…0").
    public static func between(_ left: String?, _ right: String?) -> String? {
        let left = left ?? ""
        guard let right else { return left + "U" }
        guard left < right else { return nil }
        let l = Array(left), r = Array(right)
        var i = 0
        while i < l.count, i < r.count, l[i] == r[i] { i += 1 }
        let prefix = String(r.prefix(i))
        if i == l.count {
            // `left` is a prefix of `right`: extend it below right's next digit.
            guard let tail = below(Array(r[i...])) else { return nil }
            return prefix + tail
        }
        guard let li = digits.firstIndex(of: l[i]), let ri = digits.firstIndex(of: r[i]) else {
            return left + "U"
        }
        if ri - li > 1 { return prefix + String(digits[(li + ri) / 2]) }
        return left + "U"
    }

    /// A non-empty string below `rest` (non-empty), or nil when `rest` is all "0".
    /// A loop, not recursion: a synced rank can be any length (RC-0.1.0-602 T-03).
    private static func below(_ rest: [Character]) -> String? {
        var zeros = ""
        for character in rest {
            guard let index = digits.firstIndex(of: character) else { return zeros + "0" }
            if index > 1 { return zeros + String(digits[index / 2]) }
            if index == 1 { return zeros + "0U" }
            zeros += "0"
        }
        return nil
    }

    /// Ranks for `ranks` (display order) that strictly increase. Ranks on the
    /// longest increasing run are kept; the rest get ranks between their kept
    /// neighbours. Falls back to a fresh even spread when no gap fits.
    public static func normalized(_ ranks: [String]) -> [String] {
        guard !ranks.isEmpty else { return [] }
        let kept = longestIncreasingIndices(ranks)
        var result = ranks
        var index = 0
        while index < ranks.count {
            if kept.contains(index) {
                index += 1
                continue
            }
            var end = index
            while end < ranks.count, !kept.contains(end) { end += 1 }
            var current: String? = index > 0 ? result[index - 1] : nil
            let upper: String? = end < ranks.count ? result[end] : nil
            for slot in index ..< end {
                guard let next = between(current, upper) else { return LexoRank.initialSequence(count: ranks.count) }
                result[slot] = next
                current = next
            }
            index = end
        }
        return result
    }

    /// Indices of one longest strictly increasing subsequence of non-empty
    /// ranks (earliest such subsequence, so the choice is deterministic).
    static func longestIncreasingIndices(_ ranks: [String]) -> Set<Int> {
        let n = ranks.count
        var length = [Int](repeating: 0, count: n)
        var previous = [Int](repeating: -1, count: n)
        for i in 0 ..< n where !ranks[i].isEmpty {
            length[i] = 1
            for j in 0 ..< i where !ranks[j].isEmpty && ranks[j] < ranks[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        guard let best = length.indices.max(by: { length[$0] < length[$1] || (length[$0] == length[$1] && $0 > $1) }),
              length[best] > 0 else { return [] }
        var result = Set<Int>()
        var cursor = best
        while cursor >= 0 {
            result.insert(cursor)
            cursor = previous[cursor]
        }
        return result
    }
}
