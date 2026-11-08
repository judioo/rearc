import Foundation

/// Chromium-owned pages the shell routes to instead of reimplementing them,
/// where Arc shows Chrome's own pages. Settings and version need
/// `trustedWebUI`; history, downloads, passwords and extensions need
/// `dailyWebUI` as well (ABI 1.14 `webui_daily_pages`). Credits requires
/// `creditsWebUI` (ABI 1.52 `webui_credits`).
public enum BrowserInternalPage: String, CaseIterable, Hashable, Sendable {
    case settings
    case privacy
    case siteSettings
    case clearBrowsingData
    /// Chromium's Import Bookmarks and Settings dialog (Arc ARC_ImportFeature).
    case importData
    /// Static licences page; requires `creditsWebUI` (ABI 1.52).
    case credits
    case version
    case history
    case downloads
    case passwords
    case extensions
    /// Settings window rows (ARC-RECORDING-2026-11-06 §6.3): subpages of the
    /// admitted `settings` host, so they need `trustedWebUI` only.
    case searchSettings
    case downloadSettings
    case payments
    case notifications

    public var url: URL {
        switch self {
        case .settings: return URL(string: "chrome://settings")!
        case .privacy: return URL(string: "chrome://settings/privacy")!
        case .siteSettings: return URL(string: "chrome://settings/content")!
        case .clearBrowsingData: return URL(string: "chrome://settings/clearBrowserData")!
        case .importData: return URL(string: "chrome://settings/importData")!
        case .credits: return URL(string: "chrome://credits")!
        case .version: return URL(string: "chrome://version")!
        case .history: return URL(string: "chrome://history/")!
        case .downloads: return URL(string: "chrome://downloads/")!
        case .passwords: return URL(string: "chrome://password-manager/")!
        case .extensions: return URL(string: "chrome://extensions/")!
        case .searchSettings: return URL(string: "chrome://settings/search")!
        case .downloadSettings: return URL(string: "chrome://settings/downloads")!
        case .payments: return URL(string: "chrome://settings/payments")!
        case .notifications: return URL(string: "chrome://settings/content/notifications")!
        }
    }

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .privacy: return "Privacy and Security"
        case .siteSettings: return "Site Settings"
        case .clearBrowsingData: return "Clear Browsing Data"
        case .importData: return "Import Browser Data"
        case .credits: return "Credits"
        case .version: return "About Chromium Engine"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .passwords: return "Passwords"
        case .extensions: return "Extensions"
        case .searchSettings: return "Search Engine"
        case .downloadSettings: return "Download Settings"
        case .payments: return "Payment Methods"
        case .notifications: return "Notifications"
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
