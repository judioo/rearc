import Foundation

/// One site the command bar can search (Arc site search, COMMAND-BAR §4.2).
/// Typing its keyword, the start of its name, or a word that completes to
/// its site, then Tab, turns the bar into a scoped search: a chip tinted
/// with the site's colour, and Return searches that site instead of the
/// default engine. The chip, hint and URL come from this entry (the seeded
/// list, the profile's engines, or another browser's imported keywords),
/// never from a page.
public struct SiteSearchEngine: Identifiable, Hashable, Sendable {
    /// Where an entry comes from; earlier sources win a duplicate.
    public enum Source: String, Codable, Hashable, Sendable {
        /// Imported from another browser's `Web Data` keywords (the person's own).
        case imported
        /// The profile's search engines as Chromium lists them.
        case engine
        /// ReArc's own list (Arc `seededPopularSiteSearches`).
        case seeded
    }

    public var id: String
    public var name: String
    /// Chromium's keyword ("cwc", "youtube.com"): typed exactly, it offers this site first.
    public var keyword: String?
    /// Lowercased words that trigger it besides the name (e.g. "yt").
    public var aliases: [String]
    /// The host without "www.", also a trigger ("github.com").
    public var domain: String
    /// Search URL with `%s` where the query goes (`SiteSearchTemplate.validated`).
    public var template: String
    /// The chip's colour when the entry knows it (Arc `loadedSiteSearchDominantColor`);
    /// nil takes the site's favicon colour, else the space's accent.
    public var color: SpaceColor?
    public var source: Source
    /// The hint's verb: "Search cushwake", "Ask ChatGPT".
    public var verb: String
    /// The field's placeholder while the chip is on.
    public var placeholder: String
    /// The engine's suggest URL (`%s`) for this entry. Only the profile's
    /// default engine has one the shell may use; nothing else asks a site.
    public var suggestTemplate: String?

    public init(id: String, name: String, keyword: String? = nil, aliases: [String] = [], domain: String, template: String,
                color: SpaceColor? = nil, source: Source = .seeded, verb: String = "Search", placeholder: String = "Search…",
                suggestTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.keyword = keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.aliases = aliases
        self.domain = domain
        self.template = template
        self.color = color
        self.source = source
        self.verb = verb
        self.placeholder = placeholder
        self.suggestTemplate = suggestTemplate
    }

    /// An entry from a keyword row (the engine's list, another browser's
    /// `Web Data`): nil unless the template passes `SiteSearchTemplate.validated`.
    public init?(keywordRowID id: String, name: String, keyword: String, template: String, source: Source,
                 suggestTemplate: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let template = SiteSearchTemplate.validated(template), let host = SiteSearchTemplate.host(of: template),
              !name.isEmpty, name.count <= SiteSearchTemplate.maxNameLength,
              keyword.count <= SiteSearchTemplate.maxNameLength, !keyword.contains(where: \.isWhitespace) else { return nil }
        self.init(id: id, name: name, keyword: keyword.isEmpty ? nil : keyword, domain: host, template: template,
                  source: source, suggestTemplate: suggestTemplate.flatMap(SiteSearchTemplate.validated))
    }

    /// The site's search page for `query`, or its home page for an empty query.
    public func url(for query: String) -> URL? {
        SiteSearchTemplate.expand(template, query: query)
    }

    /// "Search cushwake", "Ask ChatGPT".
    public var hint: String { "\(verb) \(name)" }

    /// The host the query goes to, as the selected row shows it.
    public var displayHost: String { SiteSearchTemplate.host(of: template) ?? domain }

    /// Words the typed text may be the start of.
    var triggers: [String] {
        [name.lowercased(), domain] + aliases + (keyword.map { [$0] } ?? [])
    }
}

/// Search URL templates as Chromium keeps them (`TemplateURLRef`), reduced
/// to the part ReArc fills in: the terms.
public enum SiteSearchTemplate {
    public static let slot = "%s"
    /// Longer templates and names are not someone's site search.
    public static let maxLength = 2048
    public static let maxNameLength = 100

    /// Chromium's parameters that are safe to fix; any other `{…}` rejects the template.
    static let fixedParameters = ["{inputEncoding}": "UTF-8", "{outputEncoding}": "UTF-8", "{language}": "en"]

    /// `raw` with `{searchTerms}` as `%s`, or nil: only http(s) with a host,
    /// at least one slot after the host, no credentials, whitespace or
    /// unresolved parameters, at most `maxLength` characters. A
    /// `javascript:` or `data:` template never passes.
    public static func validated(_ raw: String) -> String? {
        var template = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty, template.count <= maxLength,
              !template.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        template = template.replacingOccurrences(of: "{searchTerms}", with: slot)
        for (parameter, value) in fixedParameters { template = template.replacingOccurrences(of: parameter, with: value) }
        guard template.contains(slot), !template.contains("{"), !template.contains("}"),
              let a = URLComponents(string: template.replacingOccurrences(of: slot, with: "a")),
              let b = URLComponents(string: template.replacingOccurrences(of: slot, with: "b")),
              let scheme = a.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = a.host, !host.isEmpty, a.user == nil, a.password == nil,
              // The terms never reach the scheme, host or port.
              a.host == b.host, a.port == b.port, a.scheme == b.scheme else { return nil }
        return template
    }

    /// The template's host without "www.".
    public static func host(of template: String) -> String? {
        guard let host = URLComponents(string: template.replacingOccurrences(of: slot, with: "q"))?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The template filled with `query` the way Chromium encodes terms
    /// (`TemplateURLRef::ReplaceSearchTerms`): in the query string a space
    /// becomes "+", in the path "%20"; everything but ASCII letters, digits
    /// and `-_.!~*'()` is percent-encoded, so the terms cannot add
    /// parameters or path segments. An empty query opens the site.
    public static func expand(_ template: String, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template = validated(template) else { return nil }
        guard !trimmed.isEmpty else {
            guard let url = URLComponents(string: template.replacingOccurrences(of: slot, with: "")),
                  let scheme = url.scheme, let host = url.host else { return nil }
            return URL(string: "\(scheme.lowercased())://\(host.lowercased())/")
        }
        var output = ""
        var rest = Substring(template)
        while let range = rest.range(of: slot) {
            let before = rest[..<range.lowerBound]
            output += before
            let inQuery = output.contains("?")
            guard let encoded = encode(trimmed, inQuery: inQuery) else { return nil }
            output += encoded
            rest = rest[range.upperBound...]
        }
        output += rest
        return URL(string: output)
    }

    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")

    static func encode(_ terms: String, inQuery: Bool) -> String? {
        if inQuery {
            return terms.split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
                .joined(separator: "+")
        }
        return terms.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// The terms in `url` when it is this template's search page (the way
    /// Chromium finds a keyword's search terms in history): the same host
    /// (with or without "www.") and path, and the slot's query parameter or
    /// path segment present. Nil for any other page.
    public static func terms(in url: URL, template: String) -> String? {
        let marker = "rearcslot"
        guard let template = validated(template),
              let shape = URLComponents(string: template.replacingOccurrences(of: slot, with: marker)),
              let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let pageHost = page.host?.lowercased(), let host = host(of: template),
              pageHost == host || pageHost == "www." + host else { return nil }
        let raw: String?
        if let item = shape.percentEncodedQueryItems?.first(where: { $0.value?.contains(marker) == true }) {
            guard trimmedPath(page.percentEncodedPath) == trimmedPath(shape.percentEncodedPath),
                  let value = page.percentEncodedQueryItems?.first(where: { $0.name == item.name })?.value,
                  let pattern = item.value else { return nil }
            raw = between(value, pattern: pattern, marker: marker)
        } else if shape.percentEncodedPath.contains(marker) {
            raw = between(page.percentEncodedPath, pattern: shape.percentEncodedPath, marker: marker)
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let text = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text.count > maxLength ? nil : text
    }

    private static func trimmedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// What `value` has where `pattern` has `marker`.
    private static func between(_ value: String, pattern: String, marker: String) -> String? {
        guard let range = pattern.range(of: marker) else { return nil }
        let prefix = String(pattern[..<range.lowerBound]), suffix = String(pattern[range.upperBound...])
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count >= prefix.count + suffix.count else { return nil }
        return String(value.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

/// The seeded site searches (Arc `seededPopularSiteSearches`) and the
/// matching rule for the Tab trigger (`migratedToTabOnlySiteSearchTrigger`).
public enum SiteSearchCatalog {

    private static func rgb(_ hex: UInt32) -> SpaceColor {
        SpaceColor(
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
        // Arc's "Ask ChatGPT" entry (`gptSiteSearch`): ChatGPT opens a new chat
        // with `q` as the first message. The colour is Arc's chip, measured
        // (#579F8F, 2026-11-12 recording).
        SiteSearchEngine(id: "chatgpt", name: "ChatGPT", aliases: ["gpt"], domain: "chatgpt.com",
                         template: "https://chatgpt.com/?q=%s", color: rgb(0x579F8F),
                         verb: "Ask", placeholder: "Send a Message…"),
        SiteSearchEngine(id: "perplexity", name: "Perplexity", domain: "perplexity.ai",
                         template: "https://www.perplexity.ai/search?q=%s", color: rgb(0x20808D),
                         verb: "Ask", placeholder: "Ask anything…"),
    ]

    /// Shortest text that offers a site by name (one letter matches too much).
    public static let minimumLength = 2

    /// One list from every source: imported first (the person's own
    /// keywords), then the profile's engines, then the seeded list. A later
    /// entry for the same search page (host and path) or the same keyword
    /// is dropped, but lends the kept one its colour, verb and placeholder
    /// when that has none of its own, and its keyword as an alias.
    public static func merged(imported: [SiteSearchEngine] = [], engine: [SiteSearchEngine] = [],
                              seeded: [SiteSearchEngine] = seeded) -> [SiteSearchEngine] {
        var kept: [SiteSearchEngine] = []
        var byPage: [String: Int] = [:]
        var byKeyword: [String: Int] = [:]
        for entry in imported + engine + seeded {
            let page = pageKey(entry.template)
            if let index = byPage[page] ?? entry.keyword.flatMap({ byKeyword[$0] }) {
                var existing = kept[index]
                if existing.color == nil { existing.color = entry.color }
                if existing.verb == "Search", entry.verb != "Search" {
                    existing.verb = entry.verb
                    existing.placeholder = entry.placeholder
                }
                for word in entry.aliases + [entry.keyword, entry.name.lowercased()].compactMap({ $0 })
                where !existing.triggers.contains(word) { existing.aliases.append(word) }
                kept[index] = existing
                continue
            }
            byPage[page] = kept.count
            if let keyword = entry.keyword, byKeyword[keyword] == nil { byKeyword[keyword] = kept.count }
            kept.append(entry)
        }
        return kept
    }

    /// The template's host (without "www.") and path: two templates for the same search page.
    static func pageKey(_ template: String) -> String {
        guard let parts = URLComponents(string: template.replacingOccurrences(of: SiteSearchTemplate.slot, with: "q")) else {
            return template.lowercased()
        }
        var host = parts.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + parts.path.lowercased()
    }

    /// The site a single typed word offers, if any: an exact keyword first
    /// (Chromium's keyword mode, "cwc"), then the site the field completes
    /// to (`completedHost`, "chatgpt.com" for "chat"), then an exact name,
    /// alias or domain, then the shortest name it begins. A leading "www."
    /// is ignored; text with spaces, a scheme or a path is never a trigger.
    public static func match(_ text: String, in engines: [SiteSearchEngine] = seeded, completedHost: String? = nil) -> SiteSearchEngine? {
        var word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if word.hasPrefix("www.") { word.removeFirst(4) }
        guard !word.isEmpty, !word.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        if let exact = engines.first(where: { $0.keyword == word }) { return exact }
        if var host = completedHost?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if let site = engines.first(where: { $0.domain == host }) { return site }
        }
        guard word.count >= minimumLength else { return nil }
        if let exact = engines.first(where: { $0.triggers.contains(word) }) { return exact }
        return engines
            .filter { $0.triggers.contains { $0.hasPrefix(word) } }
            .min { $0.name.count < $1.name.count }
    }
}

extension SearchEngineChoices {
    /// The profile's engines as site searches (keyword, name, template). The
    /// default engine carries its suggest URL when `defaultProvider` has one.
    public func siteSearchEngines(defaultProvider: SearchProvider? = nil) -> [SiteSearchEngine] {
        engines.compactMap { engine in
            let suggest = defaultProvider.flatMap { provider in
                SiteSearchCatalog.pageKey(provider.searchTemplate) == SiteSearchCatalog.pageKey(engine.searchTemplate)
                    ? provider.suggestTemplate : nil
            }
            return SiteSearchEngine(keywordRowID: "engine-\(engine.id)", name: engine.name, keyword: engine.keyword,
                                    template: engine.searchTemplate, source: .engine, suggestTemplate: suggest)
        }
    }
}

extension SearchProvider {
    /// The default engine as a site search, with its suggest URL.
    public var siteSearchEngine: SiteSearchEngine? {
        SiteSearchEngine(keywordRowID: "default-\(id)", name: name, keyword: keyword, template: searchTemplate,
                         source: .engine, suggestTemplate: suggestTemplate)
    }
}
