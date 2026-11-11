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
        XCTAssertEqual(options, EngineLaunchOptions(engine: .chromium, selfTest: true, source: .selfTest))
    }

    // MARK: LaunchServices launches of the Chromium bundle (Finder, Dock, `open`, links)

    private let chromiumBundle: [String: Any] = [
        "ReArcDefaultEngine": "chromium",
        "NSPrincipalClass": "BrowserCrApplication",
    ]

    func testChromiumBundleDefaultsToChromiumWithoutAnEngineChoice() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: [:], infoDictionary: chromiumBundle)
        XCTAssertEqual(options.engine, .chromium)
        XCTAssertEqual(options.source, .infoPlist)
        // LaunchServices passes -psn_ arguments on some systems; they are not engine choices.
        let finder = EngineLaunchOptions.parse(arguments: ["ReArc", "-psn_0_12345"], environment: [:], infoDictionary: chromiumBundle)
        XCTAssertEqual(finder.engine, .chromium)
    }

    func testEnvironmentAndFlagStillOverrideTheBundleDefault() {
        let environment = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: ["REARC_ENGINE": "webkit"], infoDictionary: chromiumBundle)
        XCTAssertEqual(environment.engine, .webkit)
        XCTAssertEqual(environment.source, .environment)
        let flag = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-engine=webkit"], environment: [:], infoDictionary: chromiumBundle)
        XCTAssertEqual(flag.source, .argument)
    }

    func testWebKitBundleKeepsTheWebKitDefault() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: [:], infoDictionary: ["NSPrincipalClass": "NSApplication"])
        XCTAssertEqual(options, EngineLaunchOptions(engine: .webkit, selfTest: false))
        XCTAssertFalse(EngineLaunchOptions.applicationClassRequiresChromium(infoDictionary: ["NSPrincipalClass": "NSApplication"]) { _ in true })
    }

    func testChromiumApplicationClassNeverRunsTheWebKitPath() {
        let requires = EngineLaunchOptions.applicationClassRequiresChromium(infoDictionary: chromiumBundle) { $0 == "BrowserCrApplication" }
        XCTAssertTrue(requires)
        let asked = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-engine=webkit"], environment: [:], infoDictionary: chromiumBundle)
        let resolved = asked.resolvingApplicationClass(requiresChromium: requires)
        XCTAssertEqual(resolved.engine, .chromium, "WebKit would abort in +[BrowserCrApplication initialize]")
        XCTAssertEqual(resolved.source, .applicationClass)
        // A bundle without the key (an older build) is caught the same way.
        let old = EngineLaunchOptions.parse(arguments: ["ReArc"], environment: [:], infoDictionary: ["NSPrincipalClass": "BrowserCrApplication"])
        XCTAssertEqual(old.resolvingApplicationClass(requiresChromium: true).engine, .chromium)
        // The class is absent when the framework did not load: AppKit falls back to NSApplication.
        XCTAssertFalse(EngineLaunchOptions.applicationClassRequiresChromium(infoDictionary: chromiumBundle) { _ in false })
        XCTAssertEqual(old.resolvingApplicationClass(requiresChromium: false).engine, .webkit)
    }

    func testLaunchProbeIsNotAnEngineChoice() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-launch-probe=/tmp/probe.txt"], environment: [:],
                                                infoDictionary: chromiumBundle)
        XCTAssertEqual(options.launchProbePath, "/tmp/probe.txt")
        XCTAssertEqual(options.source, .infoPlist)
        XCTAssertFalse(options.selfTest)
        XCTAssertNil(EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-launch-probe="], environment: [:]).launchProbePath)
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

final class ReleaseLaunchSecurityTests: XCTestCase {
    func testReleaseOnlyPassesProfileSelectionToChromium() {
        let attacks = ["--remote-debugging-port=9222", "--remote-debugging-pipe", "--no-sandbox",
                       "--disable-web-security", "--enable-features=Evil", "--load-extension=/tmp/x",
                       "--host-resolver-rules=MAP * evil", "--rearc-selftest", "https://evil.test"]
        let result = ChromiumLaunchArguments.browserArguments(
            ["ReArc"] + attacks + ["--user-data-dir=/isolated", "--profile-directory", "Profile 2"],
            defaultUserDataDir: { XCTFail("explicit profile"); return "/unused" }, keychain: .system, isRelease: true)
        XCTAssertEqual(result, ["ReArc", "--user-data-dir=/isolated", "--profile-directory=Profile 2"])
        XCTAssertEqual(ChromiumLaunchArguments.browserArguments(["ReArc"] + attacks,
            defaultUserDataDir: { "/isolated" }, keychain: .system, isRelease: true),
                       ["ReArc", "--user-data-dir=/isolated"])
    }

    /// RC-0.1.0-602 T-04: a shipped bundle's engine profile is always ReArc's own.
    func testShippedBundleNeverTakesAUserDataDirAndProfileNamesStayInside() {
        let argv = ["ReArc", "--user-data-dir=/tmp/prepared", "--user-data-dir", "/tmp/other", "--profile-directory=Profile 2"]
        XCTAssertEqual(ChromiumLaunchArguments.browserArguments(argv, defaultUserDataDir: { "/Users/x/Library/Application Support/ReArc/Chromium" },
                                                                keychain: .system, isRelease: true, isShipped: true),
                       ["ReArc", "--profile-directory=Profile 2", "--user-data-dir=/Users/x/Library/Application Support/ReArc/Chromium"])
        XCTAssertEqual(ChromiumLaunchArguments.browserArguments(argv, defaultUserDataDir: { XCTFail("explicit"); return "" },
                                                                keychain: .system, isRelease: true, isShipped: false),
                       ["ReArc", "--user-data-dir=/tmp/prepared", "--user-data-dir=/tmp/other", "--profile-directory=Profile 2"],
                       "the bundle release.sh is verifying keeps its throwaway profiles")
        for escape in ["../../../tmp/evil", "..", ".", "a/b", "/tmp/x", ""] {
            XCTAssertEqual(ChromiumLaunchArguments.releaseArguments(["ReArc", "--profile-directory=" + escape]), ["ReArc"], escape)
        }
        XCTAssertTrue(ChromiumLaunchArguments.isPlainProfileDirectory("Default"))
        XCTAssertTrue(ChromiumLaunchArguments.isPlainProfileDirectory("Profile 3"))
    }

    /// A shipped bundle given a data folder refuses to start rather than open the person's own data.
    func testAShippedBundleRefusesADataFolderOrProfileFolder() {
        XCTAssertNotNil(ShippedBuild.launchRefusal(arguments: ["ReArc"], environment: ["REARC_DATA_DIR": "/tmp/x"], shipped: true))
        XCTAssertNotNil(ShippedBuild.launchRefusal(arguments: ["ReArc", "--user-data-dir=/tmp/x"], environment: [:], shipped: true))
        XCTAssertNotNil(ShippedBuild.launchRefusal(arguments: ["ReArc", "--user-data-dir", "/tmp/x"], environment: [:], shipped: true))
        XCTAssertNil(ShippedBuild.launchRefusal(arguments: ["ReArc", "-psn_0_1", "https://x.test"], environment: ["REARC_DATA_DIR": ""], shipped: true))
        XCTAssertNil(ShippedBuild.launchRefusal(arguments: ["ReArc", "--user-data-dir=/tmp/x"], environment: ["REARC_DATA_DIR": "/tmp/x"], shipped: false))
    }

    /// Profiles made by builds 500 to 564 abort without these features (build 602), so every
    /// launch passes them, whatever argv says.
    func testPersistedProfileFeaturesReachTheEngineInEveryLaunch() {
        let feature = ChromiumLaunchArguments.persistedProfileFeatures
        XCTAssertTrue(feature.contains("PrepopulatedEnginesMigration") && feature.contains("ApplySearchEngineTypeMigration"))
        for (isRelease, isShipped) in [(false, false), (true, false), (true, true)] {
            for argv in [["ReArc"], ["ReArc", "--enable-features=Other", "--disable-features=PrepopulatedEnginesMigration"]] {
                let arguments = ChromiumLaunchArguments.engineArguments(argv, defaultUserDataDir: { "/data" }, keychain: .system,
                                                                       isRelease: isRelease, isShipped: isShipped)
                XCTAssertEqual(arguments.last, feature, "release \(isRelease), shipped \(isShipped), argv \(argv)")
                XCTAssertEqual(Array(arguments.dropLast()), ChromiumLaunchArguments.browserArguments(
                    argv, defaultUserDataDir: { "/data" }, keychain: .system, isRelease: isRelease, isShipped: isShipped))
            }
        }
        XCTAssertEqual(ChromiumLaunchArguments.engineArguments(["ReArc"], defaultUserDataDir: { "/d" }, keychain: .devMock, isRelease: false).last, feature)
    }

    func testShippedIsReleaseWithoutTheVerificationKey() {
        XCTAssertTrue(ShippedBuild.isShipped(infoDictionary: ["ReArcRelease": true]))
        XCTAssertFalse(ShippedBuild.isShipped(infoDictionary: ["ReArcRelease": true, "ReArcReleaseVerification": true]))
        XCTAssertTrue(ShippedBuild.isVerificationBundle(infoDictionary: ["ReArcRelease": true, "ReArcReleaseVerification": true]))
        XCTAssertFalse(ShippedBuild.isVerificationBundle(infoDictionary: ["ReArcReleaseVerification": true]), "only a release bundle")
        XCTAssertFalse(ShippedBuild.isShipped(infoDictionary: [:]))
        XCTAssertFalse(ShippedBuild.current, "the test runner is no shipped bundle")
    }

    func testReleaseIgnoresDiagnosticFlagsUnlessVerificationEnvironmentIsSet() {
        let flags = ["ReArc", "--rearc-selftest", "--rearc-launch-probe=/tmp/probe", "--rearc-bench"]
        let shipped: [String: Any] = ["ReArcRelease": true, "ReArcDefaultEngine": "chromium"]
        let info = shipped.merging(["ReArcReleaseVerification": true]) { $1 }
        for environment in [[:], [EngineLaunchOptions.releaseVerificationEnvironmentKey: "1"]] {
            // RC-0.1.0-602 F-03, T-04: a shipped bundle has no self-test or probe, whatever the environment says.
            let shipping = EngineLaunchOptions.parse(arguments: flags + ["--user-data-dir=/tmp/fresh"], environment: environment,
                                                     infoDictionary: shipped, dataDirRefusal: { _ in nil })
            XCTAssertFalse(shipping.selfTest)
            XCTAssertNil(shipping.launchProbePath)
            XCTAssertNil(shipping.bench)
            XCTAssertNil(shipping.verificationRefusal)
        }
        XCTAssertFalse(EngineLaunchOptions.parse(arguments: flags + ["--user-data-dir=/tmp/fresh"], environment: [:], infoDictionary: info,
                                                 dataDirRefusal: { _ in nil }).selfTest, "the verification bundle still needs the environment")
        let verification = EngineLaunchOptions.parse(arguments: flags + ["--user-data-dir=/tmp/fresh"],
            environment: [EngineLaunchOptions.releaseVerificationEnvironmentKey: "1"], infoDictionary: info,
            dataDirRefusal: { _ in nil })
        XCTAssertNil(verification.verificationRefusal)
        XCTAssertTrue(verification.selfTest)
        XCTAssertEqual(verification.launchProbePath, "/tmp/probe")
        XCTAssertNil(EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-bench"],
            environment: [EngineLaunchOptions.releaseVerificationEnvironmentKey: "1"], infoDictionary: info).bench)
    }

    /// RC-0.1.0-544 F-03: a release self-test or probe never runs on the user's profile.
    func testReleaseVerificationRefusesAnyDataDirThatIsNotThrowaway() {
        let info: [String: Any] = ["ReArcRelease": true, "ReArcReleaseVerification": true, "ReArcDefaultEngine": "chromium"]
        let environment = [EngineLaunchOptions.releaseVerificationEnvironmentKey: "1"]
        for flag in ["--rearc-selftest", "--rearc-launch-probe=/tmp/probe"] {
            let missing = EngineLaunchOptions.parse(arguments: ["ReArc", flag], environment: environment, infoDictionary: info,
                                                    dataDirRefusal: { _ in XCTFail("no dir to check"); return nil })
            XCTAssertNotNil(missing.verificationRefusal)
            XCTAssertFalse(missing.selfTest)
            XCTAssertNil(missing.launchProbePath)
            var checked: [String] = []
            let used = EngineLaunchOptions.parse(arguments: ["ReArc", flag, "--user-data-dir", "/real"], environment: environment,
                                                 infoDictionary: info, dataDirRefusal: { checked.append($0); return "in use" })
            XCTAssertEqual(checked, ["/real"])
            XCTAssertEqual(used.verificationRefusal?.contains("in use"), true)
            XCTAssertFalse(used.selfTest)
            XCTAssertNil(used.launchProbePath)
        }
        // Development bundles keep their own temp default.
        let dev = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-selftest"], environment: [:],
                                            dataDirRefusal: { _ in XCTFail("dev builds are not checked"); return "x" })
        XCTAssertTrue(dev.selfTest)
        XCTAssertNil(dev.verificationRefusal)
    }

    func testThrowawayDataDirIsNewOrEmptyAndOutsideTheShellData() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("rearc-f03-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("ReArc", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Chromium/Default"), withIntermediateDirectories: true)
        let refusal = { ReleaseVerificationDataDir.refusal($0, protectedRoots: [root]) }
        XCTAssertNil(refusal(base.appendingPathComponent("absent").path))
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(refusal(empty.path))
        XCTAssertNotNil(refusal(root.path))
        XCTAssertNotNil(refusal(root.appendingPathComponent("Chromium").path))
        XCTAssertNotNil(refusal(root.appendingPathComponent("Chromium/../Chromium/New").path))
        XCTAssertNotNil(refusal(base.path), "an ancestor of the data dir")
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Chromium"))
        XCTAssertNotNil(refusal(link.path), "a symlink to the real profile")
        let used = base.appendingPathComponent("used", isDirectory: true)
        try fm.createDirectory(at: used, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: used.appendingPathComponent("Local State"))
        XCTAssertNotNil(refusal(used.path), "an existing profile elsewhere")
        let file = base.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertNotNil(refusal(file.path))
        XCTAssertNotNil(refusal(""))
    }
}
