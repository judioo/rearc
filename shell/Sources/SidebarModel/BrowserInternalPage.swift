import Foundation

/// Chromium-owned pages the shell routes to instead of reimplementing them,
/// where Arc shows Chrome's own settings. All are `chrome://settings` or
/// `chrome://version` (the engine's audited WebUI hosts).
public enum BrowserInternalPage: String, CaseIterable, Hashable, Sendable {
    case settings
    case privacy
    case siteSettings
    case clearBrowsingData
    case version

    public var url: URL {
        switch self {
        case .settings: return URL(string: "chrome://settings")!
        case .privacy: return URL(string: "chrome://settings/privacy")!
        case .siteSettings: return URL(string: "chrome://settings/content")!
        case .clearBrowsingData: return URL(string: "chrome://settings/clearBrowserData")!
        case .version: return URL(string: "chrome://version")!
        }
    }

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .privacy: return "Privacy and Security"
        case .siteSettings: return "Site Settings"
        case .clearBrowsingData: return "Clear Browsing Data"
        case .version: return "About Chromium Engine"
        }
    }

    /// Chrome's singleton-tab rule: an open tab on the same WebUI host is reused.
    public func isShown(by url: URL) -> Bool {
        url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == self.url.host()
    }
}
