import XCTest
@testable import SidebarModel

final class HighRemediationRound2Tests: XCTestCase {

    func testFutureSchemaVersionIsRejected() throws {
        let store = SidebarStore.sample()
        let data = try JSONEncoder().encode(store.makeSnapshot())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 99
        let patched = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SidebarSnapshot.self, from: patched))
    }

    func testCorruptSidebarFileIsQuarantined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-hr2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("sidebar.json")
        try Data("{".utf8).write(to: url)
        let persistence = SidebarFilePersistence(fileURL: url)
        XCTAssertNil(persistence.loadSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let quarantined = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertTrue(quarantined.contains(where: { $0.hasPrefix("sidebar.corrupt-") }))
    }

    func testStyleCSSRejectsRemoteURLFetch() {
        let css = "body { background-image: url(https://example.test/beacon); }"
        XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: true).contains(.remoteImportInCSS))
    }

    func testInvalidPackageSkippedFromActiveEntries() {
        var library = ProfileBoostLibrary(profileID: UUID())
        let install = BoostInstallation(packageID: UUID(), enabled: true, order: 0)
        let pkg = BoostPackage(
            manifest: BoostManifest(
                id: install.packageID,
                name: "Bad",
                hostScope: [BoostHostRule(host: "github.io", hostMatch: .registrable)],
                payloadKinds: [.style]
            ),
            styleBoost: BoostStylePayload(css: "body{color:red}")
        )
        library.upsertPackage(pkg, installation: install)
        let context = BoostTabContext(
            profileID: library.profileID,
            spaceID: UUID(),
            url: URL(string: "https://alice.github.io/page")!
        )
        XCTAssertTrue(BoostActivation.activeEntries(library: library, context: context).isEmpty)
    }

    func testGitHubTenantGetsExactDefaultScope() {
        let url = URL(string: "https://alice.github.io/docs")!
        let rule = BoostScopeMatcher.defaultRule(forPage: url)
        XCTAssertEqual(rule?.host, "alice.github.io")
        XCTAssertEqual(rule?.hostMatch, .exact)
    }

    func testSelectorCandidatesUseDocumentMatchCounts() {
        let descriptor = ElementDescriptor(
            tag: "div",
            classes: ["card"],
            tagMatchCount: 40,
            classMatchCounts: ["card": 12]
        )
        let candidates = SelectorScoringEngine.generateCandidates(from: descriptor)
        let classCandidate = candidates.first { $0.css.contains(".card") }
        XCTAssertEqual(classCandidate?.matchCount, 12)
    }

    func testCaptureFilenameCanonicalization() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(
            CaptureRecord.canonicalFileName(id: id, proposed: "../../escape.png"),
            "\(id.uuidString).png"
        )
        let record = CaptureRecord(
            id: id,
            sourceURL: nil,
            sourceTitle: "t",
            scope: .visible,
            fileName: "../../escape.png"
        )
        let store = CaptureFileStore(directoryURL: FileManager.default.temporaryDirectory)
        let url = store.fileURL(for: record)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".png"))
        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).png")
    }
}
