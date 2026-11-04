import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 17 shell glue: navigation state mapping, favicons, menus, folder rows
/// and the Cmd+W / archive paths through BrowserViewModel.
final class Wave17ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Second", sortRank: "b")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w17-\(UUID().uuidString)")
        return BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
    }

    /// 16x16 PNG (same bytes as the Chromium self-test fixture).
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGMQVDImCTGMahjVMHw1AAAaNGYB4V8qqwAAAABJRU5ErkJggg=="
    )!

    func testSecurityStateMapping() {
        XCTAssertEqual(WebSecurityState(chromiumLevel: 0), .secure)
        XCTAssertEqual(WebSecurityState(chromiumLevel: 1), .insecure)
        XCTAssertEqual(WebSecurityState(chromiumLevel: 2), .dangerous)
        XCTAssertEqual(WebSecurityState(chromiumLevel: 3), .none)
        XCTAssertEqual(WebSecurityState(chromiumLevel: 4), .unknown)
        XCTAssertEqual(WebSecurityState(chromiumLevel: 99), .unknown)
        XCTAssertEqual(WebSecurityState.webKit(url: URL(string: "https://a.test"), hasOnlySecureContent: true), .secure)
        XCTAssertEqual(WebSecurityState.webKit(url: URL(string: "https://a.test"), hasOnlySecureContent: false), .insecure)
        XCTAssertEqual(WebSecurityState.webKit(url: URL(string: "http://a.test"), hasOnlySecureContent: false), .insecure)
        XCTAssertEqual(WebSecurityState.webKit(url: URL(string: "about:blank"), hasOnlySecureContent: false), .none)
        XCTAssertEqual(WebSecurityState.webKit(url: nil, hasOnlySecureContent: false), .unknown)
    }

    func testWebKitFaviconCandidatesPreferDeclaredIconsThenFaviconICO() {
        let page = URL(string: "https://site.test/a/b?q=1")!
        let candidates = [
            FaviconCandidate(url: URL(string: "https://site.test/touch.png")!, rel: "apple-touch-icon", sizes: "180x180"),
            FaviconCandidate(url: URL(string: "https://site.test/big.png")!, rel: "icon", sizes: "192x192"),
            FaviconCandidate(url: URL(string: "https://site.test/32.png")!, rel: "icon", sizes: "32x32"),
            FaviconCandidate(url: URL(string: "data:image/png;base64,AAAA")!, rel: "icon", sizes: ""),
        ]
        XCTAssertEqual(FaviconCandidate.ordered(candidates, pageURL: page).map(\.absoluteString), [
            "https://site.test/32.png",
            "https://site.test/big.png",
            "https://site.test/touch.png",
            "https://site.test/favicon.ico",
        ])
    }

    func testFaviconStoreKeysByHostAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FaviconStore(directory: directory)
        XCTAssertNil(store.image(for: URL(string: "https://www.site.test/x")!))
        XCTAssertTrue(store.store(Self.png, for: URL(string: "https://www.site.test/page")!))
        XCTAssertNotNil(store.image(for: URL(string: "https://site.test/other")!), "www. is ignored")
        XCTAssertFalse(store.store(Data("not an image".utf8), for: URL(string: "https://bad.test")!))
        let file = directory.appendingPathComponent(FaviconStore.fileName(for: "site.test"))
        let expectation = expectation(description: "icon written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(FaviconStore(directory: directory).image(for: URL(string: "https://site.test")!), "reloads from disk")
        XCTAssertEqual(FaviconStore.fileName(for: "a/b:c"), "a_b_c.icon")
    }

    func testShellMenuKeyEquivalents() {
        let model = makeModel()
        let spaces = ShellMenus.spaces(model).flatMap { $0 }
        XCTAssertEqual(spaces.first?.menuKeyEquivalent, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        XCTAssertEqual(spaces.first?.eventModifiers, [.command, .option])
        let ctrl3 = spaces.first { $0.title == "Space 3" }
        XCTAssertEqual(ctrl3?.menuKeyEquivalent, "3")
        XCTAssertEqual(ctrl3?.modifiers, .control)
        let navigation = ShellMenus.navigation(model).flatMap { $0 }.filter { !$0.isAlternate }.map { "\($0.title)=\($0.menuKeyEquivalent)" }
        XCTAssertEqual(navigation, ["Back=[", "Forward=]", "Reload Page=r", "Reload Ignoring Cache=r", "Stop Loading=."])
        let pin = ShellMenus.sidebarItems(model).flatMap { $0 }.first { $0.title == "Pin/Unpin Tab" }
        XCTAssertEqual(pin?.menuKeyEquivalent, "d")
        // Ctrl+2 switches to the second space of the active profile.
        spaces.first { $0.title == "Space 2" }?.action()
        XCTAssertEqual(model.store.activeSpaceID, model.store.spacesInActiveProfile[1].id)
    }

    func testFolderRowsPeekTheSelectedChildWhenCollapsed() throws {
        let store = SidebarStore()
        let a = store.addTab(kind: .pinned, title: "A", url: URL(string: "https://a.test")!)
        let b = store.addTab(kind: .pinned, title: "B", url: URL(string: "https://b.test")!)
        let folder = try XCTUnwrap(store.createFolder(containing: [a.id, b.id]))
        let content = store.content(for: store.activeSpaceID)
        var rows = SidebarRowItem.rows(content.pinned, expanded: [folder.id], selected: nil)
        XCTAssertEqual(rows.map(\.id), [folder.id, a.id, b.id])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
        rows = SidebarRowItem.rows(content.pinned, expanded: [], selected: b.id)
        XCTAssertEqual(rows.map(\.id), [folder.id, b.id])
        rows = SidebarRowItem.rows(content.pinned, expanded: [], selected: nil)
        XCTAssertEqual(rows.map(\.id), [folder.id])
    }

    func testURLFieldShowsDomain() {
        XCTAssertEqual(SidebarURLField.displayHost(URL(string: "https://www.example.com/a")!), "example.com")
        XCTAssertNil(SidebarURLField.displayHost(URL(string: "about:blank")!))
        XCTAssertEqual(SidebarURLField.displayHost(URL(string: "data:text/html,x")!), "data:text/html,x")
    }

    func testCmdWOnFavoriteUnloadsInsteadOfDeleting() throws {
        var favorite: Tab!
        var pinned: Tab!
        let model = makeModel { store in
            favorite = store.addTab(kind: .favorite, title: "F", url: URL(string: "https://f.test")!)
            pinned = store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!)
            store.selectTab(favorite.id)
        }
        model.loadSelectedIfNeeded()
        XCTAssertNotNil(model.engineHost.engine(forTabID: favorite.id, profileID: model.store.activeProfileID))
        model.closeSelectedTab()
        XCTAssertEqual(model.store.favorites.map(\.id), [favorite.id], "the favorite stays")
        XCTAssertNil(model.engineHost.engine(forTabID: favorite.id, profileID: model.store.activeProfileID), "engine unloaded")
        XCTAssertEqual(model.store.selectedItemID, pinned.id)
        XCTAssertTrue(model.store.closedTabStack.records.isEmpty)
        model.removeFavorite(favorite.id)
        XCTAssertTrue(model.store.favorites.isEmpty)
    }

    func testFavoriteEnginesUseTheOwningProfile() {
        let model = makeModel()
        let favorite = model.store.addTab(kind: .favorite, title: "F", url: URL(string: "https://f.test")!)
        let owner = model.store.activeProfileID
        let other = model.store.addProfile(name: "Other")
        model.selectProfile(other.id)
        XCTAssertEqual(model.profileID(for: favorite), owner)
    }

    func testArchiveAndRestoreThroughTheModel() throws {
        var today: Tab!
        let model = makeModel { store in
            today = store.addTab(kind: .today, title: "T", url: URL(string: "https://t.test")!)
            store.selectTab(today.id)
        }
        model.loadSelectedIfNeeded()
        model.archiveTab()
        XCTAssertNil(model.store.tab(withID: today.id))
        XCTAssertNil(model.engineHost.engine(forTabID: today.id, profileID: model.store.activeProfileID))
        model.restoreArchivedTab(today.id)
        XCTAssertEqual(model.store.selectedTabID, today.id)
        XCTAssertNotNil(model.engineHost.engine(forTabID: today.id, profileID: model.store.activeProfileID))
    }

    func testDeletionPromptsAndSpaceDelete() {
        let model = makeModel()
        let second = model.store.spacesInActiveProfile[1]
        model.executeCommand(.switchToSpace(second.id), commandID: nil)
        XCTAssertNil(model.executeCommand(.deleteSpace, commandID: nil))
        XCTAssertEqual(model.pendingDeletion, .space(second.id))
        XCTAssertTrue(model.pendingDeletionMessage.title.contains("Second"))
        model.confirmPendingDeletion()
        XCTAssertNil(model.store.space(withID: second.id))
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(model.executeCommand(.deleteSpace, commandID: nil), "The last space cannot be deleted")
    }

    func testRenamePromptRenamesFolderTabAndSpace() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .pinned, title: "Page", url: URL(string: "https://p.test")!)
        let folder = try XCTUnwrap(model.newFolder(containing: [tab.id]))
        XCTAssertEqual(model.pendingRename, .folder(folder.id), "a new folder opens the rename prompt")
        model.pendingRenameText = "Work"
        model.commitRename()
        XCTAssertEqual(model.store.folder(withID: folder.id)?.title, "Work")
        model.beginRename(.tab(tab.id))
        model.pendingRenameText = "Mine"
        model.commitRename()
        XCTAssertEqual(model.store.tab(withID: tab.id)?.displayTitle, "Mine")
        model.beginRename(.space(model.store.activeSpaceID))
        XCTAssertEqual(model.pendingRenameText, "Main")
        model.pendingRenameText = "Home"
        model.commitRename()
        XCTAssertEqual(model.store.activeSpace.name, "Home")
    }

    func testSidebarPeekOnlyWhileHidden() {
        let model = makeModel()
        model.setSidebarPeeking(true)
        XCTAssertFalse(model.isSidebarPeeking, "a visible sidebar never floats")
        model.toggleSidebar()
        model.setSidebarPeeking(true)
        XCTAssertTrue(model.isSidebarPeeking)
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarPeeking)
    }
}
