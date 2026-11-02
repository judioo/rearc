import Foundation
import SidebarModel

/// Engine operations behind the boost editor drawer and element picker.
/// WKEngine uses WKContentWorld scripts and message handlers; ChromiumEngine
/// uses `ReArcTabEvaluateScript` in the `rearc.boost.editor` isolated world
/// plus a native picker overlay (the ABI provides no page-to-host messages).
protocol BoostEditorEngine: AnyObject {
    /// False on engines that cannot evaluate script (Chromium ABI < 1.5).
    var supportsBoostEditor: Bool { get }
    var onBoostEditorPick: ((PickedElementSnapshot) -> Void)? { get set }
    var onBoostEditorCancel: (() -> Void)? { get set }

    func setBoostEditorOpen(_ open: Bool)
    func setBoostPickerMode(_ active: Bool)
    func highlightBoostSelector(_ css: String)
    func applyEditorLiveCSS(_ css: String)
    func clearEditorLiveCSS()
    func fetchRepairScan(completion: @escaping ([PickedElementSnapshot]) -> Void)
}

/// Editor-world expressions shared by both engines. Every expression is an
/// IIFE so it is valid for `ReArcTabEvaluateScript`, which evaluates
/// expressions, and returns plain JSON values (never pre-stringified JSON).
enum BoostEditorScripts {
    /// Runs `body` with `p` bound to `window.__rearcBoostPicker`, installing
    /// BoostPickerScript first if this document/world does not have it yet.
    static func withPicker(_ body: String) -> String {
        "(function(){ if (!window.__rearcBoostPicker) { \(BoostPickerScript.bridgeSource) } "
            + "var p = window.__rearcBoostPicker; return \(body); })()"
    }

    /// Descriptor of the element at viewport CSS coordinates, or null.
    static func snapshotAt(x: Double, y: Double) -> String {
        withPicker("p.snapshotAt(\(x), \(y))")
    }

    static func setPickMode(_ active: Bool) -> String {
        withPicker("(p.setPickMode(\(active)), null)")
    }

    static func highlight(selector: String) -> String {
        withPicker("(p.highlightSelector(\(jsLiteral(selector))), null)")
    }

    static let hideOverlay = withPicker("(p.hideOverlay(), null)")

    static let scanRepairCandidates = withPicker("p.scanRepairCandidates(24)")

    /// Replaces the editor's live `<style>` nodes; nil when the CSS does not compile.
    static func liveStylesheet(_ css: String) -> String? {
        let rules: [BoostCSSRule]
        if css.isEmpty {
            rules = []
        } else {
            guard let compiled = BoostStyleCompiler.compileStylesheet(css, allowInStyle: true) else { return nil }
            rules = compiled
        }
        let payload = rules.map { ["id": $0.id, "css": $0.css] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let rulesJSON = String(decoding: data, as: UTF8.self)
        return """
        (function(){
          var PREFIX = 'rearc-boost-editor-live-';
          var rules = \(rulesJSON);
          var active = {};
          for (var i = 0; i < rules.length; i++) {
            var rule = rules[i];
            var styleId = PREFIX + rule.id;
            active[styleId] = true;
            var node = document.getElementById(styleId);
            if (!node) {
              node = document.createElement('style');
              node.id = styleId;
              node.type = 'text/css';
              (document.head || document.documentElement).appendChild(node);
            }
            node.textContent = rule.css;
          }
          var nodes = document.querySelectorAll('style[id^="' + PREFIX + '"]');
          for (var j = 0; j < nodes.length; j++) {
            if (!active[nodes[j].id]) nodes[j].remove();
          }
          return rules.length;
        })()
        """
    }

    /// A JavaScript string literal for `value`.
    static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
            return "\"\""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
