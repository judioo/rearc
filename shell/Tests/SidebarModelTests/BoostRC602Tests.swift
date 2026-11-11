import XCTest
@testable import SidebarModel

/// RC-0.1.0-602 N-02 (boost CSS: line endings, the text checked is the text the engine gets,
/// imported CSS waits for review) and F-12 (approvals).
final class BoostRC602Tests: XCTestCase {
    func testLineEndingsAreNormalisedBeforeCheckingAndInWhatTheEngineGets() throws {
        XCTAssertEqual(BoostSecurity.normalizedCSS("a\r\nb\rc\u{0C}d\ne"), "a\nb\nc\nd\ne")
        // A hex escape followed by CR LF: Blink takes CR LF as the escape's one whitespace.
        let css = "a{content:\"\\41\r\n\";background:url(\"data:x\")}"
        let rules = try XCTUnwrap(BoostStyleCompiler.compileStylesheet(css))
        XCTAssertFalse(rules.contains { $0.css.contains("\r") })
        XCTAssertFalse(BoostStyleCompiler.joinedForEngine(rules).contains("\r"))
    }

    func testTheJoinedSheetIsCheckedToo() {
        // Each piece alone is harmless; the newline-joined sheet the engine reads is checked as well.
        XCTAssertNil(BoostStyleCompiler.compileStylesheet("a{b:c} @import \"https://evil.test/x.css\";"))
        XCTAssertNotNil(BoostStyleCompiler.compileStylesheet("a{color:red} b{color:blue}"))
    }

    func testAnImportedBoostFilesCSSWaitsForReview() throws {
        let store = SidebarStore()
        let imported = BoostPackage.newStyle(name: "Shared", hostScope: [BoostHostRule(host: "docs.test")], css: "body{color:red}")
        XCTAssertNil(store.importBoostPackage(imported))
        let library = store.boostLibrary()
        let package = try XCTUnwrap(library.package(id: imported.manifest.id))
        XCTAssertFalse(library.styleApproved(package), "a file's CSS is reviewed before it applies")
        XCTAssertTrue(BoostLibraryListing.rows(library).first?.styleNeedsApproval == true)
        let own = BoostPackage.newStyle(name: "Mine", hostScope: [BoostHostRule(host: "docs.test")], css: "body{color:blue}")
        XCTAssertNil(store.addBoost(own))
        XCTAssertTrue(store.boostLibrary().styleApproved(try XCTUnwrap(store.boostLibrary().package(id: own.manifest.id))),
                      "CSS written on this Mac is its own")
    }

    func testApprovalTakesOnlyWhatTheSheetShowed() throws {
        let store = SidebarStore()
        let package = BoostPackage.newStyle(name: "Shared", hostScope: [BoostHostRule(host: "docs.test")], css: "body{color:red}")
        XCTAssertNil(store.importBoostPackage(package))
        let shown = try XCTUnwrap(BoostLibraryOps.styleApprovalHash(try XCTUnwrap(store.boostLibrary().package(id: package.manifest.id))))
        // A sync change lands while the sheet is open.
        var changed = package
        changed.styleBoost?.css = "body{color:blue}"
        var library = store.boostLibrary()
        library.upsertPackage(changed, installation: try XCTUnwrap(library.installation(for: package.manifest.id)))
        var snapshot = store.makeSnapshot()
        snapshot.boostLibrariesByProfileID[store.activeProfileID] = library
        store.applySnapshot(snapshot)
        XCTAssertFalse(store.approveBoostStyle(packageID: package.manifest.id, shownHash: shown))
        XCTAssertFalse(store.boostLibrary().styleApproved(try XCTUnwrap(store.boostLibrary().package(id: package.manifest.id))))
        let now = try XCTUnwrap(BoostLibraryOps.styleApprovalHash(try XCTUnwrap(store.boostLibrary().package(id: package.manifest.id))))
        XCTAssertTrue(store.approveBoostStyle(packageID: package.manifest.id, shownHash: now))
    }

    func testAMissingApprovalsMapApprovesNothing() {
        var library = ProfileBoostLibrary(profileID: UUID())
        let package = BoostPackage.newStyle(name: "x", hostScope: [], css: "a{}")
        _ = BoostLibraryOps.add(package, to: &library)
        library.approvedStyleHashes = nil
        library.approvedScriptHashes = nil
        XCTAssertFalse(library.styleApproved(package))
    }
}
