import Foundation
import XCTest
@testable import SidebarModel

/// Arc's site controls popover: rows, tiles and state text.
final class SiteControlsPanelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testQuickActionsInArcOrder() {
        let items = SiteControlCenter.quickActions(boostsEligible: true)
        XCTAssertEqual(items.map(\.action), [.share, .boost, .capture, .captureFullPage])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
        let ineligible = SiteControlCenter.quickActions(boostsEligible: false)
        XCTAssertEqual(ineligible.filter { !$0.isEnabled }.map(\.action), [.boost])
        XCTAssertEqual(Set(SiteControlCenter.QuickAction.allCases.map(\.symbol)).count, 4)
    }

    func testExtensionTilesPutPinsFirstInPinOrderThenAdd() {
        let actions = ["a", "b", "c", "d"].map { ExtensionActionItem(id: $0, name: $0.uppercased()) }
        var pins = ExtensionPins()
        pins.pin("c")
        pins.pin("a")
        pins.pin("gone") // an extension this tab doesn't list
        let tiles = SiteControlCenter.extensionTiles(actions, pins: pins)
        XCTAssertEqual(tiles.map(\.id), ["c", "a", "b", "d", "+"])
        XCTAssertEqual(tiles.first, .action(actions[2], pinned: true))
        XCTAssertEqual(tiles[2], .action(actions[1], pinned: false))
        XCTAssertEqual(SiteControlCenter.extensionTiles([], pins: pins), [.add])
        XCTAssertEqual(SiteControlCenter.extensionColumns, 4)
    }

    func testTilesKeepTheirPlaceWhilePinnedOrUnpinnedInTheOpenPanel() {
        let actions = ["a", "b", "c", "d"].map { ExtensionActionItem(id: $0, name: $0.uppercased()) }
        var pins = ExtensionPins(pinnedIDs: ["c"])
        let opened = pins
        // The pin button on D, then on C: both stay where the pointer is.
        pins.toggle("d")
        pins.toggle("c")
        let open = SiteControlCenter.extensionTiles(actions, pins: pins, order: opened)
        XCTAssertEqual(open.map(\.id), ["c", "a", "b", "d", "+"])
        XCTAssertEqual(open[0], .action(actions[2], pinned: false))
        XCTAssertEqual(open[3], .action(actions[3], pinned: true))
        // The next opening sorts them: the toolbar's first.
        let reopened = SiteControlCenter.extensionTiles(actions, pins: pins)
        XCTAssertEqual(reopened.map(\.id), ["d", "a", "b", "c", "+"])
        XCTAssertEqual(reopened[0], .action(actions[3], pinned: true))
        XCTAssertEqual(reopened[3], .action(actions[2], pinned: false))
    }

    func testPinButtonIsSolidWhenPinnedAndOfferedUnderThePointer() {
        let item = ExtensionActionItem(id: "a", name: "Ad Blocker")
        let pinned = SiteControlCenter.ExtensionTile.action(item, pinned: true)
        let unpinned = SiteControlCenter.ExtensionTile.action(item, pinned: false)
        XCTAssertEqual(pinned.pinBadge(hovered: false), .pinned)
        XCTAssertEqual(pinned.pinBadge(hovered: true), .pinned)
        XCTAssertNil(unpinned.pinBadge(hovered: false), "no button until the pointer is on the tile")
        XCTAssertEqual(unpinned.pinBadge(hovered: true), .offered)
        XCTAssertNil(SiteControlCenter.ExtensionTile.add.pinBadge(hovered: true))
        XCTAssertEqual(SiteControlCenter.PinBadge.pinned.title, "Unpin extension")
        XCTAssertEqual(SiteControlCenter.PinBadge.offered.title, "Pin extension")
    }

    func testHoverLabelNamesTheExtensionOrWhatThePinButtonDoes() {
        let item = ExtensionActionItem(id: "a", name: "Ad Blocker", title: "Ad Blocker: 3 blocked")
        let pinned = SiteControlCenter.ExtensionTile.action(item, pinned: true)
        let unpinned = SiteControlCenter.ExtensionTile.action(item, pinned: false)
        XCTAssertEqual(pinned.hoverLabel(onPin: false), "Ad Blocker")
        XCTAssertEqual(unpinned.hoverLabel(onPin: false), "Ad Blocker")
        XCTAssertEqual(pinned.hoverLabel(onPin: true), "Unpin extension")
        XCTAssertEqual(unpinned.hoverLabel(onPin: true), "Pin extension")
        XCTAssertEqual(SiteControlCenter.ExtensionTile.add.hoverLabel(onPin: false), "Chrome Web Store")
        XCTAssertLessThan(SiteControlCenter.hoverLabelDelay, 1, "sooner than a system tooltip")
    }

    func testPreviewPointerFindsATileByNameOrID() {
        let actions = [ExtensionActionItem(id: "aaaa", name: "Ad Blocker"), ExtensionActionItem(id: "bbbb", name: "Notes: Quick")]
        let tiles = SiteControlCenter.extensionTiles(actions, pins: ExtensionPins(pinnedIDs: ["aaaa"]))
        XCTAssertEqual(SiteControlCenter.previewHover("ad blocker", in: tiles), .init(id: "aaaa"))
        XCTAssertEqual(SiteControlCenter.previewHover("bbbb:pin", in: tiles), .init(id: "bbbb", onPin: true))
        XCTAssertEqual(SiteControlCenter.previewHover("Notes: Quick", in: tiles), .init(id: "bbbb"))
        XCTAssertEqual(SiteControlCenter.previewHover("Notes: Quick:pin", in: tiles), .init(id: "bbbb", onPin: true))
        XCTAssertEqual(SiteControlCenter.previewHover("+", in: tiles), .init(id: "+"))
        XCTAssertNil(SiteControlCenter.previewHover("Gone", in: tiles))
    }

    func testPermissionRowsLeadWithLocationAndFollowTheEngine() {
        let blocked = SitePermissionStore.Entry(decision: .deny, remembered: true, date: now)
        let once = SitePermissionStore.Entry(decision: .allow, remembered: false, date: now)
        let permissions: [(type: PermissionType, entry: SitePermissionStore.Entry)] = [
            (.clipboard, once), (.notifications, blocked), (.camera, once), (.geolocation, blocked),
        ]
        let chromium = SiteControlCenter.settingRows(permissions: permissions, permissionsInEngine: true,
                                                     autoPiP: .enabled, autoPiPEnabled: true, now: now)
        XCTAssertEqual(chromium.map(\.title), ["Location", "Camera", "Notifications", "Clipboard", "Automatic Picture-In-Picture"])
        XCTAssertEqual(chromium.map(\.state), ["Blocked", "Allowed this time", "Blocked", "Allowed this time", "Allowed"])
        XCTAssertEqual(chromium[0].kind, .permission("geolocation"))
        XCTAssertTrue(chromium[0].isBlocked)
        XCTAssertFalse(chromium[1].isBlocked)
        XCTAssertEqual(chromium[0].actions, [.openSiteSettings], "Chromium keeps the answer; its Site Settings change it")
        XCTAssertEqual(chromium[0].symbol, PermissionType.geolocation.symbol)

        let webKit = SiteControlCenter.settingRows(permissions: permissions, permissionsInEngine: false,
                                                   autoPiP: .enabled, autoPiPEnabled: true, now: now)
        XCTAssertEqual(webKit[0].actions, [.allow, .reset])
        XCTAssertEqual(webKit[1].actions, [.block, .reset])
    }

    func testAutoPictureInPictureRowStates() {
        func row(_ preference: AutoPiPHostPreference, enabled: Bool = true) -> SiteControlCenter.SettingRow {
            SiteControlCenter.settingRows(permissions: [], permissionsInEngine: true, autoPiP: preference,
                                          autoPiPEnabled: enabled, now: now).last!
        }
        XCTAssertEqual(SiteControlCenter.settingRows(permissions: [], permissionsInEngine: true, autoPiP: .enabled,
                                                     autoPiPEnabled: true, now: now).count, 1)
        XCTAssertEqual(row(.enabled).kind, .autoPictureInPicture)
        XCTAssertEqual(row(.enabled).actions, [.block, .snoozeOneHour])
        XCTAssertEqual(row(.disabled).state, "Blocked")
        XCTAssertEqual(row(.disabled).actions, [.allow])
        let snoozed = row(.snoozedUntil(now.addingTimeInterval(44 * 60 + 10)))
        XCTAssertEqual(snoozed.state, "Snoozed for 45 min")
        XCTAssertEqual(snoozed.actions, [.allow, .block])
        XCTAssertEqual(row(.snoozedUntil(now.addingTimeInterval(5))).state, "Snoozed for 1 min")
        XCTAssertEqual(row(.enabled, enabled: false).state, "Off for all sites")
        XCTAssertTrue(row(.enabled, enabled: false).isBlocked)
        XCTAssertEqual(row(.disabled, enabled: false).actions, [])
    }

    func testAllowingAutoPictureInPictureEndsABlockOrSnooze() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        var mutations = 0
        store.onDidMutate = { mutations += 1 }
        store.snoozeAutoPiP(forHost: "video.test", now: now)
        store.allowAutoPiP(forHost: "video.test")
        XCTAssertEqual(AutoPiPPolicy.effectiveHostPreference(host: "video.test", settings: store.autoPiPPolicy, now: now), .enabled)
        store.allowAutoPiP(forHost: "video.test")
        XCTAssertEqual(mutations, 2, "allowing a site that is already allowed changes nothing")
    }

    func testMoreMenuHoldsZoomBoostsAndSiteData() {
        let chromium = SiteControlCenter.moreMenu(zoomPercent: 100, boosts: [], shellClearsSiteData: false, siteSettingsAvailable: true)
        XCTAssertEqual(chromium, [
            [.zoomLevel(percent: 100), .zoomIn, .zoomOut, .actualSize(enabled: false)],
            [.cookiesAndSiteData, .siteSettings],
        ])
        XCTAssertEqual(chromium.flatMap { $0 }.map(\.title),
                       ["Zoom 100%", "Zoom In", "Zoom Out", "Actual Size", "Cookies and Site Data…", "Site Settings…"])

        let boost = SiteControlCenter.BoostRow(id: UUID(), name: "Dark", isEnabled: true)
        let webKit = SiteControlCenter.moreMenu(zoomPercent: 125, boosts: [boost], shellClearsSiteData: true, siteSettingsAvailable: false)
        XCTAssertEqual(webKit, [
            [.zoomLevel(percent: 125), .zoomIn, .zoomOut, .actualSize(enabled: true)],
            [.boost(id: boost.id, name: "Dark", enabled: true), .editBoosts],
            [.clearSiteData],
        ])
    }

    func testFooterFollowsTheConnection() {
        let secure = SiteControlCenter.footer(.secure, certificateAvailable: false, siteSettingsAvailable: true)
        XCTAssertEqual(secure, .init(title: "Secure", symbol: "lock.fill", isWarning: false, action: .openSiteSettings))
        XCTAssertEqual(SiteControlCenter.footer(.secure, certificateAvailable: true, siteSettingsAvailable: false).action, .showCertificate)
        let insecure = SiteControlCenter.footer(.insecure, certificateAvailable: false, siteSettingsAvailable: false)
        XCTAssertEqual(insecure.title, "Not Secure")
        XCTAssertTrue(insecure.isWarning)
        XCTAssertNil(insecure.action)
        XCTAssertEqual(SiteControlCenter.footer(.dangerous, certificateAvailable: false, siteSettingsAvailable: true).title, "Dangerous")
        XCTAssertEqual(SiteControlCenter.footer(.unknown, certificateAvailable: true, siteSettingsAvailable: false).action, nil,
                       "no certificate to show without a connection")
    }
}
