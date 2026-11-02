import Foundation
import SidebarModel
import WebKit

struct BoostInstallPlan: Equatable {
    var entries: [BoostRuntimeEntry]
}

enum BoostInjectionScriptBuilder {
    static let hostWorldName = "rearc.host"
    static let pageshowHandler = "rearcBoostPageshow"
    static let styleNodePrefix = "rearc-boost-"

    static func hostWorld() -> WKContentWorld {
        WKContentWorld.world(name: hostWorldName)
    }

    static func scriptWorld(for packageID: UUID) -> WKContentWorld {
        WKContentWorld.world(name: "rearc.boost.\(packageID.uuidString.lowercased())")
    }

    static func sharedHostingJSON() -> String {
        jsonArray(Array(BoostPublicSuffixList.sharedHostingDomains).sorted())
    }

    static func livePlanPayloadJSON(entries: [BoostRuntimeEntry]) -> String {
        let payload = entries.map { entry -> String in
            let rules = entry.cssRules.map { rule -> String in
                """
                {"id":"\(escapeJS(rule.id))","css":"\(escapeJS(rule.css))"}
                """
            }.joined(separator: ",")
            let hosts = entry.hostScope.map { rule -> String in
                """
                {"host":"\(escapeJS(rule.host))","match":"\(rule.hostMatch.rawValue)","pathPrefix":"\(escapeJS(rule.pathPrefix))","schemes":\(jsonArray(rule.schemes))}
                """
            }.joined(separator: ",")
            return """
            {"id":"\(entry.packageID.uuidString.lowercased())","order":\(entry.order),"hosts":[\(hosts)],"cssRules":[\(rules)],"hasScript":\(entry.scriptUserEnabled ? "true" : "false")}
            """
        }.joined(separator: ",")
        return "{\"packages\":[\(payload)]}"
    }

    static func coordinatorSource(entries: [BoostRuntimeEntry]) -> String {
        let initialPlan = livePlanPayloadJSON(entries: entries)
        return """
        (function(){
          var PREFIX = '\(styleNodePrefix)';
          function escRe(s){ return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&'); }
          var SHARED_HOSTING = \(sharedHostingJSON());
          function registrable(host){
            var p = host.toLowerCase().split('.');
            if (p.length >= 3 && ['co','com','org','net','ac','gov'].indexOf(p[p.length-2]) >= 0) {
              return p.slice(-3).join('.');
            }
            return p.slice(-2).join('.');
          }
          function eligible(){
            var s = (location.protocol || '').replace(':','').toLowerCase();
            if (s !== 'http' && s !== 'https') return false;
            if (location.href === 'about:blank') return false;
            return true;
          }
          function hostOk(rule, host){
            host = host.toLowerCase();
            if (rule.match === 'exact') return host === rule.host;
            if (SHARED_HOSTING.indexOf(rule.host) >= 0) return false;
            return registrable(host) === rule.host;
          }
          function pathOk(rule){
            if (!rule.pathPrefix) return true;
            var path = location.pathname || '/';
            if (path === rule.pathPrefix) return true;
            return path.indexOf(rule.pathPrefix + '/') === 0;
          }
          function matches(rule){
            var scheme = (location.protocol || '').replace(':','').toLowerCase();
            if (rule.schemes.indexOf(scheme) < 0) return false;
            var host = location.hostname;
            if (!host) return false;
            if (!hostOk(rule, host)) return false;
            return pathOk(rule);
          }
          function packageMatches(pkg){
            for (var i = 0; i < pkg.hosts.length; i++) {
              if (matches(pkg.hosts[i])) return true;
            }
            return false;
          }
          function removeOrphanBoostStyles(activeStyleIds){
            var nodes = document.querySelectorAll('style[id^="' + PREFIX + '"]');
            for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (!activeStyleIds[node.id]) node.remove();
            }
          }
          function applyCSS(){
            var PACKAGES = (window.__rearcBoostPlan && window.__rearcBoostPlan.packages) || [];
            if (!eligible()) {
              removeOrphanBoostStyles({});
              return;
            }
            PACKAGES.sort(function(a,b){ return a.order - b.order; });
            var activeStyleIds = {};
            for (var i = 0; i < PACKAGES.length; i++) {
              var pkg = PACKAGES[i];
              if (!packageMatches(pkg)) continue;
              var rules = pkg.cssRules || [];
              for (var r = 0; r < rules.length; r++) {
                var rule = rules[r];
                if (!rule || !rule.css) continue;
                var styleId = PREFIX + pkg.id + '-' + rule.id;
                activeStyleIds[styleId] = true;
                var node = document.getElementById(styleId);
                if (!node) {
                  node = document.createElement('style');
                  node.id = styleId;
                  node.type = 'text/css';
                  (document.head || document.documentElement).appendChild(node);
                }
                node.textContent = rule.css;
              }
            }
            removeOrphanBoostStyles(activeStyleIds);
          }
          window.__rearcBoostPlan = \(initialPlan);
          window.__rearcBoostCoordinator = {
            apply: applyCSS,
            probePath: function(){ applyCSS(); },
            setPlan: function(plan){
              window.__rearcBoostPlan = plan || { packages: [] };
              applyCSS();
            }
          };
          if (document.documentElement && document.documentElement.tagName === 'HTML') {
            applyCSS();
          }
          window.addEventListener('pageshow', function(){
            applyCSS();
            if (window.webkit && window.webkit.messageHandlers['\(pageshowHandler)']) {
              window.webkit.messageHandlers['\(pageshowHandler)'].postMessage('pageshow');
            }
          });
        })();
        """
    }

    static func scriptSource(js: String, packageID: UUID, hostScope: [BoostHostRule]) -> String {
        let hosts = hostScope.map { rule -> String in
            """
            {"host":"\(escapeJS(rule.host))","match":"\(rule.hostMatch.rawValue)","pathPrefix":"\(escapeJS(rule.pathPrefix))","schemes":\(jsonArray(rule.schemes))}
            """
        }.joined(separator: ",")
        let wrapped = """
        (function(){
          // WK-LIMIT: installed user scripts cannot be removed per navigation; gate execution on the committed URL.
          var HOST_RULES = [\(hosts)];
          function escRe(s){ return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&'); }
          var SHARED_HOSTING = \(sharedHostingJSON());
          function registrable(host){
            var p = host.toLowerCase().split('.');
            if (p.length >= 3 && ['co','com','org','net','ac','gov'].indexOf(p[p.length-2]) >= 0) {
              return p.slice(-3).join('.');
            }
            return p.slice(-2).join('.');
          }
          function hostOk(rule, host){
            host = host.toLowerCase();
            if (rule.match === 'exact') return host === rule.host;
            if (SHARED_HOSTING.indexOf(rule.host) >= 0) return false;
            return registrable(host) === rule.host;
          }
          function pathOk(rule){
            if (!rule.pathPrefix) return true;
            var path = location.pathname || '/';
            if (path === rule.pathPrefix) return true;
            return path.indexOf(rule.pathPrefix + '/') === 0;
          }
          function ruleMatches(rule){
            var scheme = (location.protocol || '').replace(':','').toLowerCase();
            if (rule.schemes.indexOf(scheme) < 0) return false;
            var host = location.hostname;
            if (!host) return false;
            if (!hostOk(rule, host)) return false;
            return pathOk(rule);
          }
          function authorizedHere(){
            var s = (location.protocol || '').replace(':','').toLowerCase();
            if (s !== 'http' && s !== 'https') return false;
            if (location.href === 'about:blank') return false;
            for (var i = 0; i < HOST_RULES.length; i++) {
              if (ruleMatches(HOST_RULES[i])) return true;
            }
            return false;
          }
          if (!authorizedHere()) return;
          var REVISIONS = window.__rearcBoostScriptRevisions = window.__rearcBoostScriptRevisions || new Set();
          var key = '\(packageID.uuidString.lowercased())';
          if (REVISIONS.has(key)) return;
          REVISIONS.add(key);
          try {
            \(js)
          } catch (e) {
            console.error('[ReArc Boost]', e);
          }
        })();
        """
        return wrapped
    }

    private static func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\(escapeJS($0))\"" }.joined(separator: ",") + "]"
    }
}

final class BoostPageshowHandler: NSObject, WKScriptMessageHandler {
    var onPageshow: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == BoostInjectionScriptBuilder.pageshowHandler else { return }
        onPageshow?()
    }
}
