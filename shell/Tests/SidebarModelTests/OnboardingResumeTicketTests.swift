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
        func action(_ env: [String: String], _ here: String, _ t: OnboardingResumeTicket?, gone: Set<String> = [], shipped: Bool = false,
                    bound: String? = ticket.nonce) -> OnboardingResumeTicket.LaunchAction {
            OnboardingResumeTicket.launchAction(environment: env, bundlePath: here, ticket: t, shipped: shipped,
                                                exists: { present.subtracting(gone).contains($0) }, boundNonce: { _ in bound })
        }
        XCTAssertEqual(action([:], demo, nil), .none, "an ordinary launch")
        XCTAssertEqual(action(["REARC_DATA_DIR": "/tmp/demo"], demo, ticket), .none, "our own relaunch names its folder")
        XCTAssertEqual(action([:], demo, ticket), .adopt(dataDirectory: "/tmp/demo"), "Quit & Reopen of the demo: its folder, not the default")
        XCTAssertEqual(action([:], "/Applications/ReArc.app", real), .adopt(dataDirectory: nil), "a real install resumes on its default folder")
        // RC-0.1.0-602 T-06: never another bundle, never a folder ReArc did not bind to the ticket.
        XCTAssertEqual(action([:], other, ticket), .none, "another copy's ticket: this copy launches as usual and opens nothing")
        XCTAssertEqual(action([:], other, ticket, gone: [demo]), .none, "even when the writer is gone")
        XCTAssertEqual(action([:], demo, ticket, gone: ["/tmp/demo"]), .discard, "its folder was deleted")
        XCTAssertEqual(action([:], demo, ticket, bound: nil), .discard, "a folder that holds no nonce")
        XCTAssertEqual(action([:], demo, ticket, bound: "another"), .discard, "a folder bound to another ticket")
        XCTAssertEqual(action([:], demo, ticket, shipped: true), .discard, "a shipped bundle stays on the person's own folder")
        XCTAssertEqual(action(["REARC_DATA_DIR": "/tmp/demo"], "/Applications/ReArc.app", real, shipped: true), .adopt(dataDirectory: nil),
                       "a shipped bundle ignores the environment too")
    }

    func testABoundFolderAndAPrivateTicketAreRequired() throws {
        let folder = url.deletingLastPathComponent()
        let data = folder.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let ticket = OnboardingResumeTicket(dataDirectory: data.path, bundlePath: "/x/ReArc.app", name: "Kai", colourIndex: 1, isRehearsal: false)
        XCTAssertNil(OnboardingResumeTicket.boundNonce(in: data.path))
        ticket.bindDataDirectory(data)
        XCTAssertEqual(OnboardingResumeTicket.boundNonce(in: data.path), ticket.nonce)
        XCTAssertEqual(OnboardingResumeTicket.launchAction(environment: [:], bundlePath: "/x/ReArc.app", ticket: ticket, shipped: false),
                       .adopt(dataDirectory: data.path))
        let marker = data.appendingPathComponent(OnboardingResumeTicket.markerName)
        chmod(marker.path, 0o644)
        XCTAssertNil(OnboardingResumeTicket.boundNonce(in: data.path), "a marker others can read or write is not ReArc's")

        ticket.write(to: url)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(OnboardingResumeTicket.current(at: url), ticket)
        chmod(url.path, 0o666)
        XCTAssertNil(OnboardingResumeTicket.current(at: url), "a ticket others could have written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "and it is removed")

        let elsewhere = folder.appendingPathComponent("planted.json")
        ticket.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        XCTAssertNil(OnboardingResumeTicket.current(at: url), "a link is never followed")
    }

    func testTheRelaunchLogNeverFollowsALinkAndDropsControlCharacters() throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("victim.txt")
        try Data("keep\n".utf8).write(to: target)
        let log = folder.appendingPathComponent("relaunch.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        OnboardingResumeTicket.log("evil", to: log)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
        try FileManager.default.removeItem(at: log)
        OnboardingResumeTicket.log("opened by x\n2026-01-01 pid 1 forged line\u{1b}[2J", to: log)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertFalse(text.contains("\u{1b}"))
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
