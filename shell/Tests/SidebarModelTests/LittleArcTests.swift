import XCTest
@testable import SidebarModel

final class LittleArcTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testCreatePersistAndArchiveManual() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let created = store.createLittleArcWindow(url: url("https://example.com"), title: "Example")
        XCTAssertEqual(store.littleArcLiveWindows.count, 1)
        XCTAssertEqual(store.littleArcLiveWindows[0].id, created.id)

        let snapshot = store.makeSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertEqual(snapshot.littleArcWindows.count, 1)

        let loaded = SidebarStore()
        loaded.applySnapshot(snapshot)
        XCTAssertEqual(loaded.littleArcLiveWindows.map(\.title), ["Example"])

        XCTAssertNotNil(store.archiveLittleArcWindow(id: created.id, reason: .manual))
        XCTAssertTrue(store.littleArcLiveWindows.isEmpty)
        XCTAssertEqual(store.littleArcArchivedWindows.count, 1)
        XCTAssertEqual(store.littleArcArchivedWindows[0].reason, .manual)
    }

    func testAutoArchiveThresholdLogic() {
        let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let idle = reference.addingTimeInterval(-(LittleArcPolicy.autoArchiveIdleThreshold + 60))
        let recent = reference.addingTimeInterval(-3600)
        let profile = Profile.personalDefault()
        let stale = LittleArcWindow(
            url: url("https://stale.test"),
            title: "Stale",
            profileID: profile.id,
            createdAt: idle,
            lastActiveAt: idle
        )
        let fresh = LittleArcWindow(
            url: url("https://fresh.test"),
            title: "Fresh",
            profileID: profile.id,
            createdAt: recent,
            lastActiveAt: recent
        )

        let eligible = LittleArcPolicy.windowsEligibleForAutoArchive(
            live: [stale, fresh],
            referenceDate: reference
        )
        XCTAssertEqual(eligible, [stale.id])

        let store = SidebarStore(spaces: [Space(name: "One")])
        store.littleArcWindows = [stale, fresh]
        let archived = store.autoArchiveIdleLittleArcWindows(referenceDate: reference)
        XCTAssertEqual(archived, [stale.id])
        XCTAssertEqual(store.littleArcLiveWindows.map(\.id), [fresh.id])
        XCTAssertEqual(store.littleArcArchivedWindows.first?.reason, .auto)
    }

    func testPromoteFromLiveAndArchive() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let live = store.createLittleArcWindow(url: url("https://live.test"), title: "Live")
        let tab = store.promoteLittleArcToTab(id: live.id)
        XCTAssertNotNil(tab)
        XCTAssertEqual(tab?.url.absoluteString, "https://live.test")
        XCTAssertTrue(store.littleArcLiveWindows.isEmpty)
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.count, 1)

        let archivedWindow = store.createLittleArcWindow(url: url("https://archived.test"), title: "Archived")
        _ = store.archiveLittleArcWindow(id: archivedWindow.id, reason: .manual)
        let tab2 = store.promoteLittleArcToTab(id: archivedWindow.id)
        XCTAssertNotNil(tab2)
        XCTAssertTrue(store.littleArcArchivedWindows.isEmpty)
        XCTAssertEqual(store.content(for: store.activeSpaceID).today.count, 2)
    }

    /// Arc's "Open in <Space>": the last focused browser window's space by
    /// default, or a space picked from the menu.
    func testOpenInTargetsTheKeyWindowsSpaceOrAPickedOne() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let window = SidebarWindowID()
        store.selectSpace(two.id)
        store.windowBecameKey(window)
        let little = store.createLittleArcWindow(url: url("https://target.test"), title: "T")
        XCTAssertEqual(store.littleArcTargetSpace(for: little.id)?.id, two.id)
        let first = store.promoteLittleArcToTab(id: little.id)
        XCTAssertEqual(store.content(for: two.id).today.map(\.id), [first?.id])

        let one = store.spaces.first { $0.name == "One" }!
        let picked = store.createLittleArcWindow(url: url("https://picked.test"), title: "P")
        let second = store.promoteLittleArcToTab(id: picked.id, into: one.id)
        XCTAssertEqual(store.activeSpaceID, one.id)
        XCTAssertEqual(store.content(for: one.id).today.map(\.id), [second?.id])
    }

    func testCreateLittleArcRecordsActiveProfile() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let work = store.addProfile(name: "Work")
        store.selectProfile(work.id)
        let window = store.createLittleArcWindow(url: url("https://profile.test"), title: "P")
        XCTAssertEqual(window.profileID, work.id)
    }

    func testPeekStyleURLBecomesTodayTab() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let peekURL = url("https://peek.example/page")
        let tab = store.addTab(kind: .today, title: peekURL.host() ?? "Peek", url: peekURL)
        store.selectTab(tab.id)
        XCTAssertEqual(store.selectedTab?.url, peekURL)
        XCTAssertEqual(store.kind(of: tab.id), .today)
    }

    func testSnapshotV4MigratesToV5LittleArcFields() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(store.makeSnapshot())
        ) as! [String: Any]
        object["schemaVersion"] = 4
        object.removeValue(forKey: "littleArcWindows")
        object.removeValue(forKey: "archivedLittleArcWindows")
        let snapshot = try JSONDecoder().decode(
            SidebarSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(snapshot.schemaVersion, 10)
        XCTAssertTrue(snapshot.littleArcWindows.isEmpty)
        XCTAssertTrue(snapshot.archivedLittleArcWindows.isEmpty)
    }
}
