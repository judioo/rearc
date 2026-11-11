@testable import ReArc
import XCTest

/// Relaunching opens this very bundle by its URL, on the same data folder
/// and arguments; nothing here launches anything.
final class ReArcRelaunchTests: XCTestCase {
    func testTheHelperRequestRoundTripsThisBundleAndItsArguments() throws {
        let bundle = URL(fileURLWithPath: "/Users/x/dist/demo/ReArc.app", isDirectory: true)
        let args = ReArcRelaunch.arguments(["/exe", "-psn_0_1234", "--onboarding", "--reopen-import", "--rearc-relaunch-helper"],
                                           reopenImport: false)
        XCTAssertEqual(args, ["--onboarding"])
        XCTAssertEqual(ReArcRelaunch.arguments(["/exe"], reopenImport: true), ["--reopen-import"])
        let argv = ["/exe"] + ReArcRelaunch.helperArguments(pid: 4242, bundle: bundle, arguments: ["--onboarding", "--"])
        let request = try XCTUnwrap(ReArcRelaunch.request(from: argv))
        XCTAssertEqual(request.pid, 4242)
        XCTAssertEqual(request.bundle.path, bundle.path, "by path, never by bundle id")
        XCTAssertEqual(request.arguments, ["--onboarding", "--"])
        XCTAssertNil(ReArcRelaunch.request(from: ["/exe", "--onboarding"]), "a normal launch is not a helper")
    }

    func testOnlyTheDataFolderIsPassedOn() {
        XCTAssertEqual(ReArcRelaunch.environment(["REARC_DATA_DIR": "/tmp/demo", "HOME": "/Users/x"]), ["REARC_DATA_DIR": "/tmp/demo"])
        XCTAssertEqual(ReArcRelaunch.environment(["HOME": "/Users/x"]), [:])
    }

    /// RC-0.1.0-602 T-09: the helper reopens only its own bundle, for the ReArc that started it.
    func testTheHelperOpensOnlyItsOwnBundleForItsParent() {
        let own = URL(fileURLWithPath: "/Applications/ReArc.app", isDirectory: true)
        let request = { (path: String, pid: pid_t) in ReArcRelaunch.Request(pid: pid, bundle: URL(fileURLWithPath: path, isDirectory: true), arguments: []) }
        XCTAssertTrue(ReArcRelaunch.accepts(request("/Applications/ReArc.app", 4242), ownBundle: own, parent: 4242))
        XCTAssertTrue(ReArcRelaunch.accepts(request("/Applications/./ReArc.app", 4242), ownBundle: own, parent: 4242))
        XCTAssertFalse(ReArcRelaunch.accepts(request("/System/Applications/Calculator.app", 4242), ownBundle: own, parent: 4242),
                       "any other app")
        XCTAssertFalse(ReArcRelaunch.accepts(request("/Applications/ReArc.app", 4242), ownBundle: own, parent: 999),
                       "started by some other process")
        let live = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(ReArcRelaunch.accepts(request("/Applications/ReArc.app", live), ownBundle: own, parent: 1),
                       "orphaned, but the named ReArc is still running: not its relaunch")
        XCTAssertFalse(ReArcRelaunch.accepts(request("/usr/bin", 4242), ownBundle: URL(fileURLWithPath: "/usr/bin"), parent: 4242),
                       "only from an app bundle")
    }
}
