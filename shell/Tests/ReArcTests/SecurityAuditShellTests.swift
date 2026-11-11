import XCTest
@testable import ReArc
import SidebarModel

/// Shell side of the RC-500 engine fixes: how the fullscreen hint (F-08) and
/// the breach toast (F-09) name a site from the engine's serialized origin.
final class SecurityAuditShellTests: XCTestCase {
    func testDisplaySiteNamesTheOrigin() {
        XCTAssertEqual(BrowserViewModel.displaySite("https://bank.example"), "bank.example")
        XCTAssertEqual(BrowserViewModel.displaySite("https://bank.example:8443"), "bank.example:8443")
        XCTAssertEqual(BrowserViewModel.displaySite("http://bank.example"), "http://bank.example", "an insecure origin keeps its scheme")
        XCTAssertEqual(BrowserViewModel.displaySite("null"), "This page", "an opaque origin names no site")
    }
}

/// Security RC-0.1.0-544 F-02: the Settings row says what is happening.
final class SafeBrowsingRowTests: XCTestCase {
    func testOnlyDownloadedListsReadAsOn() {
        XCTAssertEqual(SafeBrowsingRow(.unavailable).value, "Unavailable")
        XCTAssertTrue(SafeBrowsingRow(.unavailable).isWarning)
        XCTAssertEqual(SafeBrowsingRow(.notUpdating).value, "Not working")
        XCTAssertTrue(SafeBrowsingRow(.notUpdating).isWarning)
        XCTAssertTrue(SafeBrowsingRow(.stale(lastUpdate: Date(timeIntervalSinceNow: -5 * 86400))).isWarning)
        XCTAssertFalse(SafeBrowsingRow(.waitingForLists).value == "On")
        let on = SafeBrowsingRow(.active(lastUpdate: Date()))
        XCTAssertEqual(on.value, "On")
        XCTAssertFalse(on.isWarning)
    }
}

/// Security RC-0.1.0-544 N-05: launch arguments cannot set preferences in a release build.
final class LaunchArgumentDefaultsTests: XCTestCase {
    func testReleaseBuildsDropTheArgumentDomain() throws {
        let suite = "rearc.n05.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain(["ReArcPasswordLeakDetection": false], forName: UserDefaults.argumentDomain)
        LaunchArgumentDefaults.drop(isRelease: false, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "ReArcPasswordLeakDetection") as? Bool, false, "development builds keep it")
        LaunchArgumentDefaults.drop(isRelease: true, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "ReArcPasswordLeakDetection"))
        XCTAssertNil(PasswordLeakDetectionPreference.load(from: defaults).explicitChoice)
    }
}

/// Security RC-0.1.0-544 F-04: a permission card under a dialog or sign-in sheet takes no
/// input, and serves its delay again once uncovered.
final class PermissionCardCoverTests: XCTestCase {
    func testACoveredCardIsInertUntilItHasBeenVisibleForTheDelay() {
        var now: TimeInterval = 100
        let prompts = PagePromptCenter(permissionClock: { now })
        prompts.sitePermissions = SitePermissionsController(fileURL: nil)
        prompts.profileID = UUID()
        var replies: [PermissionDecision] = []
        prompts.presentDialog(JavaScriptDialogRequest(id: 1, kind: .alert, message: "click fast", origin: "https://game.test")) { _ in }
        prompts.presentPermission(PermissionPromptRequest(id: 2, origin: "https://game.test", types: [.camera])) { decision, _ in
            replies.append(decision)
        }
        XCTAssertTrue(prompts.permissionCovered)
        XCTAssertTrue(prompts.asksUser)
        now += 5
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies, [], "no input while covered, however long it waited")
        prompts.answerDialog(accept: true)
        XCTAssertFalse(prompts.permissionCovered)
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies, [], "the delay starts when it is uncovered")
        now += 0.5
        prompts.answerPermission(.allow)
        XCTAssertEqual(replies, [.allow])
    }

    func testLongHostsInToastsKeepTheirDomain() {
        let site = BrowserViewModel.displaySite("https://accounts.google.com.verify-session.evil.example")
        XCTAssertTrue(site.hasSuffix("evil.example"), site)
        XCTAssertEqual(BrowserViewModel.displaySite("https://bank.example"), "bank.example")
        XCTAssertEqual(BrowserViewModel.displaySite("http://bank.example:8080"), "http://bank.example:8080")
    }
}

/// Security RC-0.1.0-564 S-07: a deleted container's directory goes at the next launch.
final class ProfileDataRemovalTests: XCTestCase {
    func testScheduledDirectoriesAreRemovedButNeverDefaultOrASymlink() throws {
        let fm = FileManager.default
        let udd = fm.temporaryDirectory.appendingPathComponent("rearc-s07-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: udd) }
        let deleted = UUID()
        let name = try XCTUnwrap(ChromiumProfileDeletions.directoryName(for: deleted, map: ChromiumProfileStorageMap()))
        XCTAssertEqual(name, ChromiumProfileStoragePlan.namedDirectoryName(forKey: ChromiumProfileKey.storageKey(for: deleted)))
        try fm.createDirectory(at: udd.appendingPathComponent(name).appendingPathComponent("Network"), withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: udd.appendingPathComponent(name).appendingPathComponent("Network/Cookies"))
        try fm.createDirectory(at: udd.appendingPathComponent("Default"), withIntermediateDirectories: true)
        let outside = fm.temporaryDirectory.appendingPathComponent("rearc-s07-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: udd.appendingPathComponent("ReArcProfile-4C494E4B"), withDestinationURL: outside)

        ChromiumProfileDeletions.schedule(name, in: udd)
        ChromiumProfileDeletions.schedule("Default", in: udd)
        ChromiumProfileDeletions.schedule("../escape", in: udd)
        ChromiumProfileDeletions.schedule("ReArcProfile-4C494E4B", in: udd)
        XCTAssertEqual(ChromiumProfileDeletions.pending(in: udd), [name, "ReArcProfile-4C494E4B"])

        XCTAssertEqual(ChromiumProfileDeletions.run(in: udd), [name])
        XCTAssertFalse(fm.fileExists(atPath: udd.appendingPathComponent(name).path))
        XCTAssertTrue(fm.fileExists(atPath: udd.appendingPathComponent("Default").path))
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "a symlink is never followed")
        XCTAssertEqual(ChromiumProfileDeletions.pending(in: udd), [])

        var adopted = ChromiumProfileStorageMap()
        adopted.recordDirectory("Default", for: deleted)
        XCTAssertNil(ChromiumProfileDeletions.directoryName(for: deleted, map: adopted), "the startup directory stays")
    }

    /// RC-0.1.0-602 S-07: a deleted container recreated before a restart keeps its folder.
    func testAProfileOpenedAgainIsNoLongerScheduled() throws {
        let fm = FileManager.default
        let udd = fm.temporaryDirectory.appendingPathComponent("rearc-s07b-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: udd, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: udd) }
        let back = UUID(), gone = UUID()
        let backName = try XCTUnwrap(ChromiumProfileDeletions.directoryName(for: back, map: ChromiumProfileStorageMap()))
        let goneName = try XCTUnwrap(ChromiumProfileDeletions.directoryName(for: gone, map: ChromiumProfileStorageMap()))
        for name in [backName, goneName] {
            try fm.createDirectory(at: udd.appendingPathComponent(name), withIntermediateDirectories: true)
            ChromiumProfileDeletions.schedule(name, in: udd)
        }
        ChromiumProfileDeletions.unschedule(backName, in: udd)
        XCTAssertEqual(ChromiumProfileDeletions.run(in: udd), [goneName])
        XCTAssertTrue(fm.fileExists(atPath: udd.appendingPathComponent(backName).path))
    }

    @MainActor
    func testTheDeleteDialogSaysWhenTheDataStays() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-s07-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let model = BrowserViewModel(store: SidebarStore(), persistence: SidebarFilePersistence(fileURL: file), faviconStore: FaviconStore(directory: nil))
        defer { model.persistence.stop() }
        let other = model.store.addProfile(name: "Work")
        model.pendingDeletion = .profile(other.id)
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("browsing data are deleted"))
        model.profileKeepsDataOnDelete = { $0 == other.id }
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("browsing data stays"))
        model.pendingDeletion = nil
    }
}
