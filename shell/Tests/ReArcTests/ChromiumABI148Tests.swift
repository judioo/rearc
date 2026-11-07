import XCTest
@testable import ReArc

/// ABI 1.48: download history at scale (sliced loads, live limit, archived rows).
final class ChromiumABI148Tests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    func testDownloadHistoryNeedsABI48ItsFeatureAndDownloads() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: all).downloadHistory)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 48, hasFeature: all).downloadHistory)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 48, hasFeature: { $0 != "download_history" }).downloadHistory)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 48, hasFeature: { $0 != "downloads" }).downloadHistory)
        XCTAssertFalse(ChromiumCapabilities.none.downloadHistory)
    }

    func testSummaryListsTheFlag() {
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 48, hasFeature: all).summary.contains("download_history=1"))
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 47, hasFeature: all).summary.contains("download_history=0"))
    }
}
