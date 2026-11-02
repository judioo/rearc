import Foundation
import SidebarModel

/// Shell-side form of the engine's ordered `ReArcScript` plan, mapped from
/// `BoostRuntimeEntry` as engine/docs/C-ABI.md "Boost plan semantics" requires.
/// Pure Swift so the mapping is testable without a Chromium build.
enum ChromiumBoostPlan {
    struct Scope: Equatable {
        var host: String
        var pathPrefix: String
        var includeSubdomains: Bool
        var schemeMask: UInt32
    }

    struct Entry: Equatable {
        var id: String
        var scopes: [Scope]
        var runAt: UInt32
        var source: String
        var css: String
    }

    static let schemeHTTP: UInt32 = 1
    static let schemeHTTPS: UInt32 = 2
    /// WKEngine injects boost JS at document end; keep the same timing.
    static let runAtDocumentEnd: UInt32 = 1

    static func entries(from runtimeEntries: [BoostRuntimeEntry]) -> [Entry] {
        runtimeEntries
            .sorted { $0.order < $1.order }
            .compactMap(entry(from:))
    }

    static func scriptIDs(in plan: [Entry]) -> Set<String> {
        Set(plan.filter { !$0.source.isEmpty }.map(\.id))
    }

    private static func entry(from runtime: BoostRuntimeEntry) -> Entry? {
        let scopes = runtime.hostScope.compactMap(scope(from:))
        guard !scopes.isEmpty else { return nil }
        let css = runtime.cssRules.map(\.css).filter { !$0.isEmpty }.joined(separator: "\n")
        let source = runtime.scriptUserEnabled ? (runtime.js ?? "") : ""
        guard !css.isEmpty || !source.isEmpty else { return nil }
        return Entry(
            id: runtime.packageID.uuidString.lowercased(),
            scopes: scopes,
            runAt: runAtDocumentEnd,
            source: source,
            css: css
        )
    }

    private static func scope(from rule: BoostHostRule) -> Scope? {
        var mask: UInt32 = 0
        for scheme in rule.schemes {
            switch scheme.lowercased() {
            case "http": mask |= schemeHTTP
            case "https": mask |= schemeHTTPS
            default: break
            }
        }
        guard mask != 0, !rule.host.isEmpty else { return nil }
        let includeSubdomains = rule.hostMatch == .registrable
        // The engine rejects a whole plan containing a public/private suffix
        // with include_subdomains; WKEngine never matches these either.
        if includeSubdomains, BoostPublicSuffixList.isSharedHostingRegistrableDomain(rule.host) {
            return nil
        }
        return Scope(
            host: rule.host.lowercased(),
            pathPrefix: rule.pathPrefix,
            includeSubdomains: includeSubdomains,
            schemeMask: mask
        )
    }
}
