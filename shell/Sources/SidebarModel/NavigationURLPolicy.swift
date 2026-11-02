import Foundation

public enum NavigationURLPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "about", "file"]

    public static func isAllowedNavigationScheme(_ scheme: String) -> Bool {
        allowedSchemes.contains(scheme.lowercased())
    }

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return isAllowedNavigationScheme(scheme)
    }
}
