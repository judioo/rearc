import Foundation

/// Chromium-owned pages the shell routes to instead of reimplementing them,
/// where Arc shows Chrome's own pages. Settings and version need
/// `trustedWebUI`; history, downloads, passwords and extensions need
/// `dailyWebUI` as well (ABI 1.14 `webui_daily_pages`).
public enum BrowserInternalPage: String, CaseIterable, Hashable, Sendable {
    case settings
    case privacy
    case siteSettings
    case clearBrowsingData
    /// Chromium's Import Bookmarks and Settings dialog (Arc ARC_ImportFeature).
    case importData
    case version
    case history
    case downloads
    case passwords
    case extensions

    public var url: URL {
        switch self {
        case .settings: return URL(string: "chrome://settings")!
        case .privacy: return URL(string: "chrome://settings/privacy")!
        case .siteSettings: return URL(string: "chrome://settings/content")!
        case .clearBrowsingData: return URL(string: "chrome://settings/clearBrowserData")!
        case .importData: return URL(string: "chrome://settings/importData")!
        case .version: return URL(string: "chrome://version")!
        case .history: return URL(string: "chrome://history/")!
        case .downloads: return URL(string: "chrome://downloads/")!
        case .passwords: return URL(string: "chrome://password-manager/")!
        case .extensions: return URL(string: "chrome://extensions/")!
        }
    }

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .privacy: return "Privacy and Security"
        case .siteSettings: return "Site Settings"
        case .clearBrowsingData: return "Clear Browsing Data"
        case .importData: return "Import Browser Data"
        case .version: return "About Chromium Engine"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        case .extensions: return "Extensions"
        }
    }

    /// Whether an engine with `engine` admission can open this page.
    public func isAvailable(engine: NavigationURLPolicy.EngineSchemes) -> Bool {
        NavigationURLPolicy.allows(url, engine: engine)
    }

    /// Chromium's per-site page (permissions and their reset) for a serialized origin.
    public static func siteDetailsURL(origin: String) -> URL? {
        var components = URLComponents(string: "chrome://settings/content/siteDetails")
        components?.queryItems = [URLQueryItem(name: "site", value: origin)]
        return components?.url
    }

    /// Chrome's singleton-tab rule: an open tab on the same WebUI host is reused.
    public func isShown(by url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == self.url.host()
    }
}
