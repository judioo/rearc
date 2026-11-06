import QuartzCore
import XCTest
@testable import ReArc

/// Launch: the early window's capability gate and its off-main frame clock.
final class LaunchEarlyWindowTests: XCTestCase {
    func testEarlyWindowCapabilityNeedsABI45() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 44, hasFeature: all).earlyWindow)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 45, hasFeature: all).earlyWindow)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 45, hasFeature: { $0 != "early_window" }).earlyWindow)
        XCTAssertFalse(ChromiumCapabilities.none.earlyWindow)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 45, hasFeature: all).summary.contains("early_window=1"))
    }

    func testFrameClockHostTimeIsCACurrentMediaTime() {
        let before = CACurrentMediaTime()
        let host = LaunchFrameClock.seconds(hostTime: mach_absolute_time())
        let after = CACurrentMediaTime()
        XCTAssertGreaterThanOrEqual(host, before)
        XCTAssertLessThanOrEqual(host, after)
    }

    func testFrameClockReportsARefreshAfterTheCommit() throws {
        let clock = LaunchFrameClock()
        let committed = CACurrentMediaTime()
        try XCTSkipUnless(clock.start(after: committed, screen: nil), "no active display for a CVDisplayLink")
        let presented = try XCTUnwrap(clock.presented(timeout: 2))
        XCTAssertGreaterThan(presented, committed)
        XCTAssertLessThan(presented - committed, 0.5)
        XCTAssertEqual(clock.presented(timeout: 0), presented)
    }
}
