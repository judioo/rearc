import Foundation

/// Which URLs trusted shell UI (command bar, menus) may hand to an engine.
/// The base set is what every engine loads; Chromium (ABI 1.5,
/// `navigation_extended`) additionally admits audited WebUI and view-source,
/// and ABI 1.14 (`webui_daily_pages`) four daily-use WebUI hosts, mirroring
/// `ReArcTabNavigate` admission in engine/docs/C-ABI.md.
public enum NavigationURLPolicy {
    /// Engine-specific additions to the base set.
    public struct EngineSchemes: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// `chrome://settings` and `chrome://version` only.
        public static let trustedWebUI = EngineSchemes(rawValue: 1)
        /// One `view-source:` wrapper around an http(s) or file URL.
        public static let viewSource = EngineSchemes(rawValue: 2)
        /// `chrome://history`, `downloads`, `password-manager` and `extensions`
        /// (ABI 1.14); only meaningful together with `trustedWebUI`.
        public static let dailyWebUI = EngineSchemes(rawValue: 4)
        /// Static Chromium licence page (`webui_credits`, ABI 1.52).
        public static let creditsWebUI = EngineSchemes(rawValue: 8)
        /// The ABI 1.5 set; engines with `webui_daily_pages` add `dailyWebUI`.
        public static let chromium: EngineSchemes = [.trustedWebUI, .viewSource]
    }

    /// The WebUI hosts the engine audited for browser-less tabs in ABI 1.5.
    public static let trustedWebUIHosts: Set<String> = ["settings", "version"]
    /// The daily-use hosts added by `webui_daily_pages`. `chrome://flags`,
    /// bookmarks and every other host stay rejected.
    public static let dailyWebUIHosts: Set<String> = ["history", "downloads", "password-manager", "extensions"]

    /// Exact WebUI hosts admitted for `engine` (no prefix or wildcard match).
    public static func webUIHosts(for engine: EngineSchemes) -> Set<String> {
        guard engine.contains(.trustedWebUI) else { return [] }
        var hosts = trustedWebUIHosts
        if engine.contains(.dailyWebUI) { hosts.formUnion(dailyWebUIHosts) }
        if engine.contains(.creditsWebUI) { hosts.insert("credits") }
        return hosts
    }

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
            guard let host = url.host()?.lowercased() else { return false }
            return webUIHosts(for: engine).contains(host)
        case "view-source":
            guard engine.contains(.viewSource) else { return false }
            let inner = String(url.absoluteString.dropFirst(viewSourcePrefix.count))
            guard let target = URL(string: inner), let targetScheme = target.scheme?.lowercased() else { return false }
            return viewSourceTargets.contains(targetScheme)
        default:
            return false
        }
    }

    /// A web page from outside ReArc's own UI: an import (Arc, browsers,
    /// bookmark files) or a synced tab (RC-0.1.0-602 T-07). http or https
    /// with a host and no user name or password; never `data:`, `file:`,
    /// `chrome:` or `javascript:`, which the trusted UI alone may open.
    public static func isImportableWebPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
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
