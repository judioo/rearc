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
}
