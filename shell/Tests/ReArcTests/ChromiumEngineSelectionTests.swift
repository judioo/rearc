import XCTest
@testable import ReArc
@testable import SidebarModel

final class EngineLaunchOptionsTests: XCTestCase {

    func testDefaultsToWebKit() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: [:])
        XCTAssertEqual(options, EngineLaunchOptions(engine: .webkit, selfTest: false))
    }

    func testEnvironmentSelectsChromium() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: ["REARC_ENGINE": "Chromium"])
        XCTAssertEqual(options.engine, .chromium)
    }

    func testFlagOverridesEnvironment() {
        let toWebKit = EngineLaunchOptions.parse(
            arguments: ["ReArc", "--rearc-engine=webkit"],
            environment: ["REARC_ENGINE": "chromium"]
        )
        XCTAssertEqual(toWebKit.engine, .webkit)
        let toChromium = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-engine=chromium"], environment: [:])
        XCTAssertEqual(toChromium.engine, .chromium)
    }

    func testUnknownValuesFallBackToWebKit() {
        XCTAssertEqual(EngineLaunchOptions.parse(arguments: ["ReArc"], environment: ["REARC_ENGINE": "blink"]).engine, .webkit)
        XCTAssertEqual(EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-engine=gecko"], environment: [:]).engine, .webkit)
    }

    func testSelfTestImpliesChromium() {
        let options = EngineLaunchOptions.parse(
            arguments: ["ReArc", "--rearc-engine=webkit", "--rearc-selftest"],
            environment: [:]
        )
        XCTAssertEqual(options, EngineLaunchOptions(engine: .chromium, selfTest: true))
    }

    func testExecutablePathIsNotParsedAsFlag() {
        let options = EngineLaunchOptions.parse(arguments: ["--rearc-selftest"], environment: [:])
        XCTAssertFalse(options.selfTest)
    }
}

final class ChromiumBoostPlanTests: XCTestCase {

    private func runtimeEntry(
        id: UUID = UUID(),
        order: Int = 0,
        scope: [BoostHostRule],
        cssRules: [BoostCSSRule] = [],
        js: String? = nil,
        scriptUserEnabled: Bool = true
    ) -> BoostRuntimeEntry {
        BoostRuntimeEntry(
            packageID: id,
            order: order,
            hostScope: scope,
            css: cssRules.map(\.css).joined(separator: "\n"),
            cssRules: cssRules,
            js: js,
            scriptUserEnabled: scriptUserEnabled
        )
    }

    func testMapsScopesSchemesAndContent() {
        let id = UUID(uuidString: "5E1F7E57-B005-4000-8000-0000000000AA")!
        let plan = ChromiumBoostPlan.entries(from: [
            runtimeEntry(
                id: id,
                scope: [
                    BoostHostRule(host: "Example.com", hostMatch: .registrable, schemes: ["https", "HTTP"]),
                    BoostHostRule(host: "docs.example.org", hostMatch: .exact, pathPrefix: "/guide", schemes: ["http"]),
                ],
                cssRules: [BoostCSSRule(id: "a", css: "body{color:red}"), BoostCSSRule(id: "b", css: "p{margin:0}")],
                js: "console.log(1)"
            ),
        ])
        XCTAssertEqual(plan, [
            ChromiumBoostPlan.Entry(
                id: "5e1f7e57-b005-4000-8000-0000000000aa",
                scopes: [
                    .init(host: "example.com", pathPrefix: "", includeSubdomains: true, schemeMask: 3),
                    .init(host: "docs.example.org", pathPrefix: "/guide", includeSubdomains: false, schemeMask: 1),
                ],
                runAt: ChromiumBoostPlan.runAtDocumentEnd,
                source: "console.log(1)",
                css: "body{color:red}\np{margin:0}"
            ),
        ])
        XCTAssertEqual(ChromiumBoostPlan.scriptIDs(in: plan), ["5e1f7e57-b005-4000-8000-0000000000aa"])
    }

    func testOrdersByBoostOrder() {
        let first = UUID()
        let second = UUID()
        let scope = [BoostHostRule(host: "example.com")]
        let plan = ChromiumBoostPlan.entries(from: [
            runtimeEntry(id: second, order: 5, scope: scope, cssRules: [BoostCSSRule(id: "x", css: "a{}")]),
            runtimeEntry(id: first, order: 1, scope: scope, cssRules: [BoostCSSRule(id: "y", css: "b{}")]),
        ])
        XCTAssertEqual(plan.map(\.id), [first.uuidString.lowercased(), second.uuidString.lowercased()])
    }

    func testScriptOmittedWhenUserDisabledScripts() {
        let plan = ChromiumBoostPlan.entries(from: [
            runtimeEntry(
                scope: [BoostHostRule(host: "example.com")],
                cssRules: [BoostCSSRule(id: "a", css: "body{}")],
                js: "alert(1)",
                scriptUserEnabled: false
            ),
        ])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].source, "")
        XCTAssertTrue(ChromiumBoostPlan.scriptIDs(in: plan).isEmpty)
    }

    func testDropsEntriesWithNothingToInject() {
        let plan = ChromiumBoostPlan.entries(from: [
            runtimeEntry(scope: [BoostHostRule(host: "example.com")], js: "alert(1)", scriptUserEnabled: false),
            runtimeEntry(scope: [BoostHostRule(host: "example.com")], cssRules: [BoostCSSRule(id: "e", css: "")]),
        ])
        XCTAssertTrue(plan.isEmpty)
    }

    func testDropsUnsupportedSchemesAndSharedHostingSuffixes() {
        let plan = ChromiumBoostPlan.entries(from: [
            runtimeEntry(
                scope: [
                    BoostHostRule(host: "example.com", schemes: ["ftp"]),
                    BoostHostRule(host: "github.io", hostMatch: .registrable),
                    BoostHostRule(host: "me.github.io", hostMatch: .exact),
                ],
                cssRules: [BoostCSSRule(id: "a", css: "body{}")]
            ),
            runtimeEntry(
                scope: [BoostHostRule(host: "vercel.app", hostMatch: .registrable)],
                cssRules: [BoostCSSRule(id: "b", css: "body{}")]
            ),
        ])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].scopes, [.init(host: "me.github.io", pathPrefix: "", includeSubdomains: false, schemeMask: 2)])
    }
}
