import XCTest
@testable import SidebarModel

/// The note a relaunch for a privacy permission leaves, so the onboarding
/// comes back at its browser step on the same data folder.
final class OnboardingResumeTicketTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ReArcTicket-\(UUID().uuidString)/onboarding-resume.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testATicketResumesOnceForItsOwnBundleWhileFresh() {
        let now = Date()
        let ticket = OnboardingResumeTicket(dataDirectory: "/tmp/demo", bundlePath: "/x/ReArc.app", name: "Kai", colourIndex: 3,
                                            isRehearsal: false, written: now)
        ticket.write(to: url)
        XCTAssertNil(OnboardingResumeTicket.peek(at: url, bundlePath: "/Applications/ReArc.app", now: now), "another ReArc ignores it")
        XCTAssertEqual(OnboardingResumeTicket.peek(at: url, bundlePath: "/x/ReArc.app", now: now), ticket)
        XCTAssertEqual(OnboardingResumeTicket.take(at: url, bundlePath: "/x/ReArc.app", now: now), ticket)
        XCTAssertNil(OnboardingResumeTicket.take(at: url, bundlePath: "/x/ReArc.app", now: now), "once")
    }

    func testAStaleTicketIsDropped() {
        let then = Date(timeIntervalSinceNow: -OnboardingResumeTicket.lifetime - 1)
        OnboardingResumeTicket(dataDirectory: nil, bundlePath: "/x/ReArc.app", name: "Kai", colourIndex: 0, isRehearsal: true, written: then)
            .write(to: url)
        XCTAssertNil(OnboardingResumeTicket.peek(at: url, bundlePath: "/x/ReArc.app"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAReopenWithoutTheEnvironmentGetsTheTicketsDataFolder() {
        let ticket = OnboardingResumeTicket(dataDirectory: "/tmp/demo", bundlePath: "/x", name: "", colourIndex: 0, isRehearsal: false)
        XCTAssertEqual(OnboardingResumeTicket.dataDirectory(environment: [:], ticket: ticket), "/tmp/demo")
        XCTAssertNil(OnboardingResumeTicket.dataDirectory(environment: ["REARC_DATA_DIR": "/other"], ticket: ticket), "an explicit one wins")
        XCTAssertNil(OnboardingResumeTicket.dataDirectory(environment: [:], ticket: nil))
    }
}
