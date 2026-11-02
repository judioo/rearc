import XCTest
@testable import ReArc
@testable import SidebarModel

final class HighRemediationReArcTests: XCTestCase {

    func testNavigationCommitUpdatesTabRecord() {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let tab = store.addTab(kind: .today, title: "Start", url: URL(string: "https://a.test")!)
        store.selectTab(tab.id)
        let vm = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        vm.handleTabNavigationCommit(
            tabID: tab.id,
            url: URL(string: "https://b.test/path")!,
            title: "B Title"
        )
        XCTAssertEqual(store.tab(withID: tab.id)?.url.absoluteString, "https://b.test/path")
        XCTAssertEqual(store.tab(withID: tab.id)?.title, "B Title")
    }

    func testSyncAllTabBoostsDoesNotConstructNewEngines() {
        let host = EngineHost()
        let store = SidebarStore(spaces: [Space(name: "Main")])
        _ = store.addTab(kind: .today, title: "One", url: URL(string: "https://one.test")!)
        _ = store.addTab(kind: .today, title: "Two", url: URL(string: "https://two.test")!)
        XCTAssertTrue(host.allTabEngines().isEmpty)
        let vm = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        vm.syncAllTabBoosts()
        XCTAssertTrue(host.allTabEngines().isEmpty)
    }

    func testPickerScriptIncludesMatchCountHints() {
        XCTAssertTrue(BoostPickerScript.bridgeSource.contains("tagMatchCount"))
        XCTAssertTrue(BoostPickerScript.bridgeSource.contains("classMatchCounts"))
    }

    func testCoordinatorIncludesSharedHostingList() {
        let source = BoostInjectionScriptBuilder.coordinatorSource(entries: [])
        XCTAssertTrue(source.contains("SHARED_HOSTING"))
        XCTAssertTrue(source.contains("github.io"))
    }

    func testLivePlanJSONUsesCssRules() {
        let json = BoostInjectionScriptBuilder.livePlanPayloadJSON(entries: [
            BoostRuntimeEntry(
                packageID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                order: 0,
                hostScope: [BoostHostRule(host: "example.com")],
                css: "body{color:red}",
                cssRules: [BoostCSSRule(id: "0", css: "body{color:red}")],
                js: nil,
                scriptUserEnabled: false
            )
        ])
        XCTAssertTrue(json.contains("cssRules"))
    }

    func testRepairScanScriptExists() {
        XCTAssertTrue(BoostPickerScript.bridgeSource.contains("scanRepairCandidates"))
    }
}
