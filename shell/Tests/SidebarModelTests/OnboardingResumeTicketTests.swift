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

    func testEachLaunchDecidesBeforeTouchingAnyData() {
        let demo = "/w/dist/demo/ReArc.app", other = "/w2/dist/chromium/ReArc.app"
        let ticket = OnboardingResumeTicket(dataDirectory: "/tmp/demo", bundlePath: demo, name: "Kai", colourIndex: 1, isRehearsal: false)
        let real = OnboardingResumeTicket(dataDirectory: nil, bundlePath: "/Applications/ReArc.app", name: "Kai", colourIndex: 1, isRehearsal: false)
        let present: Set<String> = ["/tmp/demo", demo, other, "/Applications/ReArc.app"]
        func action(_ env: [String: String], _ here: String, _ t: OnboardingResumeTicket?, gone: Set<String> = []) -> OnboardingResumeTicket.LaunchAction {
            OnboardingResumeTicket.launchAction(environment: env, bundlePath: here, ticket: t, exists: { present.subtracting(gone).contains($0) })
        }
        XCTAssertEqual(action([:], demo, nil), .none, "an ordinary launch")
        XCTAssertEqual(action(["REARC_DATA_DIR": "/tmp/demo"], demo, ticket), .none, "our own relaunch names its folder")
        XCTAssertEqual(action([:], demo, ticket), .adopt(dataDirectory: "/tmp/demo"), "Quit & Reopen of the demo: its folder, not the default")
        XCTAssertEqual(action([:], "/Applications/ReArc.app", real), .adopt(dataDirectory: nil), "a real install resumes on its default folder")
        XCTAssertEqual(action([:], other, ticket), .handOff(bundlePath: demo, dataDirectory: "/tmp/demo"),
                       "macOS reopened another copy: it hands over and quits")
        XCTAssertEqual(action([:], other, ticket, gone: [demo]), .adopt(dataDirectory: "/tmp/demo"), "the writer is gone: resume here")
        XCTAssertEqual(action([:], demo, ticket, gone: ["/tmp/demo"]), .discard, "its folder was deleted")
    }

    func testATicketFromBeforeTheNonceIsIgnored() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"a","bundlePath":"/x","colourIndex":1,"isRehearsal":false,"written":816037663}"#.utf8).write(to: url)
        XCTAssertNil(OnboardingResumeTicket.current(at: url))
    }

    func testTheRelaunchLogAppends() throws {
        let log = url.deletingLastPathComponent().appendingPathComponent("relaunch.log")
        OnboardingResumeTicket.log("first", to: log)
        OnboardingResumeTicket.log("second", to: log)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("second"))
        XCTAssertFalse(OnboardingResumeTicket.defaultURL.path.contains("/Library/Caches/"), "tests never use the real Caches")
    }
}
