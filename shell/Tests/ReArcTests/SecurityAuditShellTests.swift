import XCTest
@testable import ReArc
import SidebarModel

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

/// Security RC-0.1.0-544 F-02: the Settings row says what is happening.
final class SafeBrowsingRowTests: XCTestCase {
    func testOnlyDownloadedListsReadAsOn() {
        XCTAssertEqual(SafeBrowsingRow(.unavailable).value, "Unavailable")
        XCTAssertTrue(SafeBrowsingRow(.unavailable).isWarning)
        XCTAssertEqual(SafeBrowsingRow(.notUpdating).value, "Not working")
        XCTAssertTrue(SafeBrowsingRow(.notUpdating).isWarning)
        XCTAssertTrue(SafeBrowsingRow(.stale(lastUpdate: Date(timeIntervalSinceNow: -5 * 86400))).isWarning)
        XCTAssertFalse(SafeBrowsingRow(.waitingForLists).value == "On")
        let on = SafeBrowsingRow(.active(lastUpdate: Date()))
        XCTAssertEqual(on.value, "On")
        XCTAssertFalse(on.isWarning)
    }
}

/// Security RC-0.1.0-544 N-05: launch arguments cannot set preferences in a release build.
final class LaunchArgumentDefaultsTests: XCTestCase {
    func testReleaseBuildsDropTheArgumentDomain() throws {
        let suite = "rearc.n05.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain(["ReArcPasswordLeakDetection": false], forName: UserDefaults.argumentDomain)
        LaunchArgumentDefaults.drop(isRelease: false, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "ReArcPasswordLeakDetection") as? Bool, false, "development builds keep it")
        LaunchArgumentDefaults.drop(isRelease: true, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "ReArcPasswordLeakDetection"))
        XCTAssertNil(PasswordLeakDetectionPreference.load(from: defaults).explicitChoice)
    }
}
