import Foundation

/// Resolves free-form command-bar input into a URL: full URLs pass through,
/// bare hosts get an https:// scheme, and anything else becomes a web search
/// with `provider` (the engine's default search on Chromium, the shell
/// preference on WebKit).
public enum URLEntry {
    public static func resolve(
        _ input: String,
        engine: NavigationURLPolicy.EngineSchemes = [],
        provider: SearchProvider = .duckDuckGo
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            guard NavigationURLPolicy.allows(url, engine: engine) else { return nil }
            return url
        }

        if !trimmed.contains(" "), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }

        return searchURL(for: trimmed, provider: provider)
    }

    /// The web search for `text` (command bar fallback, "Search for …" in the page menu).
    public static func searchURL(for text: String, provider: SearchProvider = .duckDuckGo) -> URL? {
        provider.searchURL(for: text)
    }
}
