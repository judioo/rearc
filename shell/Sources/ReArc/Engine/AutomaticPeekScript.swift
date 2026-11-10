import Foundation
import SidebarModel

/// Isolated-world click routing for Chromium, before the page navigates.
enum AutomaticPeekScript {
    static let id = UUID(uuidString: "71C705EC-6CF3-4FC6-88D0-33725D144B96")!
    static var worldID: String { id.uuidString.lowercased() }

    static func source(for url: URL?) -> String {
        let domain = url.flatMap(AutomaticPeek.domain) ?? ""
        let encoded = String(data: try! JSONEncoder().encode(domain), encoding: .utf8)!
        return """
        (function() {
          if (window.rearcAutoPeekClick) document.removeEventListener('click', window.rearcAutoPeekClick, true);
          var domain = \(encoded);
          window.rearcAutoPeekClick = function(e) {
            if (!e.isTrusted) return;
            if (!domain || window !== window.top || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
            var link = e.composedPath().find(function(n) { return n.tagName === 'A'; });
            if (!link || link.hasAttribute('download') || (link.target && link.target !== '_self' && link.target !== '_blank')) return;
            var url; try { url = new URL(link.href); } catch (_) { return; }
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
            var host = url.hostname.toLowerCase().replace(/\\.$/, '');
            if (host === domain || host.endsWith('.' + domain)) return;
            e.preventDefault(); e.stopImmediatePropagation();
            rearcPostMessage(JSON.stringify({ href: url.href }));
          };
          document.addEventListener('click', window.rearcAutoPeekClick, true);
        })();
        """
    }

    static func entry(for url: URL?, documentURL: URL? = nil) -> ChromiumBoostPlan.Entry? {
        guard let url, AutomaticPeek.domain(url) != nil, let host = url.host?.lowercased() else { return nil }
        var hosts = [host.trimmingCharacters(in: CharacterSet(charactersIn: "."))]
        if let documentURL, AutomaticPeek.domain(documentURL) != nil, let current = documentURL.host?.lowercased() {
            let normalized = current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !hosts.contains(normalized) { hosts.append(normalized) }
        }
        // Exact hosts avoid rejecting the entire Boost plan on a suffix the
        // shell's smaller domain table does not know. Commits refresh the scope.
        let scopes = hosts.map {
            ChromiumBoostPlan.Scope(host: $0, pathPrefix: "/", includeSubdomains: false,
                                    schemeMask: ChromiumBoostPlan.schemeHTTP | ChromiumBoostPlan.schemeHTTPS)
        }
        return .init(id: worldID, scopes: scopes, runAt: 0, source: source(for: url), css: "")
    }
}
