import Foundation

/// Which URLs trusted shell UI (command bar, menus) may hand to an engine.
/// The base set is what every engine loads; Chromium (ABI 1.5,
/// `navigation_extended`) additionally admits audited WebUI and view-source,
/// mirroring `ReArcTabNavigate` admission in engine/docs/C-ABI.md.
public enum NavigationURLPolicy {
    /// Engine-specific additions to the base set.
    public struct EngineSchemes: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// `chrome://settings` and `chrome://version` only.
        public static let trustedWebUI = EngineSchemes(rawValue: 1)
        /// One `view-source:` wrapper around an http(s) or file URL.
        public static let viewSource = EngineSchemes(rawValue: 2)
        public static let chromium: EngineSchemes = [.trustedWebUI, .viewSource]
    }

    /// The only WebUI hosts the engine has audited for browser-less tabs.
    public static let trustedWebUIHosts: Set<String> = ["settings", "version"]

    private static let baseSchemes: Set<String> = ["http", "https", "data", "file"]
    private static let viewSourceTargets: Set<String> = ["http", "https", "file"]
    private static let viewSourcePrefix = "view-source:"

    public static func allows(_ url: URL, engine: EngineSchemes = []) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        if baseSchemes.contains(scheme) { return true }
        switch scheme {
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
        case "chrome":
            guard engine.contains(.trustedWebUI), let host = url.host()?.lowercased() else { return false }
            return trustedWebUIHosts.contains(host)
        case "view-source":
            guard engine.contains(.viewSource) else { return false }
            let inner = String(url.absoluteString.dropFirst(viewSourcePrefix.count))
            guard let target = URL(string: inner), let targetScheme = target.scheme?.lowercased() else { return false }
            return viewSourceTargets.contains(targetScheme)
        default:
            return false
        }
    }

    /// `view-source:` URL for a page, when the engine can show its source.
    public static func viewSourceURL(for url: URL, engine: EngineSchemes) -> URL? {
        guard engine.contains(.viewSource),
              let scheme = url.scheme?.lowercased(),
              viewSourceTargets.contains(scheme),
              let wrapped = URL(string: viewSourcePrefix + url.absoluteString) else { return nil }
        return wrapped
    }
}
