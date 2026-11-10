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
        var saved: (String, Int)?
        var relaunched = 0
        var importCategories: [ImportCategory] { ImportCategory.allCases }
        func discoverSources(_ done: @escaping (BrowserScan) -> Void) { done(scans.isEmpty ? BrowserScan() : scans.removeFirst()) }
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

    private func player(_ host: Host, opened: @escaping (ImportPermission) -> Void = { _ in }, elsewhere: Bool = false) -> SunrisePlayer {
        let player = SunrisePlayer(variant: .horizon, reduced: true)
        player.audio = nil
        player.host = host
        player.onToggleWindow = { [unowned player] in player.windowed.toggle() }
        player.presentSettings = { permission, done in opened(permission); done(elsewhere) }
        player.hideSettingsHelper = {}
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
        XCTAssertTrue(player.windowed, "out of full screen, so Settings comes up in front")
        XCTAssertEqual(host.saved?.0, "Kai")
        XCTAssertEqual(host.saved?.1, 1)
        XCTAssertEqual(player.act2?.settingsElsewhere, true)
        XCTAssertEqual(player.act2?.permissionLines?.steps, "System Settings opened on your other display.")

        player.applicationBecameActive()
        XCTAssertFalse(player.windowed, "full screen again")
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
        XCTAssertEqual(player.act2?.permissionLines?.steps, "Switch on ReArc in Full Disk Access, then come back.")
        XCTAssertEqual(player.act2?.offersRelaunch, false, "no relaunch before Settings was visited")
        player.allowAccess()
        XCTAssertEqual(opened, [.fullDiskAccess], "one pane covers Chrome and Safari")
        player.applicationBecameActive()
        let act2 = try XCTUnwrap(player.act2)
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
        let size = NSSize(width: 300, height: 92)
        XCTAssertEqual(SettingsAccess.helperOrigin(size: size, near: settings, screen: nil, displays: screens),
                       NSPoint(x: 1800, y: 96), "under System Settings")
        let low = NSRect(x: 100, y: 20, width: 700, height: 600)
        XCTAssertEqual(SettingsAccess.helperOrigin(size: size, near: low, screen: nil, displays: screens),
                       NSPoint(x: -212, y: 44), "beside it when there is no room below")
    }
}
