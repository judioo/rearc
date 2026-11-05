import Foundation

/// Prepared text for a history snapshot. Build when history changes, rather
/// than lowercasing URLs and splitting 5,000 titles on every keystroke.
/// Scores and tie breaks are identical to `VisitHistory.matches`.
public struct VisitHistorySearchIndex: Sendable {
    private struct Entry: Sendable {
        var key: String
        var record: VisitRecord
        var title: String
        var host: String
        var bareHost: String
        var address: String
        var words: [Substring]

        func quality(tokens: [String]) -> Double? {
            guard let first = tokens.first else { return nil }
            for token in tokens where !title.contains(token) && !address.contains(token) { return nil }
            if bareHost.hasPrefix(first) || host.hasPrefix(first) { return 4 }
            if address.hasPrefix(first) { return 3.5 }
            if words.contains(where: { $0.hasPrefix(first) }) { return 2.5 }
            if title.contains(first) { return 1.5 }
            return 1
        }
    }

    private var entries: [String: Entry]

    public init(history: VisitHistory) {
        self = history.searchIndex
    }

    init(records: [String: VisitRecord]) {
        entries = [:]
        entries.reserveCapacity(records.count)
        for (key, record) in records { update(record, for: key) }
    }

    /// History writes prepare just the changed page. Loading prepares the
    /// snapshot once, so even the first keystroke does no index construction.
    mutating func update(_ record: VisitRecord?, for key: String) {
        guard let record else { entries[key] = nil; return }
        let title = record.title.lowercased()
        let host = (record.url.host() ?? "").lowercased()
        entries[key] = Entry(key: key, record: record, title: title, host: host,
                             bareHost: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                             address: VisitHistory.strippedAddress(record.url),
                             words: title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
    }

    public func matches(for needle: String, now: Date, limit: Int = 5, excluding excluded: Set<String> = []) -> [VisitHistory.Match] {
        let tokens = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        var best: [VisitHistory.Match] = []
        func precedes(_ lhs: VisitHistory.Match, _ rhs: VisitHistory.Match) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.record.lastVisit != rhs.record.lastVisit { return lhs.record.lastVisit > rhs.record.lastVisit }
            return lhs.record.url.absoluteString < rhs.record.url.absoluteString
        }
        for entry in entries.values where !excluded.contains(entry.key) {
            guard let quality = entry.quality(tokens: tokens) else { continue }
            let match = VisitHistory.Match(record: entry.record, score: quality * (VisitHistory.frecency(entry.record, now: now) + 1))
            // Keep just the requested prefix, with the same total ordering as
            // the full sort. The command bar requests five rows.
            let insertion = best.firstIndex { precedes(match, $0) } ?? best.count
            if insertion < limit {
                best.insert(match, at: insertion)
                if best.count > limit { best.removeLast() }
            }
        }
        return best
    }
}
