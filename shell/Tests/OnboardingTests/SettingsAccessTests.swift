import AppKit
@testable import Onboarding
import SidebarModel
import XCTest

/// Act 2's way to System Settings and back, with a fake host: nothing opens
/// System Settings, nothing reads this Mac's browsers.
@MainActor
final class SettingsAccessTests: XCTestCase {
    final class Host: OnboardingHost {
        var scans: [BrowserScan] = []
        /// When set, a scan waits here instead of answering at once.
        var held: ((BrowserScan) -> Void)?
        var holds = false
        var saved: (String, Int)?
        var relaunched = 0
        var importCategories: [ImportCategory] { ImportCategory.allCases }
        func discoverSources(_ done: @escaping (BrowserScan) -> Void) {
            if holds { held = done; return }
            done(scans.isEmpty ? BrowserScan() : scans.removeFirst())
        }
        var canRelaunch: Bool { true }
        func relaunchForAccess() { relaunched += 1 }
        func saveResumePoint(name: String, colourIndex: Int) { saved = (name, colourIndex) }
        func bring(_ sources: [ImportSource], categories: [ImportCategory], done: @escaping (OnboardingImportOutcome) -> Void) {}
        func apply(_ result: OnboardingResult) {}
        func revealBrowser(in frame: NSRect, below overlay: NSWindow) {}
        func onboardingFinished() {}
    }

    let chromeLocked = PendingBrowser(browser: .chrome, state: .needsPermission(.appData))
    let safariLocked = PendingBrowser(browser: .safari, state: .needsPermission(.fullDiskAccess))

    private var restored = 0

    private func player(_ host: Host, opened: @escaping (ImportPermission) -> Void = { _ in }, elsewhere: Bool = false) -> SunrisePlayer {
        let player = SunrisePlayer(variant: .horizon, reduced: true)
        player.audio = nil
        player.host = host
        player.presentSettings = { permission, done in opened(permission); done(elsewhere) }
        player.restoreAfterSettings = { [unowned self] in self.restored += 1 }
        return player
    }

    func testARelaunchResumesAtTheBrowserStepWithActOnesAnswers() throws {
        let host = Host()
        host.scans = [BrowserScan(sources: [ImportSource.demo[0]], pending: [chromeLocked])]
        let player = player(host)
        player.resumeAtBrowsers(name: "Kai", colourIndex: 2)
        let act1 = try XCTUnwrap(player.act1)
        XCTAssertEqual(act1.submitted?.name, "Kai")
        XCTAssertEqual(act1.picked?.index, 2)
        XCTAssertGreaterThan(player.time(at: Date()), try XCTUnwrap(act1.handOff), "past the sunrise and Act 1")
        let act2 = try XCTUnwrap(player.act2)
        XCTAssertEqual(act2.pending, [chromeLocked])
        XCTAssertEqual(act2.sources.map(\.id), [ImportSource.demo[0].id])
    }

    func testAllowAccessLeavesFullScreenAndTheReturnFlipsTheBrowser() throws {
        let host = Host()
        let chrome = ImportSource.demo[2]
        host.scans = [BrowserScan(sources: [ImportSource.demo[0]], pending: [chromeLocked]),
                      BrowserScan(sources: [ImportSource.demo[0], chrome])]
        var opened: [ImportPermission] = []
        let player = player(host, opened: { opened.append($0) }, elsewhere: true)
        player.resumeAtBrowsers(name: "Kai", colourIndex: 1)
        XCTAssertEqual(player.act2?.permissionButton, "Allow access\u{2026}")
        XCTAssertEqual(player.act2?.permissionLines?.steps, "Under ReArc in Files & Folders, switch on Chrome, then come back.")

        player.allowAccess()
        XCTAssertEqual(opened, [.appData])
        XCTAssertEqual(host.saved?.0, "Kai")
        XCTAssertEqual(host.saved?.1, 1)
        XCTAssertEqual(player.act2?.settingsElsewhere, true)
        XCTAssertEqual(player.act2?.permissionLines?.steps, "System Settings opened on your other display.")

        player.applicationBecameActive()
        XCTAssertEqual(restored, 1, "its own presentation again")
        let act2 = try XCTUnwrap(player.act2)
        XCTAssertEqual(act2.sources.map(\.id), [ImportSource.demo[0].id, chrome.id])
        XCTAssertTrue(act2.pending.isEmpty)
        XCTAssertNotNil(act2.arrivals[1], "Chrome flips to Found")
        XCTAssertNil(act2.permissionLines)
    }

    func testStillLockedAfterFullDiskAccessOffersOneRelaunchButton() throws {
        let host = Host()
        host.scans = [BrowserScan(pending: [chromeLocked, safariLocked]), BrowserScan(pending: [chromeLocked, safariLocked])]
        var opened: [ImportPermission] = []
        let player = player(host, opened: { opened.append($0) })
        player.resumeAtBrowsers(name: "Kai", colourIndex: 0)
        XCTAssertEqual(player.act2?.permissionLines?.explanation, "macOS keeps Chrome and Safari private.")
        XCTAssertEqual(player.act2?.permissionLines?.steps,
                       "Switch on ReArc in Full Disk Access. If macOS offers Quit & Reopen, choose Later, then come back.")
        XCTAssertEqual(player.act2?.offersRelaunch, false, "no relaunch before Settings was visited")
        player.allowAccess()
        XCTAssertEqual(opened, [.fullDiskAccess], "one pane covers Chrome and Safari")
        player.applicationBecameActive()
        let act2 = try XCTUnwrap(player.act2)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(act2.offersRelaunch)
        XCTAssertEqual(act2.permissionButton, "Relaunch ReArc")
        XCTAssertEqual(act2.permissionLines?.steps, "Switched on? macOS applies it when ReArc starts again.")
        XCTAssertNil(act2.choice, "no clean start while a browser waits")
        player.relaunchForAccess()
        XCTAssertEqual(host.relaunched, 1)
    }

    func testWindowServerBoundsBecomeAppKitFramesOnTheRightDisplay() {
        // A primary 1440x900 display and a second one to its right.
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: -180, width: 1920, height: 1080)]
        let settings = SettingsAccess.appKitFrame(fromWindowServer: CGRect(x: 1600, y: 100, width: 700, height: 600), primaryHeight: 900)
        XCTAssertEqual(settings, NSRect(x: 1600, y: 200, width: 700, height: 600))
        XCTAssertEqual(SettingsAccess.screenIndex(of: settings, in: screens), 1)
        XCTAssertEqual(SettingsAccess.screenIndex(of: NSRect(x: 100, y: 100, width: 300, height: 300), in: screens), 0)
        XCTAssertNil(SettingsAccess.screenIndex(of: NSRect(x: -5000, y: 0, width: 10, height: 10), in: screens))
        XCTAssertEqual(SettingsAccess.screenIndex(of: NSRect(x: 0, y: 0, width: 1440, height: 900), in: screens), 0)
    }

    func testTheSceneAndHelperShareTheFreeColumnBesideSettings() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        // Settings where it usually opens, centred: the right column is as wide as the left; right wins.
        let centred = SettingsCompanionLayout.layout(screen: screen, settings: nil, helper: SettingsAccess.helperSize)
        let assumed = NSRect(x: 1728 / 2 - 357.5, y: 1079 / 2 - 345, width: 715, height: 690)
        XCTAssertFalse(centred.scene.intersects(assumed))
        XCTAssertGreaterThanOrEqual(centred.scene.minX, assumed.maxX)
        let helper = try! XCTUnwrap(centred.helper)
        XCTAssertFalse(helper.intersects(assumed))
        XCTAssertFalse(helper.intersects(centred.scene), "the helper sits under the scene")
        XCTAssertEqual(helper.minY, 16, "at the foot of the column")
        let notifications = NSRect(x: screen.maxX - 400, y: screen.maxY - 180, width: 400, height: 180)
        XCTAssertFalse(helper.intersects(notifications), "clear of macOS's top-right notifications")
        XCTAssertFalse(centred.scene.intersects(notifications))
        XCTAssertEqual(centred.scene.width / centred.scene.height, 1.6, accuracy: 0.01)
        XCTAssertTrue(screen.contains(centred.scene) && screen.contains(helper))

        // Settings near the right edge: the column is on the left.
        let right = NSRect(x: 1000, y: 200, width: 715, height: 690)
        let left = SettingsCompanionLayout.layout(screen: screen, settings: right, helper: nil)
        XCTAssertLessThanOrEqual(left.scene.maxX, right.minX)
        XCTAssertNil(left.helper, "no helper for Files & Folders")

        // A small display with Settings in the middle: over its sidebar at most, never its list.
        let small = NSRect(x: 0, y: 0, width: 1280, height: 777)
        let middle = NSRect(x: 280, y: 40, width: 715, height: 690)
        let tight = SettingsCompanionLayout.layout(screen: small, settings: middle, helper: SettingsAccess.helperSize)
        XCTAssertEqual(tight.scene.minX, 16)
        XCTAssertLessThanOrEqual(tight.scene.maxX, middle.minX + 230, "Settings' sidebar is about 230 pt")

        // Settings on a second display: the column is on that display.
        let second = NSRect(x: 1728, y: 0, width: 1920, height: 1055)
        let there = SettingsCompanionLayout.layout(screen: second, settings: NSRect(x: 2200, y: 200, width: 715, height: 690),
                                                   helper: SettingsAccess.helperSize)
        XCTAssertTrue(second.contains(there.scene) && second.contains(there.helper!))
    }

    func testQuitAndReopenIsRecommendedOnlyForASingleInstall() {
        var log = Act2Log(start: 0, sources: [], pending: [safariLocked])
        XCTAssertEqual(log.permissionLines?.steps,
                       "Switch on ReArc in Full Disk Access. If macOS offers Quit & Reopen, choose Later, then come back.")
        log.quitAndReopenIsSafe = true
        XCTAssertEqual(log.permissionLines?.steps, "Switch on ReArc in Full Disk Access. If macOS offers Quit & Reopen, choose it.")
    }

    func testActTwoWaitsForAScanStartedAtTheColourPick() throws {
        let host = Host()
        host.holds = true
        let player = player(host)
        player.startScanIfNeeded()
        XCTAssertNotNil(host.held, "the scan runs")
        player.startAct2()
        XCTAssertNil(player.act2, "Act 2 waits for it")
        host.held?(BrowserScan(sources: [ImportSource.demo[0]], pending: [chromeLocked]))
        let act2 = try XCTUnwrap(player.act2)
        XCTAssertEqual(act2.pending, [chromeLocked])
        XCTAssertTrue(act2.arrivals.isEmpty, "found at the start: no Found rings")
    }
}
