import XCTest
@testable import ReArc

/// A quit either finishes or undoes itself (`ChromiumQuit`); in a Chromium
/// build no page falls back to WebKit while the engine runs (`EngineChoice`).
final class ChromiumQuitTests: XCTestCase {
    func testAnIdleQuitStartsAtOnce() {
        var quit = ChromiumQuit()
        XCTAssertEqual(quit.request(force: false, mustDefer: false), .start(force: false))
        XCTAssertTrue(quit.isStopping)
        XCTAssertEqual(quit.bound, ChromiumQuit.stallBound)
        XCTAssertEqual(quit.completed(cancelled: false), .none)
        XCTAssertEqual(quit.phase, .ending)
        XCTAssertNil(quit.bound)
    }

    func testADeferredShutdownThatNeverStartsIsForcedAfterTheBound() {
        var quit = ChromiumQuit()
        XCTAssertEqual(quit.request(force: false, mustDefer: true), .none)
        XCTAssertEqual(quit.phase, .deferred(force: false))
        XCTAssertEqual(quit.bound, ChromiumQuit.deferBound)
        XCTAssertEqual(quit.boundPassed(), .start(force: true))
        XCTAssertEqual(quit.phase, .started(force: true, escalated: true))
        // The engine finishes the forced shutdown.
        XCTAssertEqual(quit.completed(cancelled: false), .none)
        XCTAssertEqual(quit.phase, .ending)
    }

    func testARejectedForcedShutdownAfterTheBoundEndsTheProcess() {
        var quit = ChromiumQuit()
        _ = quit.request(force: false, mustDefer: true)
        _ = quit.boundPassed()
        XCTAssertEqual(quit.startRejected(), .abandon)
        XCTAssertEqual(quit.phase, .ending)
    }

    func testAStartedShutdownWithNoProgressEndsTheProcess() {
        var quit = ChromiumQuit()
        _ = quit.request(force: false, mustDefer: false)
        XCTAssertEqual(quit.boundPassed(), .abandon)
        XCTAssertEqual(quit.phase, .ending)
        XCTAssertEqual(quit.boundPassed(), .none)
    }

    func testADeferredShutdownStartsWhenTheClosesFinish() {
        var quit = ChromiumQuit()
        _ = quit.request(force: true, mustDefer: true)
        XCTAssertEqual(quit.becameIdle(), .start(force: true))
        XCTAssertEqual(quit.phase, .started(force: true, escalated: false))
        XCTAssertEqual(quit.becameIdle(), .none)
    }

    func testAVetoLeavesTheRuntimeActiveAgain() {
        var quit = ChromiumQuit()
        _ = quit.request(force: false, mustDefer: false)
        XCTAssertEqual(quit.completed(cancelled: true), .undo)
        XCTAssertFalse(quit.isStopping)
        XCTAssertNil(quit.bound)
        XCTAssertEqual(ChromiumTabAdmission(.ready), .create)
        // The next quit starts again (the runtime forces it).
        XCTAssertEqual(quit.request(force: true, mustDefer: false), .start(force: true))
    }

    func testARejectionLeavesTheRuntimeActiveAgain() {
        var quit = ChromiumQuit()
        _ = quit.request(force: false, mustDefer: false)
        XCTAssertEqual(quit.startRejected(), .undo)
        XCTAssertFalse(quit.isStopping)

        // Rejected once its deferral ended (not escalated): undone too.
        _ = quit.request(force: false, mustDefer: true)
        _ = quit.becameIdle()
        XCTAssertEqual(quit.startRejected(), .undo)
        XCTAssertEqual(quit.phase, .idle)
    }

    func testAnotherQuitDuringOneChangesNothing() {
        var quit = ChromiumQuit()
        _ = quit.request(force: false, mustDefer: true)
        XCTAssertEqual(quit.request(force: true, mustDefer: false), .none)
        XCTAssertEqual(quit.phase, .deferred(force: false))
        _ = quit.becameIdle()
        XCTAssertEqual(quit.request(force: true, mustDefer: false), .none)
        XCTAssertEqual(quit.phase, .started(force: false, escalated: false))
    }

    func testStaleEventsAreIgnored() {
        var quit = ChromiumQuit()
        XCTAssertEqual(quit.completed(cancelled: true), .none)
        XCTAssertEqual(quit.startRejected(), .none)
        XCTAssertEqual(quit.boundPassed(), .none)
        XCTAssertEqual(quit.phase, .idle)
    }

    func testTheBoundsOutlastTheEnginesOwnCloseDeadline() {
        // close_controller force-closes a tab after 30 s.
        XCTAssertGreaterThan(ChromiumQuit.stallBound, 30)
        XCTAssertLessThan(ChromiumQuit.deferBound, ChromiumQuit.stallBound)
        XCTAssertNotEqual(ChromiumQuit.abandonedExitCode, 0)
    }

    // MARK: Engine choice

    private let stages: [ChromiumRuntimeStage] = [.unavailable, .starting, .ready, .quitting, .ended]

    func testAChromiumBuildNeverMakesWebKitWhileTheEngineRuns() {
        for stage in stages where stage != .unavailable {
            XCTAssertEqual(EngineChoice(chromiumBuild: true, stage: stage), .chromium, "\(stage)")
        }
        // Only a process where Chromium does not run at all uses WebKit.
        XCTAssertEqual(EngineChoice(chromiumBuild: true, stage: .unavailable), .webKit)
    }

    func testAWebKitBuildAlwaysMakesWebKit() {
        for stage in stages {
            XCTAssertEqual(EngineChoice(chromiumBuild: false, stage: stage), .webKit, "\(stage)")
        }
    }

    func testTabsWaitBeforeReadyAndDuringAQuit() {
        XCTAssertEqual(ChromiumTabAdmission(.starting), .wait)
        XCTAssertEqual(ChromiumTabAdmission(.quitting), .wait)
        XCTAssertEqual(ChromiumTabAdmission(.ready), .create)
        XCTAssertEqual(ChromiumTabAdmission(.ended), .refuse)
        XCTAssertEqual(ChromiumTabAdmission(.unavailable), .refuse)
    }

    // MARK: Shell termination

    func testTheHostsTerminatingFlagIsClearedOnCancel() {
        var termination = ShellTermination()
        XCTAssertTrue(termination.begin(), "the first request saves the window session")
        XCTAssertTrue(termination.isTerminating)
        XCTAssertFalse(termination.begin(), "a second request during the quit saves nothing")
        termination.cancel()
        XCTAssertFalse(termination.isTerminating)
        XCTAssertTrue(termination.begin(), "the next quit saves the session again")
    }

    // MARK: Windows during a quit

    func testAQuitHidesEveryWindowOnceAndShowsThemBackInTheirOrder() {
        var windows = QuitWindows<String>()
        XCTAssertNil(windows.reveal(), "nothing to show before a quit")
        XCTAssertEqual(windows.hide(["front", "middle", "back"]), ["front", "middle", "back"])
        XCTAssertTrue(windows.isHiding)
        XCTAssertEqual(windows.hide(["late"]), [], "a second request in the same quit hides nothing more")
        // Back to front: each one ordered in goes in front of the last, so "front" ends up in front.
        XCTAssertEqual(windows.reveal(), ["back", "middle", "front"])
        XCTAssertFalse(windows.isHiding)
        XCTAssertNil(windows.reveal(), "a Leave site? that showed them leaves nothing for the undo")
    }

    func testAQuitWithNoWindowStillComesBack() {
        var windows = QuitWindows<String>()
        XCTAssertEqual(windows.hide([]), [])
        // The Dock icon and menu bar come back even though no window does.
        XCTAssertEqual(windows.reveal(), [])
        XCTAssertEqual(windows.hide(["next"]), ["next"], "the next quit hides again")
    }
}
