import Foundation

/// Resolves free-form command-bar input into a URL: full URLs pass through,
/// bare hosts get an https:// scheme, and anything else becomes a web search.
public enum URLEntry {
    public static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            guard NavigationURLPolicy.isAllowedNavigationScheme(scheme) else { return nil }
            return url
        }

        if !trimmed.contains(" "), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}
