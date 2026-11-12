import XCTest
import SidebarModel
@testable import ReArc

/// The notice's shared center: one Automatic Updates setting behind the card
/// and Settings, Restart and Update reaching the updater, and the preview
/// hook a shipped bundle refuses.
@MainActor
final class UpdateNoticeCenterTests: XCTestCase {
    /// Stands in for Sparkle's updater and its `automaticallyDownloadsUpdates`.
    private final class FakeDriver: UpdateNoticeDriving {
        var automaticallyDownloadsUpdates = false
        var installs = 0
        var informationChecks = 0
        var sessionRunning = false
        var lastUpdateCheckDate: Date?
        func installFromNotice() { installs += 1 }
        func checkForUpdateInformation() -> Bool {
            guard !sessionRunning else { return false }
            informationChecks += 1
            return true
        }
    }

    private let update = AvailableUpdate(version: "0.1.0", build: UpdateBuild(700))

    func testCheckboxAndSettingsShareOneSetting() {
        let center = UpdateNoticeCenter()
        let driver = FakeDriver()
        driver.automaticallyDownloadsUpdates = true
        center.driver = driver
        XCTAssertTrue(center.automaticUpdates, "starts from the updater's value")

        // The card's checkbox (and Settings' switch: the same binding) writes through.
        center.setAutomaticUpdates(false)
        XCTAssertFalse(driver.automaticallyDownloadsUpdates)
        XCTAssertFalse(center.automaticUpdates)

        // Settings, or Sparkle itself, changes it: the checkbox follows (KVO in AppUpdater).
        driver.automaticallyDownloadsUpdates = true
        center.automaticUpdatesChanged(true)
        XCTAssertTrue(center.automaticUpdates)
    }

    func testCheckboxWithoutAnUpdaterChangesNothing() {
        let center = UpdateNoticeCenter()
        center.setAutomaticUpdates(true)
        XCTAssertFalse(center.automaticUpdates)
    }

    func testRestartAndUpdateAsksTheUpdaterOnce() {
        let center = UpdateNoticeCenter()
        let driver = FakeDriver()
        center.driver = driver
        center.install()
        XCTAssertEqual(driver.installs, 0, "nothing to install")

        center.send(.found(update, downloaded: false))
        XCTAssertEqual(center.sidebarUpdate, update)
        center.install()
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(center.notice.phase, .downloading(UpdateProgress()))
        center.install()
        XCTAssertEqual(driver.installs, 1, "the button waits while it downloads")
    }

    func testHiddenNoticeLeavesTheSidebars() {
        let center = UpdateNoticeCenter()
        center.send(.found(update, downloaded: false))
        center.hide()
        XCTAssertNil(center.sidebarUpdate)
        XCTAssertTrue(center.notice.menuState.updateAvailable)
    }

    func testPointerVisitIsRecorded() {
        let center = UpdateNoticeCenter()
        center.pointerVisited()
        XCTAssertFalse(center.notice.pointerVisited, "no update, nothing to visit")
        center.send(.found(update, downloaded: true))
        center.pointerVisited()
        XCTAssertTrue(center.notice.pointerVisited)
    }

    // MARK: Preview hook

    private let shipped: [String: Any] = ["ReArcRelease": true]
    private let verification: [String: Any] = ["ReArcRelease": true, "ReArcReleaseVerification": true]

    func testPreviewRunsInADevelopmentBuild() {
        let state = UpdateNoticePreview.requestedState(arguments: ["rearc", "--rearc-update-notice-preview=critical"],
                                                       environment: [:], infoDictionary: [:])
        XCTAssertEqual(state, .critical)
    }

    func testAShippedBundleRefusesThePreview() {
        for environment in [[:], ["REARC_RELEASE_VERIFICATION": "1"]] {
            XCTAssertNil(UpdateNoticePreview.requestedState(arguments: ["rearc", "--rearc-update-notice-preview=required"],
                                                            environment: environment, infoDictionary: shipped))
        }
    }

    func testAVerificationBundleNeedsItsVariable() {
        let arguments = ["rearc", "--rearc-update-notice-preview=ready"]
        XCTAssertNil(UpdateNoticePreview.requestedState(arguments: arguments, environment: [:], infoDictionary: verification))
        XCTAssertEqual(UpdateNoticePreview.requestedState(arguments: arguments, environment: ["REARC_RELEASE_VERIFICATION": "1"],
                                                          infoDictionary: verification), .ready)
    }

    func testUnknownPreviewStatesAndNoFlagShowNothing() {
        XCTAssertNil(UpdateNoticePreview.requestedState(arguments: ["rearc", "--rearc-update-notice-preview=launch"], environment: [:], infoDictionary: [:]))
        XCTAssertNil(UpdateNoticePreview.requestedState(arguments: ["rearc"], environment: [:], infoDictionary: [:]))
        // The program name is never read as the flag.
        XCTAssertNil(UpdateNoticePreview.requestedState(arguments: ["--rearc-update-notice-preview=normal"], environment: [:], infoDictionary: [:]))
    }

    func testEveryPreviewStateShowsTheNotice() {
        for state in UpdateNoticePreview.State.allCases {
            let center = UpdateNoticeCenter(preview: state)
            XCTAssertTrue(center.isPreviewing)
            XCTAssertTrue(center.notice.isVisible, state.rawValue)
            switch state {
            case .critical: XCTAssertEqual(center.notice.urgency, .critical)
            case .required: XCTAssertEqual(center.notice.urgency, .required)
            case .ready: XCTAssertEqual(center.notice.phase, .ready)
            case .downloading: XCTAssertEqual(center.notice.phase, .downloading(UpdateProgress(received: 42, expected: 100)))
            case .preparing: XCTAssertEqual(center.notice.phase, .extracting(0.6))
            case .restarting: XCTAssertEqual(center.notice.phase, .installing)
            case .offline: XCTAssertEqual(center.notice.phase, .failed(.offline))
            case .signature: XCTAssertEqual(center.notice.phase, .failed(.signature))
            case .nospace: XCTAssertEqual(center.notice.phase, .failed(.noSpace))
            case .quitrefused: XCTAssertEqual(center.notice.phase, .failed(.quitRefused))
            case .normal: XCTAssertEqual(center.notice.phase, .available)
            }
        }
    }

    func testPreviewInstallPlaysWithoutQuitting() async throws {
        let center = UpdateNoticeCenter(preview: .normal)
        center.install()
        for _ in 0 ..< 60 where center.notice.phase != .installing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(center.notice.phase, .installing, "the preview stops at Restarting ReArc… and nothing quits")
    }

    // MARK: About ReArc

    func testAboutAsksTheFeedAtMostOnceAMinute() {
        let center = UpdateNoticeCenter()
        let driver = FakeDriver()
        center.driver = driver
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        center.checkUpdateInformation(now: opened)
        XCTAssertEqual(driver.informationChecks, 1)
        XCTAssertEqual(center.aboutLine?.text, "Checking…")
        center.checkUpdateInformation(now: opened.addingTimeInterval(5))
        XCTAssertEqual(driver.informationChecks, 1, "not while one runs")

        driver.lastUpdateCheckDate = opened
        center.updateInformationFinished(.notFound)
        XCTAssertEqual(center.aboutLine?.text, "You have the latest version.")
        XCTAssertEqual(center.lastUpdateCheckDate, opened)
        center.checkUpdateInformation(now: opened.addingTimeInterval(59))
        XCTAssertEqual(driver.informationChecks, 1, "a minute-old answer stands")
        XCTAssertEqual(center.aboutLine?.text, "You have the latest version.")
        center.checkUpdateInformation(now: opened.addingTimeInterval(60))
        XCTAssertEqual(driver.informationChecks, 2)
    }

    func testAboutReusesTheNoticesUpdate() {
        let center = UpdateNoticeCenter()
        let driver = FakeDriver()
        center.driver = driver
        center.send(.found(AvailableUpdate(version: "2026.1114.741", build: UpdateBuild(741)), downloaded: false))
        center.checkUpdateInformation()
        XCTAssertEqual(driver.informationChecks, 0, "the notice already knows")
        XCTAssertEqual(center.aboutLine, AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available", action: .install))
        // Hidden from the sidebar, it is still the latest, and About installs it the notice's way.
        center.hide()
        XCTAssertNil(center.sidebarUpdate)
        XCTAssertEqual(center.aboutLine?.action, .install)
        center.installFromAbout()
        XCTAssertEqual(driver.installs, 1)
        XCTAssertEqual(center.aboutLine, AboutUpdateLine(text: "Latest: 2026.1114.741 — Update available", detail: "Downloading…"))
        center.installFromAbout()
        XCTAssertEqual(driver.installs, 1, "the button is gone while it downloads")
    }

    func testAboutWaitsForASessionAlreadyRunning() {
        let center = UpdateNoticeCenter()
        let driver = FakeDriver()
        driver.sessionRunning = true
        center.driver = driver
        center.checkUpdateInformation()
        XCTAssertEqual(driver.informationChecks, 0, "never interrupts a session")
        XCTAssertEqual(center.aboutLine?.text, "Checking…")
        center.updateInformationFinished(.failed)
        XCTAssertEqual(center.aboutLine, AboutUpdateLine(text: "Couldn't check for updates.", action: .checkAgain))
        // Try Again is the person's: it asks at once, the minute notwithstanding.
        driver.sessionRunning = false
        center.checkUpdateInformation(force: true)
        XCTAssertEqual(driver.informationChecks, 1)
    }

    func testAboutWithoutAnUpdaterSaysNothing() {
        let center = UpdateNoticeCenter()
        center.checkUpdateInformation()
        XCTAssertNil(center.aboutLine)
    }

    func testAboutShowsThisVersion() {
        XCTAssertEqual(AboutInfo.version(["CFBundleShortVersionString": "2026.1112.726", "CFBundleVersion": "726"]),
                       "Version 2026.1112.726")
        XCTAssertEqual(AboutInfo.version(["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "726"]),
                       "Version 0.1.0 (726)", "a build from before the dated version")
        XCTAssertEqual(AboutInfo.version(["CFBundleShortVersionString": "0.1.0"]), "Version 0.1.0")
    }
}
