import Foundation

/// One site the command bar can search (Arc site search, COMMAND-BAR §4.2).
/// Typing the start of its name and pressing Tab turns the bar into a
/// scoped search: a pill tinted with the site's colour, and Enter searches
/// that site instead of the default engine.
public struct SiteSearchEngine: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Lowercased words that trigger it besides the name (e.g. "yt").
    public var aliases: [String]
    /// Registrable domain, also a trigger ("github.com").
    public var domain: String
    /// Search URL with `%s` where the query goes.
    public var template: String
    /// Pill colour (Arc `loadedSiteSearchDominantColor`).
    public var color: SpaceTheme

    public init(id: String, name: String, aliases: [String] = [], domain: String, template: String, color: SpaceTheme) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.domain = domain
        self.template = template
        self.color = color
    }

    /// The site's search page for `query`, or its home page for an empty query.
    public func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return URL(string: "https://\(domain)/") }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Words the typed text may be the start of.
    var triggers: [String] {
        [name.lowercased(), domain] + aliases
    }
}

/// The seeded site searches (Arc `seededPopularSiteSearches`) and the
/// matching rule for the Tab trigger (`migratedToTabOnlySiteSearchTrigger`).
public enum SiteSearchCatalog {

    private static func rgb(_ hex: UInt32) -> SpaceTheme {
        SpaceTheme(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    public static let seeded: [SiteSearchEngine] = [
        SiteSearchEngine(id: "google", name: "Google", domain: "google.com",
                         template: "https://www.google.com/search?q=%s", color: rgb(0x4285F4)),
        SiteSearchEngine(id: "youtube", name: "YouTube", aliases: ["yt"], domain: "youtube.com",
                         template: "https://www.youtube.com/results?search_query=%s", color: rgb(0xFF0033)),
        SiteSearchEngine(id: "wikipedia", name: "Wikipedia", aliases: ["wiki"], domain: "wikipedia.org",
                         template: "https://en.wikipedia.org/wiki/Special:Search?search=%s", color: rgb(0x636466)),
        SiteSearchEngine(id: "github", name: "GitHub", aliases: ["gh"], domain: "github.com",
                         template: "https://github.com/search?q=%s", color: rgb(0x24292F)),
        SiteSearchEngine(id: "amazon", name: "Amazon", domain: "amazon.com",
                         template: "https://www.amazon.com/s?k=%s", color: rgb(0xFF9900)),
        SiteSearchEngine(id: "reddit", name: "Reddit", domain: "reddit.com",
                         template: "https://www.reddit.com/search/?q=%s", color: rgb(0xFF4500)),
        SiteSearchEngine(id: "maps", name: "Google Maps", aliases: ["maps"], domain: "maps.google.com",
                         template: "https://www.google.com/maps/search/%s", color: rgb(0x34A853)),
        SiteSearchEngine(id: "x", name: "X", aliases: ["twitter"], domain: "x.com",
                         template: "https://x.com/search?q=%s", color: rgb(0x111111)),
        SiteSearchEngine(id: "stackoverflow", name: "Stack Overflow", aliases: ["so"], domain: "stackoverflow.com",
                         template: "https://stackoverflow.com/search?q=%s", color: rgb(0xF48024)),
        SiteSearchEngine(id: "mdn", name: "MDN", domain: "developer.mozilla.org",
                         template: "https://developer.mozilla.org/en-US/search?q=%s", color: rgb(0x1B1B1B)),
        SiteSearchEngine(id: "npm", name: "npm", domain: "npmjs.com",
                         template: "https://www.npmjs.com/search?q=%s", color: rgb(0xCB3837)),
        SiteSearchEngine(id: "duckduckgo", name: "DuckDuckGo", aliases: ["ddg"], domain: "duckduckgo.com",
                         template: "https://duckduckgo.com/?q=%s", color: rgb(0xDE5833)),
        SiteSearchEngine(id: "imdb", name: "IMDb", domain: "imdb.com",
                         template: "https://www.imdb.com/find/?q=%s", color: rgb(0xF5C518)),
    ]

    /// Shortest text that offers a site (one letter matches too much).
    public static let minimumLength = 2

    /// The site a single typed word starts, if any: an exact name or alias
    /// first, then the shortest name it begins. A leading "www." is ignored;
    /// text with spaces, a scheme or a path is never a trigger.
    public static func match(_ text: String, in engines: [SiteSearchEngine] = seeded) -> SiteSearchEngine? {
        var word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if word.hasPrefix("www.") { word.removeFirst(4) }
        guard word.count >= minimumLength,
              !word.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        if let exact = engines.first(where: { $0.triggers.contains(word) }) { return exact }
        return engines
            .filter { $0.triggers.contains { $0.hasPrefix(word) } }
            .min { $0.name.count < $1.name.count }
    }
}

extension CommandBarSearch {
    /// Rows while a site search pill is active: one row, searching that site.
    public static func siteSearchResults(_ engine: SiteSearchEngine, query: String) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = engine.url(for: trimmed) else { return [] }
        return [Result(
            id: "site-search-\(engine.id)",
            kind: .search,
            title: trimmed.isEmpty ? "Open \(engine.name)" : "Search \(engine.name) for “\(trimmed)”",
            subtitle: url.absoluteString,
            destinationURL: url
        )]
    }
}
