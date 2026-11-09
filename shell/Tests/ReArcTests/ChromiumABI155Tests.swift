import XCTest
@testable import ReArc

final class ChromiumABI155Tests: XCTestCase {
    func testBackgroundTabsNeedMinorFeatureAndExtensionWindows() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 54, hasFeature: { _ in true }).extensionBackgroundTabs)
        let current = ChromiumCapabilities(abiMinorVersion: 55, hasFeature: { _ in true })
        XCTAssertTrue(current.extensionBackgroundTabs)
        XCTAssertTrue(current.summary.hasSuffix("devtools_docking=1 extension_background_tabs=1"))
        for missing in ["extension_background_tabs", "extension_windows"] {
            XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 55, hasFeature: { $0 != missing }).extensionBackgroundTabs)
        }
        XCTAssertFalse(ChromiumCapabilities.none.extensionBackgroundTabs)
    }
}
