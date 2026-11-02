import XCTest
@testable import SidebarModel

final class AuditTailWaveTests: XCTestCase {

    func testStyleCompilerSplitsAndEnforcesBudget() {
        let css = "body { color: red; }\n.card { display: none; }"
        let rules = BoostStyleCompiler.compileStylesheet(css, allowInStyle: true)
        XCTAssertEqual(rules?.count, 2)
        XCTAssertTrue(BoostSecurity.tabCSSBudgetOK(rules?.map(\.css) ?? []))
    }

    func testStyleCompilerRejectsRemoteURLInRule() {
        let css = "body { background: url(https://evil.test/x); }"
        XCTAssertNil(BoostStyleCompiler.compileStylesheet(css, allowInStyle: true))
    }

    func testNoOpBoostSaveDoesNotBumpVersion() {
        let pkg = BoostPackage.newStyle(name: "A", hostScope: [BoostHostRule(host: "a.test")], css: "body{}")
        let saved = BoostEditorSave.applySave(package: pkg, draftCSS: "body{}")
        XCTAssertEqual(saved?.manifest.version, pkg.manifest.version)
    }

    func testBoostSaveBumpsVersionOnContentChange() {
        let pkg = BoostPackage.newStyle(name: "A", hostScope: [BoostHostRule(host: "a.test")], css: "body{}")
        let saved = BoostEditorSave.applySave(package: pkg, draftCSS: "body{color:red}")
        XCTAssertEqual(saved?.manifest.version, pkg.manifest.version + 1)
    }

    func testCorruptLoadDisablesAutosaveUntilMutation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sidebar.json")
        try Data("{".utf8).write(to: url)
        let persistence = SidebarFilePersistence(fileURL: url)
        XCTAssertNil(persistence.loadSnapshot())
        XCTAssertFalse(persistence.autosaveEnabled)
        let store = SidebarStore.sample()
        persistence.start(autoSave: store)
        persistence.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.addTab(kind: .today, title: "Edited", url: URL(string: "https://edited.test")!)
        persistence.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNavigationPolicyRejectsJavascript() {
        XCTAssertFalse(NavigationURLPolicy.allows(URL(string: "javascript:alert(1)")!))
        XCTAssertTrue(NavigationURLPolicy.allows(URL(string: "https://example.com")!))
    }

    func testUniqueLiveMatchIncreasesScore() {
        let descriptor = ElementDescriptor(tag: "div", classes: ["card"], classMatchCounts: ["card": 1])
        let candidate = SelectorCandidate(steps: [.classToken("card")], css: ".card", matchCount: 1)
        let weak = SelectorCandidate(steps: [.classToken("card")], css: ".card", matchCount: 12)
        let strongScore = SelectorScoringEngine.score(candidate, descriptor: descriptor)
        let weakScore = SelectorScoringEngine.score(weak, descriptor: descriptor)
        XCTAssertGreaterThan(strongScore, weakScore)
    }

    func testSessionApplyMapHealedIDs() {
        var map = BoostSessionApplyMap()
        let id = UUID()
        map.setSessionSelector(storedSelectorKey: id, css: ".btn")
        XCTAssertTrue(map.isHealed(packageID: id))
    }

    func testCreateSplitRejectsDuplicateMembers() {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a")!)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b")!)
        XCTAssertNil(store.createSplit(tabIDs: [a.id, a.id], orientation: .horizontal))
        XCTAssertNotNil(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
    }
}
