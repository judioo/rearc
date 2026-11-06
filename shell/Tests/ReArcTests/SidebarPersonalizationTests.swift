import XCTest
@testable import ReArc
@testable import SidebarModel

final class SidebarPersonalizationTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-identity-\(UUID().uuidString)")
        return BrowserViewModel(store: SidebarStore(),
                                persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
    }

    func testProfileCommandDefersCreationUntilValidSave() throws {
        let model = makeModel()
        let count = model.store.profiles.count
        XCTAssertNil(model.executeCommand(.createProfile, commandID: nil))
        XCTAssertNotNil(model.profileEditorRequest)
        XCTAssertEqual(model.store.profiles.count, count)
        XCTAssertNil(model.saveProfile(ProfileDraft(), id: nil, selecting: true))
        XCTAssertNotNil(model.profileEditorRequest)
        let draft = ProfileDraft(name: "Work", avatar: .init(kind: .emoji("💼")), themeColor: SpaceTheme.presets[2])
        let created = try XCTUnwrap(model.saveProfile(draft, id: nil, selecting: true))
        XCTAssertEqual(model.store.activeProfileID, created.id)
        XCTAssertEqual(ProfileDraft(profile: created), draft)
        XCTAssertNil(model.profileEditorRequest)
    }

    func testCancellingProfileCreationLeavesStoreUnchanged() {
        let model = makeModel()
        let before = model.store.makeSnapshot()
        model.beginProfileCreation()
        model.profileEditorRequest = nil
        XCTAssertEqual(model.store.makeSnapshot(), before)
    }

    func testEditingAnotherProfilesIdentityDoesNotSwitch() throws {
        let model = makeModel()
        let active = model.store.activeProfileID
        let other = model.store.addProfile(name: "Other")
        model.beginProfileEditing(other)
        var draft = try XCTUnwrap(model.profileEditorRequest?.draft)
        draft.avatar = .init(kind: .sfSymbol(name: "leaf.fill"))
        draft.themeColor = SpaceTheme.presets[3]
        XCTAssertNotNil(model.saveProfile(draft, id: other.id, selecting: false))
        XCTAssertEqual(model.store.activeProfileID, active)
        XCTAssertEqual(model.store.profile(withID: other.id).map(ProfileDraft.init(profile:)), draft)
    }

    func testIdleRowsObserveCustomIconsAndResetWithoutHosting() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "Tab", url: URL(string: "https://example.test")!)
        let folder = try XCTUnwrap(model.store.createFolder(containing: [tab.id]))
        let space = model.store.activeSpaceID
        let chrome = ThemeChromeColors(theme: .default, dark: false)
        for id in [tab.id, folder.id] {
            let before = PlainRowState.read(id: id, model: model, spaceID: space, chrome: chrome)
            let icon: SidebarItemIcon = .emoji("🦊")
            XCTAssertTrue(model.store.setCustomIcon(icon, for: id))
            let changed = PlainRowState.read(id: id, model: model, spaceID: space, chrome: chrome)
            XCTAssertEqual(changed.customIcon, icon)
            XCTAssertNotEqual(changed, before)
            XCTAssertFalse(changed.needsHosting, "idle custom icons stay on the plain AppKit path")
            XCTAssertTrue(model.store.setCustomIcon(nil, for: id))
            XCTAssertEqual(PlainRowState.read(id: id, model: model, spaceID: space, chrome: chrome), before)
        }
    }
}
