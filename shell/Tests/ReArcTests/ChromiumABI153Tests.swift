import XCTest
@testable import ReArc

final class ChromiumABI153Tests: XCTestCase {
    func testBulkInstallsNeedMinorFeatureAndProfiles() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 52, hasFeature: { _ in true }).extensionBulkInstall)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 53, hasFeature: { _ in true }).extensionBulkInstall)
        for missing in ["extension_bulk_install", "profiles"] {
            XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 53, hasFeature: { $0 != missing }).extensionBulkInstall)
        }
        XCTAssertFalse(ChromiumCapabilities.none.extensionBulkInstall)
    }
}
