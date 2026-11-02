import Foundation

/// Subsequence fuzzy matching for command-bar TypeTravel-style commands.
public enum TypeTravelFuzzyMatch {

    public struct Match: Equatable {
        public var score: Int
        public var haystackLength: Int
    }

    /// Returns a match score when `query` is a subsequence of `haystack` (case-insensitive).
    public static func match(query: String, in haystack: String) -> Match? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let h = haystack.lowercased()
        guard !q.isEmpty, !h.isEmpty else { return nil }

        var score = 0
        var qi = q.startIndex
        var hi = h.startIndex
        var prevMatched = false
        var consecutiveRun = 0

        while qi < q.endIndex, hi < h.endIndex {
            if q[qi] == h[hi] {
                score += 10
                if prevMatched {
                    consecutiveRun += 1
                    score += 8 + consecutiveRun
                } else {
                    consecutiveRun = 0
                }
                if isWordBoundary(in: h, at: hi) {
                    score += 12
                }
                prevMatched = true
                qi = q.index(after: qi)
                hi = h.index(after: hi)
            } else {
                prevMatched = false
                consecutiveRun = 0
                hi = h.index(after: hi)
            }
        }

        guard qi == q.endIndex else { return nil }

        score += max(0, 40 - h.count)
        return Match(score: score, haystackLength: h.count)
    }

    /// Best score across title and keyword triggers.
    public static func bestScore(query: String, title: String, keywords: [String]) -> Match? {
        var best: Match?
        if let m = match(query: query, in: title) {
            best = m
        }
        for keyword in keywords {
            guard let m = match(query: query, in: keyword) else { continue }
            if best == nil || m.score > best!.score
                || (m.score == best!.score && m.haystackLength < best!.haystackLength) {
                best = m
            }
        }
        return best
    }

    private static func isWordBoundary(in text: String, at index: String.Index) -> Bool {
        if index == text.startIndex { return true }
        let prev = text.index(before: index)
        let ch = text[index]
        let prevCh = text[prev]
        return !prevCh.isLetter && !prevCh.isNumber && ch.isLetter
    }
}
