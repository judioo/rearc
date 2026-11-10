import XCTest
@testable import ReArc

/// Shell side of the RC-500 engine fixes: how the fullscreen hint (F-08) and
/// the breach toast (F-09) name a site from the engine's serialized origin.
final class SecurityAuditShellTests: XCTestCase {
    func testDisplaySiteNamesTheOrigin() {
        XCTAssertEqual(BrowserViewModel.displaySite("https://bank.example"), "bank.example")
        XCTAssertEqual(BrowserViewModel.displaySite("https://bank.example:8443"), "bank.example:8443")
        XCTAssertEqual(BrowserViewModel.displaySite("http://bank.example"), "http://bank.example", "an insecure origin keeps its scheme")
        XCTAssertEqual(BrowserViewModel.displaySite("null"), "This page", "an opaque origin names no site")
    }
}
