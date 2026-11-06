import JavaScriptCore
import Testing
@testable import ReArc

struct HistorySwipeEdgeScriptTests {
    private func edges(scrollLeft: Int = 0, range: Int = 0, direction: String = "ltr",
                       behavior: String = "auto", nested: Bool = false, tag: String = "DIV") throws -> [String: Bool] {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var innerWidth = 800, innerHeight = 600;
        var root = {tagName: 'HTML', clientWidth: 800, scrollWidth: 800, scrollLeft: 0, parentElement: null};
        var child = {tagName: '\(tag)', clientWidth: 100, scrollWidth: \(100 + range), scrollLeft: \(scrollLeft), parentElement: root};
        var document = {scrollingElement: \(nested ? "root" : "child"), elementFromPoint: function() { return child; }};
        function getComputedStyle(node) { return {direction: '\(direction)', overflowX: 'auto', overscrollBehaviorX: '\(behavior)'}; }
        """)
        return try #require(context.evaluateScript(HistorySwipeEdgeScript.source(x: 0.5, y: 0.5))?.toDictionary() as? [String: Bool])
    }

    @Test func rootAndNestedScrollersMustBeAtTheDirectionalEdge() throws {
        #expect(try edges() == ["back": true, "forward": true])
        #expect(try edges(scrollLeft: 0, range: 100) == ["back": true, "forward": false])
        #expect(try edges(scrollLeft: 100, range: 100) == ["back": false, "forward": true])
        #expect(try edges(scrollLeft: 50, range: 100, nested: true) == ["back": false, "forward": false])
        #expect(try edges(scrollLeft: -100, range: 100, direction: "rtl") == ["back": true, "forward": false])
        #expect(try edges(scrollLeft: 0, range: 100, direction: "rtl") == ["back": false, "forward": true])
    }

    @Test func blockedChainingAndUnknownEmbeddedDocumentsRejectSwipes() throws {
        #expect(try edges(behavior: "contain") == ["back": false, "forward": false])
        #expect(try edges(behavior: "none") == ["back": false, "forward": false])
        #expect(try edges(tag: "IFRAME") == ["back": false, "forward": false])
        #expect(try edges(tag: "CLOSED-SHADOW") == ["back": false, "forward": false])
    }
}
