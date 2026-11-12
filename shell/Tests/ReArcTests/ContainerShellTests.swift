import XCTest
@testable import ReArc
@testable import SidebarModel

/// Containers inside profiles, on the shell side (docs/SPACE-CONTAINERS.md).
@MainActor
final class ContainerShellTests: XCTestCase {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

    /// Personal with Mail (selected, one loaded tab) and Bank.
    private func makeModel() -> (model: BrowserViewModel, mail: Space, bank: Space, tab: Tab) {
        let store = SidebarStore(spaces: [Space(name: "Mail", sortRank: "a")])
        let bank = store.addSpace(name: "Bank", profileID: store.activeProfileID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-containers-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        let tab = store.addTab(kind: .today, title: "Statement", url: url("bank.test"), in: bank.id)
        return (model, store.spaces[0], bank, tab)
    }

    func testNewContainerReloadsInItsStorageAndKeepsThePlace() throws {
        let (model, mail, bank, tab) = makeModel()
        let personal = model.store.activeProfileID
        let old = model.engineHost.engine(for: tab, profileID: personal)
        XCTAssertNil(model.containerLabel(for: old, tab: tab))
        model.createContainerForSpace(bank.id)
        let container = try XCTUnwrap(model.store.container(ofSpace: bank.id))
        XCTAssertEqual(model.store.spaces(listedIn: personal).map(\.id), [mail.id, bank.id])
        XCTAssertNil(model.engineHost.engine(forTabID: tab.id, profileID: personal), "the old session's engine is gone")
        // Its old engine still names its real session; the next one names the container.
        XCTAssertNil(model.containerLabel(for: old, tab: tab), "the engine's profile, not the space's")
        let new = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        XCTAssertEqual(model.containerLabel(for: new, tab: tab)?.containerID, container.id)
        XCTAssertEqual(model.containerLabel(for: nil, tab: tab)?.name, "Bank", "a tab not loaded yet: where it will load")
        XCTAssertEqual(model.profile(in: nil).id, personal)
    }

    func testRemoveContainerAsksThenDeletesItsDataAndReloads() throws {
        let (model, _, bank, tab) = makeModel()
        let personal = model.store.activeProfileID
        model.createContainerForSpace(bank.id)
        let container = try XCTUnwrap(model.store.container(ofSpace: bank.id)).id
        let engine = model.engineHost.engine(for: tab, profileID: container)
        engine.load(tab.url)
        var deleted: [Profile.ID] = []
        model.onProfileDeleted = { id, _ in deleted.append(id) }
        model.requestContainerRemoval(forSpace: bank.id)
        XCTAssertEqual(model.pendingDeletion, .container(container))
        let text = model.pendingDeletionMessage
        XCTAssertEqual(text.title, "Remove the Container from “Bank”?")
        XCTAssertTrue(text.message.contains("cookies, sign-ins and site data are deleted"))
        XCTAssertTrue(text.message.contains("Personal's own session"))
        XCTAssertEqual(text.action, "Remove Container")
        model.profileKeepsDataOnDelete = { _ in true }
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("stays on this Mac"), "S-07: the Default folder stays")
        model.profileKeepsDataOnDelete = nil
        model.confirmPendingDeletion()
        XCTAssertEqual(deleted, [container], "its data folder goes as a deleted profile's (S-07)")
        XCTAssertNil(model.store.profile(withID: container))
        XCTAssertEqual(model.store.space(withID: bank.id)?.profileID, personal)
        XCTAssertNil(model.engineHost.engine(forTabID: tab.id, profileID: container))
    }

    func testDeletingAParentNamesAndDeletesItsContainers() throws {
        let (model, _, _, _) = makeModel()
        let store = model.store
        let work = store.addProfile(name: "Work")
        let client = store.addSpace(name: "Client", profileID: work.id)
        model.createContainerForSpace(client.id)
        let container = try XCTUnwrap(store.container(ofSpace: client.id)).id
        model.pendingDeletion = .profile(work.id)
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("Its 2 spaces"))
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("Its container for “Client”"))
        var deleted: [Profile.ID] = []
        model.onProfileDeleted = { id, _ in deleted.append(id) }
        model.confirmPendingDeletion()
        XCTAssertEqual(deleted, [work.id, container])
        XCTAssertNil(store.profile(withID: container))
    }

    func testDeletingAContainersOnlySpaceDeletesTheContainer() throws {
        let (model, _, bank, _) = makeModel()
        model.createContainerForSpace(bank.id)
        let container = try XCTUnwrap(model.store.container(ofSpace: bank.id)).id
        model.pendingDeletion = .space(bank.id)
        XCTAssertTrue(model.pendingDeletionMessage.message.contains("Its container's cookies, sign-ins and site data are deleted too"))
        var deleted: [Profile.ID] = []
        model.onProfileDeleted = { id, _ in deleted.append(id) }
        model.confirmPendingDeletion()
        XCTAssertEqual(deleted, [container])
    }

    /// Moving rows into a container's space crosses a session boundary: it asks
    /// with Move to Profile's confirmation, from the menu, a drop or the command bar.
    func testMovesIntoAContainerAsk() throws {
        let (model, mail, bank, _) = makeModel()
        model.createContainerForSpace(bank.id)
        let inbox = model.store.addTab(kind: .today, title: "Inbox", url: url("mail.test"), in: mail.id)
        model.moveTab(inbox.id, toSpace: bank.id)
        XCTAssertEqual(model.pendingProfileMove, SidebarProfileMove(ids: [inbox.id], spaceID: bank.id))
        XCTAssertEqual(model.store.spaceContaining(tabID: inbox.id), mail.id, "nothing moves before the answer")
        let text = model.profileMoveMessage(try XCTUnwrap(model.pendingProfileMove))
        XCTAssertEqual(text.title, "Move to Bank?")
        XCTAssertTrue(text.message.contains("reload in the “Bank” container"))
        XCTAssertTrue(text.message.contains("Cookies, sign-ins and site data stay in Personal"))
        model.pendingProfileMove = nil
        model.moveItems([inbox.id], toSpace: bank.id)
        XCTAssertNotNil(model.pendingProfileMove)
        model.pendingProfileMove = nil
        model.store.selectTab(inbox.id)
        XCTAssertNil(model.executeCommand(.moveTabToSpace(bank.id), commandID: nil))
        XCTAssertNotNil(model.pendingProfileMove)
        model.confirmProfileMove()
        XCTAssertEqual(model.store.spaceContaining(tabID: inbox.id), bank.id)
        XCTAssertEqual(model.spaceMenuTitle(bank), "Bank (Container)")
    }

    func testMovingAContainersSpaceKeepsItsPages() throws {
        let (model, _, bank, tab) = makeModel()
        let work = model.store.addProfile(name: "Work")
        model.createContainerForSpace(bank.id)
        let container = try XCTUnwrap(model.store.container(ofSpace: bank.id)).id
        let engine = model.engineHost.engine(for: tab, profileID: container)
        let message = model.spaceProfileChangeMessage(SpaceProfileChange(spaceID: bank.id, profileID: work.id))
        XCTAssertTrue(message.message.contains("keeps its container"))
        XCTAssertNil(model.changeSpaceProfile(bank.id, to: work.id))
        XCTAssertTrue(model.engineHost.engine(forTabID: tab.id, profileID: container) === engine, "nothing reloads")
        XCTAssertEqual(model.store.parentProfile(ofContainer: container)?.id, work.id)
    }

    func testSearchesAndSettingsFollowTheParent() throws {
        let (model, _, bank, _) = makeModel()
        let personal = model.store.activeProfileID
        model.createContainerForSpace(bank.id)
        model.selectSpace(bank.id)
        XCTAssertNotEqual(model.store.activeProfileID, personal)
        XCTAssertEqual(model.activeSearchProfileID, personal)
        XCTAssertEqual(model.settingsProfileID(for: model.store.activeProfileID), personal)
        XCTAssertEqual(model.spaceCountText(for: personal), "2 Spaces")
    }

    func testTheICloudDeleteSaysWhatHappensToContainers() throws {
        let (model, _, bank, _) = makeModel()
        let personal = model.store.activeProfileID
        XCTAssertEqual(model.containersDeletedNote(personal, reachesICloud: true), "")
        model.createContainerForSpace(bank.id)
        XCTAssertTrue(model.containersDeletedNote(personal, reachesICloud: false).contains("from this Mac too"))
        let off = model.containersDeletedNote(personal, reachesICloud: true)
        XCTAssertFalse(model.isSyncEnabled)
        XCTAssertTrue(off.contains("iCloud keeps the container's records"), off)
    }
}
