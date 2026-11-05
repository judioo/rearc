import Foundation

/// Ordinary off-site links from persistent sidebar tabs leave the source in place.
public enum AutomaticPeek {
    public static func domain(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") || host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) { return host }
        for suffix in BoostPublicSuffixList.sharedHostingDomains where host.hasSuffix("." + suffix) {
            return host.split(separator: ".").suffix(suffix.split(separator: ".").count + 1).joined(separator: ".")
        }
        return BoostScopeMatcher.registrableDomain(host)
    }

    public static func shouldOpen(kind: Tab.Kind, source: URL, destination: URL, enabled: Bool = true,
                                  mainFrame: Bool = true, modified: Bool = false) -> Bool {
        guard enabled, mainFrame, !modified, kind != .today,
              let sourceDomain = domain(source), let destinationDomain = domain(destination) else { return false }
        return sourceDomain != destinationDomain
    }
}
