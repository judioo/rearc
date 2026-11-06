import XCTest
@testable import ReArc

/// ABI 1.46: media capture (call card) and the default search engine choice.
final class ChromiumABI146Tests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    func testMediaCaptureNeedsABI46AndItsFeature() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 45, hasFeature: all).mediaCapture)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: all).mediaCapture)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: { $0 != "media_capture" }).mediaCapture)
        XCTAssertFalse(ChromiumCapabilities.none.mediaCapture)
    }

    func testSearchEnginesNeedsABI46AndItsFeature() {
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 45, hasFeature: all).searchEngines)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: all).searchEngines)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: { $0 != "search_engines" }).searchEngines)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 46, hasFeature: { $0 == "search_engines" }).searchEngines,
                      "independent of search_autocomplete")
    }

    func testSummaryListsBothFlags() {
        let summary = ChromiumCapabilities(abiMinorVersion: 46, hasFeature: { $0 == "media_capture" }).summary
        XCTAssertTrue(summary.contains("media_capture=1"))
        XCTAssertTrue(summary.contains("search_engines=0"))
    }
}
