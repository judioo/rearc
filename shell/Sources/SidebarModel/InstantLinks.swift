import Foundation

/// Max › Instant Links (MAX.md §6): Shift + Return on a search in the
/// command bar opens the top result instead of the results page, and
/// comma-separated searches open a tab each. It uses the search engine's
/// own "first result" address where the engine has one (DuckDuckGo's
/// backslash, Google's I'm Feeling Lucky); for any other engine it opens
/// the normal results page. Nothing else is fetched or read.
public enum InstantLinks {
    /// Searches one Shift + Return opens at most; more are dropped and the bar says so.
    public static let maximumQueries = 5
    static let maximumQueryLength = 400

    public struct Plan: Equatable, Sendable {
        public var queries: [String]
        /// Searches past `maximumQueries`, not opened.
        public var dropped: Int

        public var cappedMessage: String? {
            dropped > 0 ? "Opened the first \(InstantLinks.maximumQueries) searches; \(dropped) more were left out." : nil
        }
    }

    /// The searches in what was typed: split at commas, trimmed, blanks and
    /// repeats dropped, at most five. One search with no comma is one query.
    public static func plan(for text: String) -> Plan {
        var seen = Set<String>()
        var queries: [String] = []
        for piece in text.split(separator: ",") {
            let query = String(TidyText.singleLine(String(piece)).prefix(maximumQueryLength))
            guard !query.isEmpty, seen.insert(query.lowercased()).inserted else { continue }
            queries.append(query)
        }
        let dropped = max(queries.count - maximumQueries, 0)
        return Plan(queries: Array(queries.prefix(maximumQueries)), dropped: dropped)
    }

    /// How an engine opens its first result.
    public enum Route: Equatable, Sendable {
        /// The engine's own first-result address.
        case firstResult(URL)
        /// No such address: its results page.
        case resultsPage(URL)

        public var url: URL {
            switch self {
            case .firstResult(let url), .resultsPage(let url): return url
            }
        }
    }

    /// Engines with a first-result address, by their search host.
    public enum Engine: String, CaseIterable, Sendable {
        /// "\\query": DuckDuckGo's documented "go to the first result".
        case duckDuckGo
        /// `btnI`: Google's "I'm Feeling Lucky". Google may show its own
        /// redirect notice first; that is Google's page.
        case google

        public var name: String {
            switch self {
            case .duckDuckGo: return "DuckDuckGo"
            case .google: return "Google"
            }
        }

        static func matching(_ provider: SearchProvider) -> Engine? {
            guard let host = URL(string: provider.searchTemplate.replacingOccurrences(of: "%s", with: "q"))?.host()?.lowercased() else { return nil }
            if host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") { return .duckDuckGo }
            let parts = host.split(separator: ".")
            if parts.contains("google"), !host.hasPrefix("scholar."), !host.hasPrefix("maps.") { return .google }
            return nil
        }
    }

    /// Where Shift + Return sends `query` with the profile's default engine.
    public static func route(for query: String, provider: SearchProvider) -> Route? {
        guard let results = provider.searchURL(for: query) else { return nil }
        switch Engine.matching(provider) {
        case .duckDuckGo:
            return provider.searchURL(for: "\\" + query).map(Route.firstResult) ?? .resultsPage(results)
        case .google:
            guard var parts = URLComponents(url: results, resolvingAgainstBaseURL: false) else { return .resultsPage(results) }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "btnI", value: "1")]
            return parts.url.map(Route.firstResult) ?? .resultsPage(results)
        case nil:
            return .resultsPage(results)
        }
    }

    /// One route per search, in order.
    public static func routes(for text: String, provider: SearchProvider) -> (routes: [Route], plan: Plan) {
        let plan = plan(for: text)
        return (plan.queries.compactMap { route(for: $0, provider: provider) }, plan)
    }
}
