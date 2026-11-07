import Foundation

/// Prepared text for a history snapshot. Build when history changes, rather
/// than lowercasing URLs and splitting 5,000 titles on every keystroke.
/// Scores and tie breaks are identical to `VisitHistory.matches`.
public struct VisitHistorySearchIndex: Sendable {
    /// Immutable, so a scan retains one reference per page rather than
    /// copying a dozen fields, and history snapshots share them.
    private final class Entry: Sendable {
        let key: String
        let record: VisitRecord
        let title: PreparedText
        let host: PreparedText
        let bareHost: PreparedText
        let address: PreparedText
        /// `log2(visitCount + 1)`, the frecency's visit term.
        let visits: Double
        /// `record.url.absoluteString`, the last tie break.
        let urlString: String

        init(key: String, record: VisitRecord) {
            self.key = key
            self.record = record
            let host = (record.url.host() ?? "").lowercased()
            title = PreparedText(record.title.lowercased())
            self.host = PreparedText(host)
            bareHost = PreparedText(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            address = PreparedText(VisitHistory.strippedAddress(record.url))
            visits = log2(Double(record.visitCount) + 1)
            urlString = record.url.absoluteString
        }

        func quality(tokens: [PreparedText.Needle]) -> Double? {
            guard let first = tokens.first else { return nil }
            for token in tokens where !title.contains(token) && !address.contains(token) { return nil }
            if bareHost.hasPrefix(first) || host.hasPrefix(first) { return 4 }
            if address.hasPrefix(first) { return 3.5 }
            if title.hasWord(withPrefix: first) { return 2.5 }
            if title.contains(first) { return 1.5 }
            return 1
        }
    }

    /// Contiguous for the scan; `positions` finds a page's slot for writes.
    private var entries: [Entry]
    private var positions: [String: Int]

    public init(history: VisitHistory) {
        self = history.searchIndex
    }

    init(records: [String: VisitRecord]) {
        entries = []
        positions = [:]
        entries.reserveCapacity(records.count)
        positions.reserveCapacity(records.count)
        for (key, record) in records { update(record, for: key) }
    }

    /// History writes prepare just the changed page. Loading prepares the
    /// snapshot once, so even the first keystroke does no index construction.
    mutating func update(_ record: VisitRecord?, for key: String) {
        guard let record else {
            // Order does not matter: ranking is a total order.
            guard let position = positions.removeValue(forKey: key) else { return }
            let last = entries.removeLast()
            if position < entries.count {
                entries[position] = last
                positions[last.key] = position
            }
            return
        }
        let entry = Entry(key: key, record: record)
        if let position = positions[key] {
            entries[position] = entry
        } else {
            positions[key] = entries.count
            entries.append(entry)
        }
    }

    public func matches(for needle: String, now: Date, limit: Int = 5, excluding excluded: Set<String> = []) -> [VisitHistory.Match] {
        let tokens = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).map { PreparedText.Needle(String($0)) }
        guard !tokens.isEmpty, limit > 0 else { return [] }
        // Keep just the requested prefix, with the same total ordering as the
        // full sort (score, then newest, then URL). The command bar asks for five.
        var best: [(score: Double, entry: Entry)] = []
        let checksExclusions = !excluded.isEmpty
        best.reserveCapacity(limit + 1)
        func precedes(_ score: Double, _ entry: Entry, _ other: (score: Double, entry: Entry)) -> Bool {
            if score != other.score { return score > other.score }
            if entry.record.lastVisit != other.entry.record.lastVisit { return entry.record.lastVisit > other.entry.record.lastVisit }
            return entry.urlString < other.entry.urlString
        }
        for entry in entries {
            guard let quality = entry.quality(tokens: tokens), !checksExclusions || !excluded.contains(entry.key) else { continue }
            // `VisitHistory.frecency`, with the visit term prepared.
            let age = max(now.timeIntervalSince(entry.record.lastVisit), 0)
            let score = quality * (VisitHistory.recencyWeight(age: age) * entry.visits + 1)
            if best.count == limit, let last = best.last, !precedes(score, entry, last) { continue }
            let insertion = best.firstIndex { precedes(score, entry, $0) } ?? best.count
            best.insert((score, entry), at: insertion)
            if best.count > limit { best.removeLast() }
        }
        return best.map { VisitHistory.Match(record: $0.entry.record, score: $0.score) }
    }
}
