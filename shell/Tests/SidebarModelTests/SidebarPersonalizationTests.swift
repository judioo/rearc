import XCTest
@testable import SidebarModel

final class SidebarPersonalizationTests: XCTestCase {
    private let emoji: SidebarItemIcon = .emoji("🦊")
    private let symbol: SidebarItemIcon = .sfSymbol(name: "star.fill")
    private let url = URL(string: "https://example.test")!

    func testIconsPersistAcrossAllContainersAndReset() throws {
        let store = SidebarStore()
        let favorite = store.addTab(kind: .favorite, title: "Favorite", url: url)
        let tab = store.addTab(kind: .pinned, title: "Nested", url: url)
        let folder = try XCTUnwrap(store.createFolder(containing: [tab.id]))
        let a = store.addTab(kind: .today, title: "A", url: url)
        let b = store.addTab(kind: .today, title: "B", url: url)
        let split = try XCTUnwrap(store.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        let easel = store.addEaselSidebarItem(documentID: UUID())
        for id in [favorite.id, tab.id, folder.id, a.id, split.id, easel.id] {
            XCTAssertTrue(store.setCustomIcon(emoji, for: id))
        }
        XCTAssertFalse(store.setCustomIcon(symbol, for: UUID()))
        store.updateTab(tab.id, title: "New title", url: URL(string: "https://new.test")!)
        let restored = SidebarStore()
        restored.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(store.makeSnapshot())))
        for id in [favorite.id, tab.id, folder.id, a.id, split.id, easel.id] {
            XCTAssertEqual(restored.customIcon(for: id), emoji)
            XCTAssertTrue(restored.setCustomIcon(nil, for: id))
            XCTAssertNil(restored.customIcon(for: id))
        }
        XCTAssertEqual(restored.tab(withID: tab.id)?.faviconToken, "N")
        XCTAssertEqual(store.duplicateTab(tab.id)?.customIcon, emoji)
        XCTAssertEqual(store.duplicateTab(favorite.id)?.customIcon, emoji)
    }

    func testLegacyItemsDecodeWithoutOverride() throws {
        let tab = Tab(kind: .pinned, title: "Old", url: url)
        let split = SplitViewItem(orientation: .horizontal, tabs: [tab, Tab(kind: .pinned, title: "Two", url: url)])
        let entries: [SidebarEntry] = [.tab(tab), .folder(SidebarFolder(title: "Folder")), .split(split), .easel(SidebarEaselRef(easelDocumentID: UUID()))]
        for entry in entries {
            let data = try JSONEncoder().encode(entry)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("customIcon"))
            XCTAssertNil(try JSONDecoder().decode(SidebarEntry.self, from: data).customIcon)
        }
    }

    func testSyncCarriesProfileIdentityAndPinnedFavoriteFolderAndSplitIcons() throws {
        let source = SidebarStore()
        let profile = source.activeProfile
        let draft = ProfileDraft(name: "Work", avatar: .init(kind: .emoji("💼")), themeColor: SpaceTheme.presets[4])
        XCTAssertNil(source.updateProfile(profile.id, from: draft))
        let favorite = source.addTab(kind: .favorite, title: "Favorite", url: url)
        let nested = source.addTab(kind: .pinned, title: "Nested", url: url)
        let folder = try XCTUnwrap(source.createFolder(containing: [nested.id]))
        let a = source.addTab(kind: .pinned, title: "A", url: url)
        let b = source.addTab(kind: .pinned, title: "B", url: url)
        let split = try XCTUnwrap(source.createSplit(tabIDs: [a.id, b.id], orientation: .horizontal))
        let ids = [favorite.id, nested.id, folder.id, split.id, a.id]
        for id in ids { XCTAssertTrue(source.setCustomIcon(symbol, for: id)) }
        let stamp = SyncStamp(millis: 1, device: "test")
        func records() -> [String: SyncRecordPayload] {
            SidebarSyncProjection.extract(source.makeSnapshot()).mapValues { body in
                SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
            }
        }
        let remote = SidebarStore()
        remote.applySnapshot(SidebarSyncProjection.apply(records(), onto: remote.makeSnapshot()))
        XCTAssertEqual(remote.profile(withID: profile.id).map(ProfileDraft.init(profile:)), draft)
        for id in ids { XCTAssertEqual(remote.customIcon(for: id), symbol) }
        for id in ids { XCTAssertTrue(source.setCustomIcon(nil, for: id)) }
        remote.applySnapshot(SidebarSyncProjection.apply(records(), onto: remote.makeSnapshot()))
        for id in ids { XCTAssertNil(remote.customIcon(for: id)) }
    }
}
