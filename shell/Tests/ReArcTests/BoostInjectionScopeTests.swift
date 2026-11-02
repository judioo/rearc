import XCTest
@testable import ReArc
@testable import SidebarModel

final class BoostInjectionScopeTests: XCTestCase {

    private func entry(host: String, js: String = "window.__rearcBoostProbe = true;") -> BoostRuntimeEntry {
        BoostRuntimeEntry(
            packageID: UUID(),
            order: 0,
            hostScope: [BoostHostRule(host: host)],
            css: nil,
            js: js,
            scriptUserEnabled: true
        )
    }

    func testScriptSourceGatesOnHostScope() {
        let source = BoostInjectionScriptBuilder.scriptSource(
            js: "window.__rearcBoostProbe = true;",
            packageID: UUID(),
            hostScope: [BoostHostRule(host: "allowed.test")]
        )
        XCTAssertTrue(source.contains("authorizedHere"))
        XCTAssertTrue(source.contains("HOST_RULES"))
        XCTAssertTrue(source.contains("if (!authorizedHere()) return;"))
    }

    func testCoordinatorRemovesStaleStylesWhenOffScope() {
        let css = BoostInjectionScriptBuilder.coordinatorSource(entries: [
            BoostRuntimeEntry(
                packageID: UUID(),
                order: 0,
                hostScope: [BoostHostRule(host: "example.com")],
                css: "body { color: red; }",
                cssRules: [BoostCSSRule(id: "0", css: "body { color: red; }")],
                js: nil,
                scriptUserEnabled: false
            )
        ])
        XCTAssertTrue(css.contains("removeOrphanBoostStyles"))
        XCTAssertTrue(css.contains("cssRules"))
        XCTAssertTrue(css.contains("setPlan"))
        XCTAssertTrue(css.contains("if (!eligible())"))
    }

    func testScopeTransitionMatrixScriptContainsHostRules() {
        let pkgID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let source = BoostInjectionScriptBuilder.scriptSource(
            js: "window.__rearcBoostRan = 1;",
            packageID: pkgID,
            hostScope: [
                BoostHostRule(host: "site-a.test", hostMatch: .exact),
                BoostHostRule(host: "site-b.test", hostMatch: .exact),
            ]
        )
        XCTAssertTrue(source.contains("site-a.test"))
        XCTAssertTrue(source.contains("site-b.test"))
        XCTAssertTrue(source.contains("ruleMatches"))
    }
}
