import XCTest
@testable import SidebarModel

/// About ReArc's line under the version (AboutUpdate.swift): the feed's
/// version shown only when it is one, every state's words, and the
/// once-a-minute limit on asking the feed.
final class AboutUpdateTests: XCTestCase {
    private let latest = AvailableUpdate(version: "2026.1114.741", build: UpdateBuild(741))
    private let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func notice(_ events: UpdateNotice.Event...) -> UpdateNotice {
        var notice = UpdateNotice()
        for event in events { notice.send(event) }
        return notice
    }

    private func line(_ notice: UpdateNotice = UpdateNotice(), _ check: UpdateInformationCheck.State = .idle,
                      lastChecked: Date? = nil) -> AboutUpdateLine? {
        AboutUpdateLine.line(notice: notice, check: check, lastChecked: lastChecked, formatDate: { _ in "today at 2:05 PM" })
    }

    // MARK: The feed's version

    func testTheDatedVersionShowsAsItIs() {
        XCTAssertEqual(ReArcVersion.display("2026.1114.741", build: UpdateBuild(741)), "2026.1114.741")
        XCTAssertEqual(ReArcVersion.display(" 2026.1114.741\n", build: UpdateBuild(741)), "2026.1114.741", "Sparkle's text, trimmed")
        XCTAssertEqual(ReArcVersion.display("2026.1114.00741", build: UpdateBuild(741)), "2026.1114.00741", "a padded build is still its build")
    }

    func testAnOlderVersionShowsItsBuild() {
        XCTAssertEqual(ReArcVersion.display("0.1.0", build: UpdateBuild(677)), "0.1.0 (677)")
        XCTAssertEqual(ReArcVersion.display("0.1.0", build: nil), "0.1.0")
        XCTAssertEqual(ReArcVersion.display("2026.1114.740", build: UpdateBuild(741)), "2026.1114.740 (741)", "another build's version names the real one")
    }

    func testFeedTextThatIsNotAVersionIsNeverShown() {
        for text in ["", "ReArc 2026", "2026.1114.741 beta", "2026.1114.741\u{202E}", "１.２", "1..2", ".1", "1.",
                     "1.2.3.4.5", String(repeating: "1", count: 10), "1.2." + String(repeating: "3", count: 20),
                     "<b>1</b>", "1.0-beta", "-1"] {
            XCTAssertNil(ReArcVersion.display(text, build: UpdateBuild(741)), text)
        }
        let odd = AvailableUpdate(version: "Click here", build: UpdateBuild(741))
        XCTAssertEqual(AboutUpdateLine.latest(odd), "build 741", "the build alone")
        XCTAssertNil(AboutUpdateLine.latest(AvailableUpdate(version: "Click here")))
    }

    // MARK: Every state

    func testAnUpdateTheNoticeHolds() {
        XCTAssertEqual(line(notice(.found(latest, downloaded: false))),
                       AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available", action: .install))
        XCTAssertEqual(line(notice(.found(latest, downloaded: true))),
                       AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available", action: .install), "downloaded: installs at once")
        var critical = latest
        critical.urgency = .critical
        XCTAssertEqual(line(notice(.found(critical, downloaded: false)))?.text, "Latest: 2026.1114.741 — Critical update available")
        var required = latest
        required.urgency = .required
        XCTAssertEqual(line(notice(.found(required, downloaded: false)))?.text, "Latest: 2026.1114.741 — Required update")
        let old = AvailableUpdate(version: "0.1.0", build: UpdateBuild(677))
        XCTAssertEqual(line(notice(.found(old, downloaded: false)))?.text, "Latest: 0.1.0 (677) — Update available")
        XCTAssertEqual(line(notice(.found(AvailableUpdate(version: "?"), downloaded: false)))?.text, "Update available")
        // The notice's state wins over About's own check.
        XCTAssertEqual(line(notice(.found(latest, downloaded: false)), .upToDate)?.action, .install)
    }

    func testTheInstallInProgressAndItsFailure() {
        XCTAssertEqual(line(notice(.found(latest, downloaded: false), .installRequested, .downloadStarted, .downloadExpected(100), .downloadReceived(42))),
                       AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available", detail: "Downloading… 42%"))
        XCTAssertEqual(line(notice(.found(latest, downloaded: true), .installRequested))?.detail, "Restarting ReArc…")
        XCTAssertEqual(line(notice(.found(latest, downloaded: false), .installRequested, .failed(.offline))),
                       AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available",
                                       detail: "ReArc can't reach the update server. Check your connection.", action: .retryInstall))
    }

    func testAboutsOwnCheck() {
        XCTAssertNil(line(), "nothing asked yet")
        XCTAssertEqual(line(UpdateNotice(), .checking), AboutUpdateLine(text: "Checking…"))
        XCTAssertEqual(line(UpdateNotice(), .upToDate, lastChecked: day),
                       AboutUpdateLine(text: "You have the latest version.", detail: "Last checked today at 2:05 PM"))
        XCTAssertEqual(line(UpdateNotice(), .upToDate), AboutUpdateLine(text: "You have the latest version."))
        XCTAssertEqual(line(UpdateNotice(), .failed), AboutUpdateLine(text: "Couldn't check for updates.", action: .checkAgain))
        XCTAssertNil(line(UpdateNotice(), .found), "found, but the notice let it go")
    }

    func testButtonsUseTheNoticesWords() {
        XCTAssertEqual(AboutUpdateLine.Action.install.title, "Restart and Update")
        XCTAssertEqual(AboutUpdateLine.Action.retryInstall.title, "Try Again")
        XCTAssertEqual(AboutUpdateLine.Action.checkAgain.title, "Try Again")
    }

    func testLastCheckedIsADate() {
        XCTAssertFalse(AboutUpdateLine.lastCheckedText(day).isEmpty)
    }

    // MARK: Once a minute

    func testOnceAMinute() {
        var check = UpdateInformationCheck()
        XCTAssertTrue(check.shouldStart(at: day, noticeHoldsUpdate: false))
        check.started(at: day)
        XCTAssertFalse(check.shouldStart(at: day.addingTimeInterval(1), noticeHoldsUpdate: false), "one at a time")
        XCTAssertFalse(check.shouldStart(at: day.addingTimeInterval(1), noticeHoldsUpdate: false, force: true), "Try Again too")
        check.finished(.notFound)
        XCTAssertEqual(check.state, .upToDate)
        XCTAssertFalse(check.shouldStart(at: day.addingTimeInterval(59.9), noticeHoldsUpdate: false))
        XCTAssertTrue(check.shouldStart(at: day.addingTimeInterval(60), noticeHoldsUpdate: false))
        XCTAssertTrue(check.shouldStart(at: day.addingTimeInterval(10), noticeHoldsUpdate: false, force: true), "Try Again is the person's")
        XCTAssertTrue(check.shouldStart(at: day.addingTimeInterval(-10), noticeHoldsUpdate: false), "a clock set back")
        XCTAssertFalse(check.shouldStart(at: day.addingTimeInterval(600), noticeHoldsUpdate: true), "the notice already knows")
    }

    func testOnlyTheAwaitedSessionChangesTheLine() {
        var check = UpdateInformationCheck()
        check.finished(.failed)
        XCTAssertEqual(check.state, .idle, "a scheduled check About did not wait for")
        check.started(at: day)
        check.finished(.found)
        XCTAssertEqual(check.state, .found)
        check.finished(.failed)
        XCTAssertEqual(check.state, .found)
        check.started(at: day.addingTimeInterval(60))
        check.finished(.failed)
        XCTAssertEqual(check.state, .failed)
    }
}
