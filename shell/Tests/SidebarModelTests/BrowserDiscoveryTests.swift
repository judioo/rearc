import XCTest
@testable import SidebarModel

/// Which browsers discovery finds and in what state (PROFILE-IMPORT §2.2,
/// §6), Safari's and Firefox's readers, and the watch that re-scans when
/// ReArc comes back from System Settings. Every input is invented.
final class BrowserDiscoveryTests: XCTestCase {
    private var fixture: BrowserImportFixture!

    override func setUpWithError() throws {
        fixture = try BrowserImportFixture()
    }

    override func tearDown() {
        fixture.remove()
    }

    /// The real probe, except that `denied` paths (and what is under them)
    /// fail as a protected folder does.
    private func probe(denying denied: [URL]) -> ImportAccessProbe {
        let paths = denied.map(\.standardizedFileURL.path)
        return { url in
            let path = url.standardizedFileURL.path
            if paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return FileManager.default.fileExists(atPath: path) ? .denied : .missing
            }
            return ImportAccessProbes.system(url)
        }
    }

    private func discover(installed: Set<ImportBrowser> = [], denying denied: [URL] = []) -> [DiscoveredBrowser] {
        BrowserImportDiscovery.discover(in: fixture.root, installed: { installed.contains($0) }, probe: probe(denying: denied))
    }

    // MARK: Detection states

    func testDiscoveryTellsTheFourStatesApart() throws {
        try fixture.installBrowsers()
        try fixture.write(BrowserImportFixture.localState([("Default", "Me")]), to: "BraveSoftware/Brave-Browser/Local State")
        try fixture.write([:] as [String: Any], to: "BraveSoftware/Brave-Browser/Default/Preferences")
        let brave = fixture.root.appendingPathComponent("BraveSoftware/Brave-Browser")
        let found = discover(installed: [.chrome, .brave, .edge], denying: [brave])
        let status = Dictionary(uniqueKeysWithValues: found.map { ($0.browser, $0.status) })
        XCTAssertEqual(status[.chrome], .available, "readable")
        XCTAssertEqual(status[.brave], .blocked(.appData), "macOS privacy")
        XCTAssertEqual(status[.edge], .noProfiles, "installed, nothing to read")
        XCTAssertNil(status[.vivaldi], "not installed")
        XCTAssertEqual(found.map(\.browser), [.arc, .chrome, .brave, .edge], "ImportBrowser order")
        XCTAssertTrue(try XCTUnwrap(found.first { $0.browser == .brave }).profiles.isEmpty, "nothing is read past the denial")
    }

    func testABlockedLocalStateBlocksAReadableFolder() throws {
        try fixture.installBrowsers()
        let localState = fixture.root.appendingPathComponent("Google/Chrome/Local State")
        let chrome = try XCTUnwrap(discover(denying: [localState]).first { $0.browser == .chrome })
        XCTAssertEqual(chrome.status, .blocked(.appData))
    }

    func testTheSystemProbeReportsAnUnopenableFolderAsDenied() throws {
        try fixture.write(BrowserImportFixture.localState([("Default", "Me")]), to: "Vivaldi/Local State")
        let vivaldi = fixture.root.appendingPathComponent("Vivaldi")
        XCTAssertEqual(ImportAccessProbes.system(vivaldi), .readable)
        XCTAssertEqual(ImportAccessProbes.system(vivaldi.appendingPathComponent("Local State")), .readable)
        XCTAssertEqual(ImportAccessProbes.system(vivaldi.appendingPathComponent("Nope")), .missing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: vivaldi.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vivaldi.path) }
        XCTAssertEqual(ImportAccessProbes.system(vivaldi), .denied, "stat works, opendir fails")
        let found = BrowserImportDiscovery.discover(.vivaldi, in: fixture.root)
        XCTAssertEqual(found?.status, .blocked(.appData))
    }

    func testAnInstalledBrowserThatNeverMadeAProfileHasNoProfiles() throws {
        _ = try fixture.folder("Chromium/Crashpad")
        XCTAssertEqual(discover(installed: [.chromium]).first { $0.browser == .chromium }?.status, .noProfiles)
        XCTAssertNil(discover().first { $0.browser == .chromium }, "a leftover folder of an app that is gone")
    }

    func testChromeChannelsEdgeVivaldiAndOperaUseTheChromiumReaders() throws {
        for (path, name) in [("Google/Chrome Canary", "Night"), ("Microsoft Edge", "Work"), ("Vivaldi", "Home")] {
            try fixture.write(BrowserImportFixture.localState([("Default", name)]), to: "\(path)/Local State")
            try fixture.write([:] as [String: Any], to: "\(path)/Default/Preferences")
            try fixture.write(BrowserImportFixture.bookmarks, to: "\(path)/Default/Bookmarks")
        }
        // Opera's main profile is its user data folder.
        try fixture.write([:] as [String: Any], to: "com.operasoftware.Opera/Preferences")
        try fixture.write(BrowserImportFixture.bookmarks, to: "com.operasoftware.Opera/Bookmarks")
        let found = discover()
        XCTAssertEqual(found.map(\.browser), [.chromeCanary, .edge, .vivaldi, .opera])
        for browser in found {
            let profile = try XCTUnwrap(browser.profiles.first)
            XCTAssertEqual(BrowserImportDiscovery.inventory(of: profile).bookmarks, 3, browser.browser.name)
        }
        let opera = try XCTUnwrap(found.last?.profiles.first)
        XCTAssertEqual(opera.directory, "Default")
        XCTAssertEqual(opera.url.standardizedFileURL, fixture.root.appendingPathComponent("com.operasoftware.Opera").standardizedFileURL)
        XCTAssertEqual(ImportBrowser.edge.safeStorageService, "Microsoft Edge Safe Storage")
        XCTAssertEqual(ImportBrowser.chromeCanary.shortName, "Chrome Canary")
    }

    func testSafariNeedsFullDiskAccess() throws {
        try fixture.installSafari()
        let bookmarks = fixture.safari.appendingPathComponent("Bookmarks.plist")
        let blocked = try XCTUnwrap(discover(denying: [bookmarks]).first { $0.browser == .safari })
        XCTAssertEqual(blocked.status, .blocked(.fullDiskAccess))
        XCTAssertEqual(discover(denying: [fixture.safari]).first { $0.browser == .safari }?.status, .blocked(.fullDiskAccess))
        let safari = try XCTUnwrap(discover().first { $0.browser == .safari })
        XCTAssertEqual(safari.status, .available)
        XCTAssertEqual(safari.profiles.map(\.name), ["Safari"])
        XCTAssertEqual(ImportPermission.fullDiskAccess.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        XCTAssertEqual(ImportPermission.appData.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    // MARK: Safari

    func testSafariBookmarksKeepTheBarThenMenuAndReadingList() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: BrowserImportFixture.safariBookmarks, format: .binary, options: 0)
        let nodes = try SafariBookmarksReader.parse(data)
        XCTAssertEqual(nodes, [
            .link(title: "Bar Link", url: URL(string: "https://bar.example.com/")!),
            .folder(title: "Recipes", children: [.link(title: "Soup", url: URL(string: "https://soup.example.org/")!)]),
            .folder(title: "Bookmarks Menu", children: [.link(title: "menu.example.net", url: URL(string: "https://menu.example.net/")!)]),
            .folder(title: "Reading List", children: [.link(title: "An Essay", url: URL(string: "https://long.example.com/essay")!)]),
        ], "javascript: and user:password@ links stay behind")
        XCTAssertThrowsError(try SafariBookmarksReader.parse(Data("[]".utf8)))
    }

    func testSafariHistoryReadsPagesNewestFirstFromACopy() throws {
        let now = Date()
        try fixture.installSafari(now: now)
        let url = fixture.safari.appendingPathComponent("History.db")
        let before = try Data(contentsOf: url)
        let records = try SafariHistoryReader.read(url)
        XCTAssertEqual(records.map(\.url.absoluteString), ["https://news.example.com/", "https://maps.example.org/route"])
        XCTAssertEqual(records.map(\.title), ["Front Page", "Route"], "the last visit's title")
        XCTAssertEqual(records[0].visitCount, 2)
        XCTAssertEqual(records[0].firstVisit.timeIntervalSince(now), -7200, accuracy: 0.01)
        XCTAssertEqual(records[0].lastVisit.timeIntervalSince(now), -60, accuracy: 0.01)
        XCTAssertEqual(SafariHistoryReader.pageCount(url), 3)
        XCTAssertEqual(SafariHistoryReader.pageCount(url, after: now.addingTimeInterval(-120)), 2)
        XCTAssertEqual(try Data(contentsOf: url), before, "the source is never written")
        let profile = try XCTUnwrap(discover().first { $0.browser == .safari }?.profiles.first)
        let inventory = BrowserImportDiscovery.inventory(of: profile)
        XCTAssertEqual(inventory.bookmarks, 4)
        XCTAssertEqual(inventory.historyPages, 3)
        XCTAssertEqual(inventory.extensions, 0)
    }

    // MARK: Firefox

    func testFirefoxProfilesPutTheInstallDefaultFirst() throws {
        let entries = FirefoxProfiles.parse(BrowserImportFixture.profilesINI)
        XCTAssertEqual(entries.map(\.name), ["default-release", "old", "gone"])
        try fixture.installFirefox()
        let firefox = try XCTUnwrap(discover().first { $0.browser == .firefox })
        XCTAssertEqual(firefox.status, .available)
        XCTAssertEqual(firefox.profiles.map(\.directory), ["Profiles/aaaa.default-release", "Profiles/bbbb.old"],
                       "a profile whose folder is gone is skipped")
        XCTAssertEqual(firefox.profiles.first?.id, "firefox/Profiles/aaaa.default-release")
    }

    func testFirefoxBookmarksAndHistoryComeFromPlaces() throws {
        let now = Date()
        try fixture.installFirefox(now: now)
        let profile = try XCTUnwrap(discover().first { $0.browser == .firefox }?.profiles.first)
        XCTAssertEqual(try profile.readBookmarks(), [
            .link(title: "Fox", url: URL(string: "https://fox.example.com/")!),
            .folder(title: "Work", children: [.link(title: "The Guide", url: URL(string: "https://docs.example.org/guide")!)]),
            .folder(title: "Bookmarks Menu", children: [.link(title: "Menu Link", url: URL(string: "https://menu.example.net/")!)]),
            .folder(title: "Other Bookmarks", children: [.link(title: "Unsorted Fox", url: URL(string: "https://fox.example.com/")!)]),
        ], "place: queries, separators and tags stay behind")
        let history = try profile.readHistory()
        XCTAssertEqual(history.map(\.url.absoluteString), ["https://fox.example.com/", "https://docs.example.org/guide"])
        XCTAssertEqual(history[0].visitCount, 5)
        XCTAssertEqual(history[0].firstVisit.timeIntervalSince(now), -86400, accuracy: 0.01)
        XCTAssertEqual(history[1].firstVisit, history[1].lastVisit, "no visit rows: one date")
        XCTAssertEqual(profile.historyPageCount(), 2)
        XCTAssertEqual(profile.historyPageCount(after: now.addingTimeInterval(-120)), 1)
        // Present or not, Firefox's secrets are only noted.
        try Data("{}".utf8).write(to: profile.url.appendingPathComponent("logins.json"))
        XCTAssertTrue(BrowserImportDiscovery.inventory(of: profile).hasPasswords)
    }

    // MARK: Re-scan on focus

    private func found(_ blocked: [ImportBrowser: ImportPermission], readable: [ImportBrowser] = []) -> [DiscoveredBrowser] {
        ImportBrowser.allCases.compactMap { browser in
            if let permission = blocked[browser] { return DiscoveredBrowser(browser: browser, status: .blocked(permission)) }
            return readable.contains(browser) ? DiscoveredBrowser(browser: browser, status: .available) : nil
        }
    }

    func testTheWatchOpensABrowserOnTheRescanAfterSettings() {
        var watch = ImportAccessWatch(found([.chrome: .appData, .brave: .appData, .safari: .fullDiskAccess], readable: [.arc]))
        XCTAssertEqual(watch.blocked, [.chrome, .brave, .safari])
        XCTAssertEqual(watch.neededPermissions, [.appData, .fullDiskAccess])
        XCTAssertFalse(watch.offersRelaunch)

        watch.openedSettings(.appData)
        XCTAssertEqual(watch.awaitingReturn, [.appData])
        XCTAssertTrue(watch.becameActive(), "something is blocked: look again")
        XCTAssertTrue(watch.awaitingReturn.isEmpty)
        // Chrome was allowed; Brave not yet; Safari's pane was never opened.
        let opened = watch.update(found([.brave: .appData, .safari: .fullDiskAccess], readable: [.arc, .chrome]))
        XCTAssertEqual(opened, [.chrome])
        XCTAssertEqual(watch.blocked, [.brave, .safari])
        XCTAssertTrue(watch.offersRelaunch(for: .brave), "back from Settings and still blocked")
        XCTAssertFalse(watch.offersRelaunch(for: .safari), "its pane was never opened")

        // A plain switch back to ReArc changes nothing it knew.
        XCTAssertTrue(watch.becameActive())
        XCTAssertEqual(watch.update(found([.brave: .appData, .safari: .fullDiskAccess], readable: [.arc, .chrome])), [])
        XCTAssertTrue(watch.offersRelaunch(for: .brave), "the offer stays until Brave opens")

        watch.openedSettings(.fullDiskAccess)
        XCTAssertTrue(watch.becameActive())
        XCTAssertEqual(watch.update(found([:], readable: [.arc, .chrome, .brave, .safari])), [.brave, .safari])
        XCTAssertTrue(watch.isEmpty)
        XCTAssertFalse(watch.offersRelaunch)
        XCTAssertFalse(watch.becameActive(), "nothing blocked: no rescans")
    }

    func testAnUpdateBeforeTheReturnDoesNotOfferARelaunch() {
        var watch = ImportAccessWatch(found([.firefox: .appData]))
        watch.openedSettings(.appData)
        watch.update(found([.firefox: .appData]))
        XCTAssertFalse(watch.offersRelaunch, "still in System Settings")
        _ = watch.becameActive()
        watch.update(found([.firefox: .appData]))
        XCTAssertTrue(watch.offersRelaunch)
    }
}
