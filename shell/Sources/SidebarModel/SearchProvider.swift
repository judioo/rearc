import Foundation

/// The command bar's default web search (Chromium `TemplateURL`). On
/// Chromium it comes from the profile's TemplateURLService through
/// `ReArcSearchGetDefaultProvider` (ABI 1.26, chrome://settings/search
/// changes it); on WebKit it is the shell preference (`SearchProviderPreference`).
public struct SearchProvider: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var keyword: String
    /// Search URL with `%s` where the terms go.
    public var searchTemplate: String
    /// OpenSearch suggestions URL with `%s`; nil when the engine has none.
    public var suggestTemplate: String?

    public init(id: String, name: String, keyword: String, searchTemplate: String, suggestTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.searchTemplate = searchTemplate
        self.suggestTemplate = suggestTemplate.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A usable template: http(s) with `%s`.
    public static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return false }
        return true
    }

    public func searchURL(for terms: String) -> URL? {
        Self.fill(searchTemplate, with: terms)
    }

    public func suggestURL(for terms: String) -> URL? {
        guard let template = suggestTemplate, let url = Self.fill(template, with: terms),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Replaces `%s` with the percent-encoded terms.
    static func fill(_ template: String, with terms: String) -> URL? {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidTemplate(template) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/;%")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    public static let duckDuckGo = SearchProvider(
        id: "duckduckgo", name: "DuckDuckGo", keyword: "duckduckgo.com",
        searchTemplate: "https://duckduckgo.com/?q=%s",
        suggestTemplate: "https://duckduckgo.com/ac/?q=%s&type=list"
    )
    public static let google = SearchProvider(
        id: "google", name: "Google", keyword: "google.com",
        searchTemplate: "https://www.google.com/search?q=%s",
        suggestTemplate: "https://www.google.com/complete/search?client=firefox&q=%s"
    )
    public static let bing = SearchProvider(
        id: "bing", name: "Bing", keyword: "bing.com",
        searchTemplate: "https://www.bing.com/search?q=%s",
        suggestTemplate: "https://api.bing.com/osjson.aspx?query=%s"
    )
    public static let ecosia = SearchProvider(
        id: "ecosia", name: "Ecosia", keyword: "ecosia.org",
        searchTemplate: "https://www.ecosia.org/search?q=%s",
        suggestTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
    )
    public static let brave = SearchProvider(
        id: "brave", name: "Brave Search", keyword: "search.brave.com",
        searchTemplate: "https://search.brave.com/search?q=%s",
        suggestTemplate: "https://search.brave.com/api/suggest?q=%s"
    )

    /// The WebKit path's choices; DuckDuckGo stays the default, as before wave 23.
    public static let builtIn: [SearchProvider] = [.duckDuckGo, .google, .bing, .ecosia, .brave]
}

/// WebKit's search settings, remembered in user defaults. Chromium keeps
/// its own in the profile (chrome://settings/search).
public struct SearchProviderPreference: Equatable, Sendable {
    public static let providerKey = "ReArcSearchProvider"
    public static let suggestionsKey = "ReArcSearchSuggestions"

    public var providerID: String
    /// Ask the provider's suggest endpoint as you type (never in private windows).
    public var suggestionsEnabled: Bool

    public init(providerID: String = SearchProvider.duckDuckGo.id, suggestionsEnabled: Bool = true) {
        self.providerID = providerID
        self.suggestionsEnabled = suggestionsEnabled
    }

    public var provider: SearchProvider {
        SearchProvider.builtIn.first { $0.id == providerID } ?? .duckDuckGo
    }

    public static func load(from defaults: UserDefaults) -> SearchProviderPreference {
        SearchProviderPreference(
            providerID: defaults.string(forKey: providerKey) ?? SearchProvider.duckDuckGo.id,
            suggestionsEnabled: defaults.object(forKey: suggestionsKey) as? Bool ?? true
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(providerID, forKey: Self.providerKey)
        defaults.set(suggestionsEnabled, forKey: Self.suggestionsKey)
    }
}

/// Parses an OpenSearch suggestions response, `["terms", ["s1", "s2", …], …]`,
/// which every built-in provider's suggest endpoint returns.
public enum SearchSuggestionParser {
    public static let limit = 6

    public static func parse(_ data: Data, limit: Int = limit) -> [String] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], array.count >= 2,
              let items = array[1] as? [Any] else { return [] }
        var seen: Set<String> = []
        var output: [String] = []
        for case let text as String in items {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            output.append(trimmed)
            if output.count == limit { break }
        }
        return output
    }
}
