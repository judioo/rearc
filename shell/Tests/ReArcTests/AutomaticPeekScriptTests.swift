import XCTest
import JavaScriptCore
@testable import ReArc

final class AutomaticPeekScriptTests: XCTestCase {
    func testScopeHandlesLocalFixturesAndSharedHosting() throws {
        let local = try XCTUnwrap(AutomaticPeekScript.entry(for: URL(string: "http://127.0.0.1:8000/a")))
        XCTAssertEqual(local.scopes.first?.host, "127.0.0.1")
        XCTAssertEqual(local.scopes.first?.includeSubdomains, false)
        let tenant = try XCTUnwrap(AutomaticPeekScript.entry(for: URL(string: "https://alice.github.io/a")))
        XCTAssertEqual(tenant.scopes.first?.host, "alice.github.io")
        XCTAssertEqual(tenant.scopes.first?.includeSubdomains, false)
        let redirected = try XCTUnwrap(AutomaticPeekScript.entry(for: URL(string: "https://example.com"),
                                                                documentURL: URL(string: "https://mail.example.com/a")))
        XCTAssertEqual(redirected.scopes.map(\.host), ["example.com", "mail.example.com"])
        XCTAssertNil(AutomaticPeekScript.entry(for: URL(string: "about:blank")))
    }
    func testClickRoutingAndDisablingInTheCurrentDocument() throws {
        let context = try XCTUnwrap(JSContext())
        let parse: @convention(block) (String) -> NSDictionary = { text in
            let url = URL(string: text)
            return ["hostname": url?.host ?? "", "protocol": (url?.scheme ?? "") + ":", "href": text] as NSDictionary
        }
        context.setObject(parse, forKeyedSubscript: "parseURL" as NSString)
        context.evaluateScript("""
        var window = this; window.top = window;
        function URL(text) { var u = parseURL(text); this.hostname = u.hostname; this.protocol = u.protocol; this.href = u.href; }
        var document = {
          addEventListener: function(_, fn) { this.listener = fn; },
          removeEventListener: function(_, fn) { if (this.listener === fn) this.listener = null; }
        };
        var messages = [];
        function rearcPostMessage(message) { messages.push(JSON.parse(message)); }
        function click(href, options) {
          options = options || {};
          var prevented = false;
          var link = { tagName: 'A', href: href, target: options.target || '',
                       hasAttribute: function(name) { return name === 'download' && !!options.download; } };
          var event = Object.assign({ isTrusted: true, button: 0, composedPath: function() { return [link]; },
            preventDefault: function() { prevented = true; }, stopImmediatePropagation: function() {} }, options);
          if (document.listener) document.listener(event);
          return prevented;
        }
        """)
        context.evaluateScript(AutomaticPeekScript.source(for: URL(string: "https://mail.example.com")))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("click('https://other.org/a')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("messages[0].href")?.toString(), "https://other.org/a")
        for expression in [
            "click('https://other.org/a', {isTrusted:false})",
            "click('https://www.example.com/a')",
            "click('https://other.org/a', {metaKey:true})",
            "click('https://other.org/a', {shiftKey:true})",
            "click('https://other.org/a', {button:1})",
            "click('https://other.org/a', {download:true})",
            "click('https://other.org/a', {target:'frame'})",
            "click('mailto:a@other.org')"
        ] {
            XCTAssertEqual(context.evaluateScript(expression)?.toBool(), false, expression)
        }
        XCTAssertEqual(context.evaluateScript("click('https://other.org/b', {target:'_blank'})")?.toBool(), true)
        context.evaluateScript(AutomaticPeekScript.source(for: nil))
        XCTAssertEqual(context.evaluateScript("click('https://other.org/a')")?.toBool(), false)
        context.evaluateScript(AutomaticPeekScript.source(for: URL(string: "https://example.com")))
        XCTAssertEqual(context.evaluateScript("click('https://other.org/c')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 3)
        XCTAssertNil(context.exception)
    }

}
