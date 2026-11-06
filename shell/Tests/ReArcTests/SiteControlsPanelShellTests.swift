import XCTest
@testable import ReArc
@testable import SidebarModel

/// Arc's site controls panel (arc-recordings/2026-11-06-site-controls-panel.md)
/// on WebKit: its Settings rows change the shell's store, the ⋯ menu acts on the page.
@MainActor
final class SiteControlsPanelShellTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-site-controls-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-site-controls-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-site-controls-links-\(UUID().uuidString)")!
        return model
    }

    func testSettingRowsChangePermissionsAndAutoPictureInPicture() throws {
        let model = makeModel()
        let url = URL(string: "https://www.video.test/watch")!
        let tab = model.store.addTab(kind: .today, title: "Video", url: url)
        model.store.selectTab(tab.id)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))
        XCTAssertFalse(model.sitePermissionsLiveInEngine, "WebKit: the shell's store is the answer")
        model.automaticPictureInPicture = true

        var rows = model.siteControlSettingRows(for: engine, site: site)
        XCTAssertEqual(rows.map(\.kind), [.autoPictureInPicture])
        model.performSiteSetting(.block, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.store.autoPiPPolicy.perHost["www.video.test"], .disabled, "keyed like the auto-PiP check")
        rows = model.siteControlSettingRows(for: engine, site: site)
        XCTAssertEqual(rows[0].state, "Blocked")
        model.performSiteSetting(.allow, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.siteControlSettingRows(for: engine, site: site)[0].state, "Allowed")

        let scope = engine.pagePrompts.permissionScope
        let request = PermissionPromptRequest(id: 1, origin: site.origin, types: [.geolocation])
        model.sitePermissions.record(.deny, remembered: true, request: request, scope: scope)
        rows = model.siteControlSettingRows(for: engine, site: site)
        XCTAssertEqual(rows.map(\.title), ["Location", "Automatic Picture-In-Picture"])
        XCTAssertEqual(rows[0].state, "Blocked")
        XCTAssertEqual(rows[0].actions, [.allow, .reset])
        model.performSiteSetting(.allow, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.sitePermissions.rememberedDecision(for: request, scope: scope), .allow)
        model.performSiteSetting(.reset, on: rows[0], engine: engine, site: site)
        XCTAssertEqual(model.siteControlSettingRows(for: engine, site: site).count, 1)
    }

    func testMoreMenuZoomsAndTogglesTheSitesBoosts() throws {
        let model = makeModel()
        let url = URL(string: "https://docs.test/page")!
        let tab = model.store.addTab(kind: .today, title: "Docs", url: url)
        model.store.selectTab(tab.id)
        let engine = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let site = try XCTUnwrap(SiteControlCenter.site(for: url))

        var menu = model.siteControlsMenu(for: engine, site: site)
        XCTAssertEqual(menu, [[.zoomLevel(percent: 100), .zoomIn, .zoomOut, .actualSize(enabled: false)], [.clearSiteData]])
        model.performSiteControlsMenuItem(.zoomIn, engine: engine, site: site)
        XCTAssertFalse(PageZoom.isDefault(engine.zoomFactor))
        model.performSiteControlsMenuItem(.actualSize(enabled: true), engine: engine, site: site)
        XCTAssertTrue(PageZoom.isDefault(engine.zoomFactor))

        model.newBoost()
        let boost = try XCTUnwrap(model.siteControlBoostRows(for: url).first)
        menu = model.siteControlsMenu(for: engine, site: site)
        XCTAssertEqual(menu[1], [.boost(id: boost.id, name: boost.name, enabled: boost.isEnabled), .editBoosts])
        model.performSiteControlsMenuItem(menu[1][0], engine: engine, site: site)
        XCTAssertEqual(model.siteControlBoostRows(for: url).first?.isEnabled, !boost.isEnabled)

        let footer = model.siteControlsFooter(for: engine)
        XCTAssertNil(footer.action, "no certificate before a load, and WebKit has no Site Settings page")
    }
}
