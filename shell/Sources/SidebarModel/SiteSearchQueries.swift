import Foundation

/// One earlier query for a site search, found in history.
public struct SiteSearchQuery: Equatable, Sendable {
    public var text: String
    /// Visits of its result pages.
    public var count: Int
    public var lastUsed: Date

    public init(text: String, count: Int = 1, lastUsed: Date) {
        self.text = text
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// A shortcut's earlier queries, read out of the history the command bar
/// already may see (Chromium keeps a keyword's search terms the same way,
/// from its result pages). Nothing new is written: the queries are exactly
/// as private, as container-scoped and as clearable as that history. The
/// shell's visit store is per container and never records private windows;
/// on Chromium the profile's HistoryService (Clear Browsing Data) is read
/// too. Off-the-record profiles are never asked.
public enum SiteSearchQueries {
    /// Most queries kept for one shortcut.
    public static let limit = 50
    /// Most earlier queries listed for the typed text.
    public static let rowLimit = 6

    /// Every query whose result page is in `records`, merged by text
    /// (case-insensitive), best first (`ranked`), at most `limit`.
    public static func collect(_ records: [VisitRecord], template: String, now: Date = Date()) -> [SiteSearchQuery] {
        var byText: [String: SiteSearchQuery] = [:]
        for record in records {
            guard let text = SiteSearchTemplate.terms(in: record.url, template: template) else { continue }
            let key = text.lowercased()
            if var existing = byText[key] {
                existing.count += max(1, record.visitCount)
                if record.lastVisit > existing.lastUsed {
                    existing.lastUsed = record.lastVisit
                    existing.text = text
                }
                byText[key] = existing
            } else {
                byText[key] = SiteSearchQuery(text: text, count: max(1, record.visitCount), lastUsed: record.lastVisit)
            }
        }
        return Array(ranked(Array(byText.values), now: now).prefix(limit))
    }

    /// Most recent and most used first: visits weighted by age (Chromium's
    /// frecency buckets: this week counts most, past three months least),
    /// then the latest, then alphabetical.
    public static func ranked(_ queries: [SiteSearchQuery], now: Date = Date()) -> [SiteSearchQuery] {
        func score(_ query: SiteSearchQuery) -> Double {
            Double(query.count) * weight(age: now.timeIntervalSince(query.lastUsed))
        }
        return queries.sorted { lhs, rhs in
            let (l, r) = (score(lhs), score(rhs))
            if l != r { return l > r }
            if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
            return lhs.text < rhs.text
        }
    }

    static func weight(age: TimeInterval) -> Double {
        let days = age / 86_400
        switch days {
        case ..<4: return 100
        case ..<14: return 70
        case ..<31: return 50
        case ..<90: return 30
        default: return 10
        }
    }

    /// The queries for `typed`: those it begins, then those containing it,
    /// each in rank order. Empty text lists none (the bar is the field alone).
    public static func matching(_ typed: String, in queries: [SiteSearchQuery]) -> [SiteSearchQuery] {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let starts = queries.filter { $0.text.lowercased().hasPrefix(needle) }
        let contains = queries.filter { !$0.text.lowercased().hasPrefix(needle) && $0.text.lowercased().contains(needle) }
        return starts + contains
    }

    /// The best query `typed` is the start of (longer than it), for inline completion.
    public static func completion(for typed: String, in queries: [SiteSearchQuery]) -> String? {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let needle = typed.lowercased()
        return queries.first { $0.text.lowercased().hasPrefix(needle) && $0.text.count > typed.count }?.text
    }

    /// What follows the typed text in the field: the completion's own letters.
    public static func suffix(typed: String, completion: String) -> String? {
        guard completion.lowercased().hasPrefix(typed.lowercased()), completion.count > typed.count else { return nil }
        return String(completion.dropFirst(typed.count))
    }
}

extension CommandBarSearch {
    /// Rows while a site search chip is on: the query (completed when the
    /// field shows a completion) searching that site, then earlier queries
    /// for it, then the default engine's own suggestions when this site is
    /// that engine. Empty text gives none: the bar collapses to its field.
    /// Every row opens the entry's own template with its text.
    public static func siteSearchResults(_ engine: SiteSearchEngine, query: String, queries: [SiteSearchQuery] = [],
                                         suggestions: [SearchSuggestion] = [], completion: String? = nil) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen: Set<String> = []
        var rows: [Result] = []
        func add(_ text: String, kind: ResultKind) {
            guard seen.insert(text.lowercased()).inserted, let url = engine.url(for: text) else { return }
            rows.append(Result(id: "site-search-\(engine.id)-\(text.lowercased())", kind: kind, title: text,
                               subtitle: engine.displayHost, destinationURL: url, siteSearchID: engine.id))
        }
        // A completion stands for the typed text, as the field shows it.
        add(completion ?? trimmed, kind: .search)
        for earlier in SiteSearchQueries.matching(trimmed, in: queries).prefix(SiteSearchQueries.rowLimit) {
            add(earlier.text, kind: .history)
        }
        guard engine.suggestTemplate != nil else { return rows }
        var suggested = 0
        for suggestion in suggestions where suggested < suggestionLimit {
            let before = rows.count
            add(suggestion.text, kind: .suggestion)
            if rows.count > before { suggested += 1 }
        }
        return rows
    }
}
