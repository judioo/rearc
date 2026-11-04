import Foundation

/// The per-site panel behind the URL field's site icon (Arc `ARC_SiteControlCenter`,
/// `SiteControlCenterBoostsView`; BOOSTS §5): connection, permissions, the
/// site's boosts, its zoom and its cookies and site data.
public enum SiteControlCenter {
    /// The site a page belongs to, for web pages only.
    public struct Site: Equatable, Sendable {
        public var origin: String
        public var host: String
    }

    public static func site(for url: URL?) -> Site? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = PageOrigin.of(url), let host = PageOrigin.displayHost(origin) else { return nil }
        return Site(origin: origin, host: host)
    }

    /// Whether a website-data record (WebKit names them by registrable
    /// domain, "example.co.uk") belongs to `host` or one of its parents.
    public static func siteDataRecord(_ recordDomain: String, belongsTo host: String) -> Bool {
        let record = recordDomain.lowercased()
        let name = host.lowercased().split(separator: ":").first.map(String.init) ?? host.lowercased()
        guard !record.isEmpty else { return false }
        return name == record || name.hasSuffix("." + record)
    }

    /// One boost row: its switch says whether it changes this site now.
    public struct BoostRow: Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var isEnabled: Bool
    }

    public static func boostRows(_ matches: [(BoostPackage, BoostInstallation)]) -> [BoostRow] {
        matches.map { BoostRow(id: $0.0.manifest.id, name: $0.0.manifest.name, isEnabled: $0.1.enabled) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The site data line: what WebKit holds for the site, or where Chromium's lives.
    public static func siteDataSummary(recordCount: Int?) -> String {
        switch recordCount {
        case nil: return "Cookies and storage are kept by the engine"
        case 0: return "No cookies or site data"
        case 1: return "1 kind of site data stored"
        case let count?: return "\(count) kinds of site data stored"
        }
    }
}
