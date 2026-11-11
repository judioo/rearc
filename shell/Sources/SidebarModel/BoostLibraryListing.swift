import Foundation

/// The rows of the Boosts library page (Arc View Boosts / Library `BoostsPage`,
/// BOOSTS §2, §5) for one profile, in installation order.
public struct BoostLibraryRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// "github.com", "github.com and 2 more" or "No sites".
    public var sites: String
    public var colorHex: String
    public var enabled: Bool
    public var hasStyle: Bool
    public var hasScript: Bool
    /// Script boosts run only after the user allows their script.
    public var scriptAllowed: Bool
    /// The boost applies to the page on screen, so the editor can open on it.
    public var matchesCurrentPage: Bool
    /// The first site, opened by "Open Site".
    public var siteURL: URL?
    /// The CSS came or changed through sync and is not applied until approved on this Mac.
    public var styleNeedsApproval: Bool = false
    /// Every host rule, one per line, for the row's tooltip and the approval prompts.
    public var allSites: String = ""
}

public enum BoostLibraryListing {

    public static func rows(_ library: ProfileBoostLibrary, currentPage: URL? = nil, filter: String = "") -> [BoostLibraryRow] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let order = Dictionary(uniqueKeysWithValues: library.installations.map { ($0.packageID, $0.order) })
        return library.packages
            .compactMap { package -> BoostLibraryRow? in
                guard let install = library.installation(for: package.manifest.id) else { return nil }
                let hosts = package.manifest.hostScope.map(\.host)
                let row = BoostLibraryRow(
                    id: package.manifest.id,
                    name: package.manifest.name,
                    sites: summary(hosts),
                    colorHex: package.metadata.colorHex,
                    enabled: install.enabled,
                    hasStyle: package.styleBoost != nil,
                    hasScript: package.hasScript,
                    scriptAllowed: package.scriptBoost?.userScriptEnabled ?? false,
                    matchesCurrentPage: currentPage.map { BoostScopeMatcher.matches(scope: package.manifest.hostScope, url: $0) } ?? false,
                    siteURL: hosts.first.flatMap { URL(string: "https://\($0)/") },
                    styleNeedsApproval: !library.styleApproved(package),
                    allSites: package.manifest.hostScope.map(describe).joined(separator: "\n")
                )
                guard needle.isEmpty
                        || row.name.lowercased().contains(needle)
                        || hosts.contains(where: { $0.contains(needle) }) else { return nil }
                return row
            }
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    /// "github.com and subdomains, https, /path".
    public static func describe(_ rule: BoostHostRule) -> String {
        var text = rule.host + (rule.hostMatch == .registrable ? " and subdomains" : "")
        text += ", " + rule.schemes.joined(separator: "/")
        if !rule.pathPrefix.isEmpty { text += ", paths under " + rule.pathPrefix }
        return text
    }

    static func summary(_ hosts: [String]) -> String {
        guard let first = hosts.first else { return "No sites" }
        return hosts.count == 1 ? first : "\(first) and \(hosts.count - 1) more"
    }

    /// The page a typed site stands for ("github.com", "https://x.com/a"),
    /// or nil when it is not a host a boost can target.
    public static func siteURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), host.contains("."),
              BoostScopeMatcher.defaultRule(forPage: url) != nil else { return nil }
        return URL(string: "https://\(host)/")
    }
}
