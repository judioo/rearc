import XCTest
@testable import SidebarModel

final class BoostTests: XCTestCase {

    func testSecurityRejectsRemoteCSSImport() {
        let css = "@import url(\"https://evil.test/x.css\"); body{}"
        XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: true).contains(.remoteImportInCSS))
    }

    func testSecurityRejectsStyleBreakout() {
        let css = "body { }</style><script>alert(1)</script>"
        XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: true).contains(.styleBreakoutInCSS))
    }

    func testSecurityRejectsRemoteScriptSrc() {
        let js = "var s = document.createElement('script'); s.src = 'https://evil.test/a.js';"
        XCTAssertTrue(BoostSecurity.validateJS(js).contains(.remoteScriptSourceInJS))
    }

    func testImportRejectsStyleWithScriptPayload() {
        let package = BoostPackage.newStyle(
            name: "Bad",
            hostScope: [BoostHostRule(host: "example.com")],
            css: "body{}"
        )
        var data = try! BoostInterchange.exportJSON(package)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["scriptBoost"] = ["js": "alert(1)", "userScriptEnabled": false]
        data = try! JSONSerialization.data(withJSONObject: object)
        if case .failure(.validationFailed(let errors)) = BoostInterchange.importJSON(data) {
            XCTAssertTrue(errors.contains(.scriptInStylePackage))
        } else {
            XCTFail("expected validation failure")
        }
    }

    func testActivationMatrixSpacePolicy() {
        let profile = Profile.personalDefault()
        var library = ProfileBoostLibrary(profileID: profile.id)
        let package = BoostPackage.newStyle(
            name: "Hide",
            hostScope: [BoostHostRule(host: "example.com")],
            css: ".ad { display: none !important; }"
        )
        _ = BoostLibraryOps.add(package, to: &library, enabled: false)
        _ = BoostLibraryOps.setSpacePolicy(
            packageID: package.manifest.id,
            spaceID: UUID(),
            policy: .forceOn,
            library: &library
        )
        let spaceID = library.installations[0].spacePolicy.keys.first!
        let url = URL(string: "https://example.com/page")!
        let context = BoostTabContext(profileID: profile.id, spaceID: spaceID, url: url)
        XCTAssertTrue(BoostActivation.effectiveEnabled(
            installation: library.installations[0],
            library: library,
            context: context
        ))
        let offContext = BoostTabContext(profileID: profile.id, spaceID: spaceID, url: url)
        var offLibrary = library
        offLibrary.masterEnabled = false
        XCTAssertFalse(BoostActivation.effectiveEnabled(
            installation: offLibrary.installations[0],
            library: offLibrary,
            context: offContext
        ))
    }

    func testCrossProfileIsolation() {
        let profileA = Profile.personalDefault()
        let profileB = Profile(name: "Work")
        var library = ProfileBoostLibrary(profileID: profileA.id)
        let package = BoostPackage.newStyle(
            name: "A",
            hostScope: [BoostHostRule(host: "example.com")],
            css: "body{}"
        )
        _ = BoostLibraryOps.add(package, to: &library, enabled: true)
        let url = URL(string: "https://example.com")!
        let wrongProfile = BoostTabContext(profileID: profileB.id, spaceID: nil, url: url)
        XCTAssertTrue(BoostActivation.activeEntries(library: library, context: wrongProfile).isEmpty)
    }

    func testScriptImportStartsDisabled() {
        let package = BoostPackage.newScript(
            name: "Script",
            hostScope: [BoostHostRule(host: "example.com")],
            js: "console.log('hi')"
        )
        XCTAssertFalse(BoostInterchange.defaultEnabledOnImport(package))
    }

    func testExportImportRoundTripForksID() throws {
        let original = BoostPackage.newStyle(
            name: "Theme",
            hostScope: [BoostHostRule(host: "github.com")],
            css: "body { background: #111; }"
        )
        let data = try BoostInterchange.exportJSON(original)
        guard case .success(let imported) = BoostInterchange.importJSON(data, sourceURL: "file:///tmp/x.json") else {
            return XCTFail("import failed")
        }
        XCTAssertNotEqual(imported.manifest.id, original.manifest.id)
        XCTAssertEqual(imported.provenance.imported, true)
        XCTAssertEqual(imported.provenance.sourceURL, "file:///tmp/x.json")
        XCTAssertEqual(imported.manifest.version, 1)
    }

    func testSelectorScoringPrefersTestIdOverHashedClass() {
        let descriptor = ElementDescriptor(
            tag: "button",
            classes: ["css-1a2b3c4d5e"],
            attrs: ["data-testid": "close-dialog"]
        )
        let candidates = SelectorScoringEngine.generateCandidates(from: descriptor)
        let ranked = SelectorScoringEngine.rank(candidates, descriptor: descriptor)
        let top = ranked[0]
        XCTAssertTrue(top.0.css.contains("data-testid"))
        XCTAssertGreaterThan(top.1, 0.7)
    }

    func testSelectorRejectsInhumanClassToken() {
        XCTAssertFalse(SelectorTokenHeuristics.isHumanToken("css-1a2b3c4d5e6f7g8h"))
    }

    func testPerHostMatchingList() {
        let store = SidebarStore()
        _ = store.createBoostForCurrentSite(
            name: "Ex",
            css: "body{}",
            pageURL: URL(string: "https://www.example.com/a")!
        )
        let matches = store.boostsMatchingPage(URL(string: "https://example.com/b")!)
        XCTAssertEqual(matches.count, 1)
    }

    func testSnapshotV5MigratesToV6WithBoostLibrary() throws {
        let store = SidebarStore()
        _ = store.createBoostForCurrentSite(
            name: "Site",
            css: "body{}",
            pageURL: URL(string: "https://github.com/a")!
        )
        var snapshot = store.makeSnapshot()
        snapshot.schemaVersion = 5
        snapshot.boostLibrariesByProfileID = [:]
        let data = try JSONEncoder().encode(snapshot)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 5
        object.removeValue(forKey: "boostLibrariesByProfileID")
        let migrated = try JSONDecoder().decode(
            SidebarSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(migrated.schemaVersion, 10)
        XCTAssertNotNil(migrated.boostLibrariesByProfileID[store.activeProfileID])
    }

    func testDescriptorPipelineTopThreeCandidates() {
        let snapshot = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "button",
                id: "close-btn",
                classes: ["modal-close", "css-9f8a7b6c5"],
                attrs: ["aria-label": "Close", "data-testid": "dialog-close"],
                role: "button",
                accessibleName: "Close",
                structuralPath: ["div", "div", "button"],
                indexAmongType: 2
            ),
            bounds: ElementBounds(x: 10, y: 10, width: 40, height: 40),
            viewportWidth: 1000,
            viewportHeight: 800
        )
        let top = BoostEditorPipeline.topCandidates(from: snapshot, limit: 3)
        XCTAssertGreaterThanOrEqual(top.count, 1)
        XCTAssertLessThanOrEqual(top.count, 3)
        XCTAssertTrue(top[0].candidate.css.contains("data-testid") || top[0].candidate.css.contains("aria-label"))
        XCTAssertGreaterThanOrEqual(top[0].score, top[1].score)
    }

    func testSelfHealingAcceptsHighSimilarityWithMargin() {
        let fp = BoostSelectorFingerprint(
            tag: "button",
            role: "button",
            accessibleName: "Close",
            classHints: ["modal-close"],
            rectAreaRatio: 0.01
        )
        let good = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "button",
                classes: ["modal-close"],
                attrs: ["aria-label": "Close"],
                role: "button",
                accessibleName: "Close"
            ),
            bounds: ElementBounds(x: 0, y: 0, width: 20, height: 20),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let runner = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "button",
                classes: ["other"],
                attrs: ["aria-label": "Submit"],
                role: "button",
                accessibleName: "Submit"
            ),
            bounds: ElementBounds(x: 0, y: 0, width: 20, height: 20),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let decision = BoostSelectorRepair.considerRepair(fingerprint: fp, scan: [good, runner])
        if case .sessionApply = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected session apply")
        }
    }

    func testSelfHealingRejectsBelow082Floor() {
        let fp = BoostSelectorFingerprint(tag: "button", accessibleName: "Close")
        let weak = PickedElementSnapshot(
            descriptor: ElementDescriptor(tag: "button", accessibleName: "Dismiss"),
            bounds: ElementBounds(x: 0, y: 0, width: 10, height: 10),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let decision = BoostSelectorRepair.considerRepair(fingerprint: fp, scan: [weak])
        if case .stale(.belowSimilarityFloor) = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected below floor")
        }
    }

    func testSelfHealingRejectsInsufficientMargin() {
        let fp = BoostSelectorFingerprint(
            tag: "button",
            accessibleName: "Close",
            classHints: ["modal-close"]
        )
        let a = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "button",
                classes: ["modal-close"],
                attrs: ["aria-label": "Close"],
                accessibleName: "Close"
            ),
            bounds: ElementBounds(x: 0, y: 0, width: 20, height: 20),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let b = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "button",
                classes: ["modal-close"],
                attrs: ["aria-label": "Close dialog"],
                accessibleName: "Close dialog"
            ),
            bounds: ElementBounds(x: 0, y: 0, width: 20, height: 20),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let simA = BoostSelectorRepair.similarity(node: a, fingerprint: fp)
        let simB = BoostSelectorRepair.similarity(node: b, fingerprint: fp)
        guard simA >= BoostSelectorRepair.similarityFloor,
              simB >= BoostSelectorRepair.similarityFloor,
              simA - simB < BoostSelectorRepair.marginFloor else {
            return
        }
        let decision = BoostSelectorRepair.considerRepair(fingerprint: fp, scan: [a, b])
        if case .stale(.insufficientMargin) = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected margin rejection")
        }
    }

    func testSelfHealingTagGuardBlocksMainMismatch() {
        let fp = BoostSelectorFingerprint(
            tag: "button",
            role: "main",
            accessibleName: "Primary",
            classHints: ["content"],
            ancestorCues: [BoostAncestorCue(tag: "main")],
            rectAreaRatio: 0.02
        )
        let mainHit = PickedElementSnapshot(
            descriptor: ElementDescriptor(
                tag: "main",
                classes: ["content"],
                role: "main",
                accessibleName: "Primary",
                structuralPath: ["main"]
            ),
            bounds: ElementBounds(x: 0, y: 0, width: 200, height: 200),
            viewportWidth: 1000,
            viewportHeight: 1000
        )
        let sim = BoostSelectorRepair.similarity(node: mainHit, fingerprint: fp)
        XCTAssertGreaterThanOrEqual(sim, BoostSelectorRepair.similarityFloor)
        let decision = BoostSelectorRepair.considerRepair(fingerprint: fp, scan: [mainHit])
        if case .stale(.tagGuard) = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected tag guard")
        }
    }

    func testQuickActionHideAndZapSimilar() {
        let sel = "div.item:nth-of-type(3)"
        let hide = BoostQuickActions.hideElementRule(selector: sel)
        XCTAssertTrue(hide.contains("display: none"))
        let zap = BoostQuickActions.zapSimilarRule(selector: sel)
        XCTAssertFalse(zap.contains("nth-of-type(3)"))
        XCTAssertTrue(zap.contains("div.item"))
    }

    func testLiveEditSessionNotPersistedUntilSave() {
        let package = BoostPackage.newStyle(
            name: "Live",
            hostScope: [BoostHostRule(host: "example.com")],
            css: "body { color: red; }"
        )
        var store = SidebarStore()
        _ = store.addBoost(package)
        let draft = BoostEditorDraft(packageID: package.manifest.id, baselineCSS: package.styleBoost!.css)
        var edited = draft
        edited.draftCSS = "body { color: blue; }"
        XCTAssertTrue(edited.isDirty)
        let saved = store.boostLibrary().package(id: package.manifest.id)!
        XCTAssertEqual(saved.styleBoost?.css, "body { color: red; }")
        XCTAssertTrue(store.updateBoostStyleCSS(packageID: package.manifest.id, css: edited.draftCSS))
        let after = store.boostLibrary().package(id: package.manifest.id)!
        XCTAssertEqual(after.styleBoost?.css, "body { color: blue; }")
        XCTAssertGreaterThan(after.manifest.version, package.manifest.version)
    }

    func testSnapshotV6RoundTripWithEditedBoostCSS() throws {
        var store = SidebarStore()
        let created = store.createBoostForCurrentSite(
            name: "Edited",
            css: "body {}",
            pageURL: URL(string: "https://example.com")!
        )!
        _ = store.updateBoostStyleCSS(
            packageID: created.manifest.id,
            css: ".ad { display: none !important; }"
        )
        let snapshot = store.makeSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, 10)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        let pkg = decoded.boostLibrariesByProfileID[store.activeProfileID]!.packages.first!
        XCTAssertEqual(pkg.styleBoost?.css, ".ad { display: none !important; }")
    }

    func testDuplicateBoostCreatesNewPackage() {
        var store = SidebarStore()
        let created = store.createBoostForCurrentSite(
            name: "One",
            css: "body{}",
            pageURL: URL(string: "https://example.com")!
        )!
        let copy = store.duplicateBoost(packageID: created.manifest.id)!
        XCTAssertNotEqual(copy.manifest.id, created.manifest.id)
        XCTAssertEqual(store.boostLibrary().packages.count, 2)
    }
}
