import Foundation
import SidebarModel

/// Containers (SPACE-CONTAINERS.md): a separate browsing session for one space,
/// inside a profile. The store keeps the profile › space › container shape;
/// this side drops and reloads engines when a space's storage changes and has
/// a removed container's data deleted (S-05, S-07).
extension BrowserViewModel {

    /// The container `deleteSpace(id)` also deletes: the one whose only space it is.
    func containerDeletedWithSpace(_ id: Space.ID) -> Profile.ID? {
        guard let container = store.container(ofSpace: id), store.spaces(in: container.id).count == 1 else { return nil }
        return container.id
    }

    /// Remove Container…: asks first (`pendingDeletion`, Cancel the default).
    func requestContainerRemoval(forSpace id: Space.ID) {
        guard let container = store.container(ofSpace: id) else { return }
        pendingDeletion = .container(container.id)
    }

    func containerRemovalMessage(_ id: Profile.ID) -> (title: String, message: String, action: String) {
        let space = store.spaces(in: id).first
        let parent = store.parentProfile(ofContainer: id)?.name ?? "its profile"
        let data = profileKeepsDataOnDelete?(id) == true
            ? "The container's browsing data stays on this Mac: it is in the first profile's folder, which ReArc never removes."
            : "The container's cookies, sign-ins and site data are deleted."
        guard let space else {
            return ("Remove This Container?", "\(data) This cannot be undone.", "Remove Container")
        }
        let count = SidebarTree.tabs(store.content(for: space.id).pinned + store.content(for: space.id).today).count
        return ("Remove the Container from “\(space.name)”?",
                "“\(space.name)” goes back to \(parent)'s own session, and its \(count) tab\(count == 1 ? "" : "s") reload there. \(data) This cannot be undone.",
                "Remove Container")
    }

    /// The space goes back to its parent's session, in the same place; then the
    /// container goes as a deleted profile does, data folder included, and the
    /// space's pages reload in the parent's storage.
    func removeContainer(_ id: Profile.ID) {
        guard store.isContainer(id) else { return }
        let live = Set(engineHost.allTabEngines().map(\.0))
        let moved = store.spaces(in: id).compactMap { store.moveSpaceOutOfContainer($0.id) == nil ? nil : $0.id }
        guard deleteProfile(id) == nil else { return }
        for spaceID in moved { reloadSpaceAfterProfileChange(spaceID, live: live) }
    }

    /// Change Profile ▸ for a container's space: it keeps its container, so its
    /// pages do not reload.
    func containerMoveMessage(_ change: SpaceProfileChange) -> (title: String, message: String, action: String) {
        let space = store.space(withID: change.spaceID)?.name ?? "Space"
        let destination = store.profile(withID: change.profileID)?.name ?? "Profile"
        return ("Move “\(space)” to \(destination)?",
                "It keeps its container: its tabs, cookies and sign-ins stay as they are. It follows \(destination)'s settings.",
                "Move Space")
    }

    /// Settings › Profiles, Make This a Container of ▸: storage stays, so nothing reloads.
    @discardableResult
    func makeContainer(_ id: Profile.ID, of parentID: Profile.ID) -> ContainerChangeError? {
        let error = store.makeContainer(id, of: parentID)
        if error == nil { alignContainerSearchEngine(id) }
        return error
    }

    /// Settings › Profiles, Make This a Profile.
    @discardableResult
    func makeProfile(_ id: Profile.ID) -> ContainerChangeError? {
        store.makeProfile(id)
    }

    /// A session as the confirmations name it: a profile by its name, a
    /// container by its space (“the “Mail” container”).
    func sessionName(of profileID: Profile.ID) -> String {
        guard store.isContainer(profileID) else { return store.profile(withID: profileID)?.name ?? "the other profile" }
        return store.spaces(in: profileID).first.map { "the “\($0.name)” container" } ?? "the container"
    }

    /// A Chromium settings page in `profileID`'s own storage: in one of its own
    /// spaces, never a container's space of that profile.
    func openBrowserPage(_ page: BrowserInternalPage, inStorageOf profileID: Profile.ID) {
        if store.activeSpace.profileID != profileID {
            store.selectSpace(usingStorageOf: profileID)
            loadSelectedIfNeeded()
        }
        openBrowserPage(page)
    }

    /// What a profile delete says of its containers on this Mac and in iCloud.
    /// Deleting from iCloud takes the profile's own records only: with Sync
    /// Sidebar on, the containers' deletion here reaches iCloud as any delete
    /// does; with it off, iCloud keeps their records.
    func containersDeletedNote(_ profileID: Profile.ID, reachesICloud: Bool) -> String {
        let names = store.containers(of: profileID).map { "“\(store.spaces(in: $0.id).first?.name ?? $0.name)”" }
        guard !names.isEmpty else { return "" }
        let these = names.count == 1 ? "Its container for \(names[0]) goes" : "Its containers for \(ListFormatter.localizedString(byJoining: names)) go"
        guard reachesICloud else { return " \(these) from this Mac too, with \(names.count == 1 ? "its" : "their") sign-ins." }
        return isSyncEnabled
            ? " \(these) too, from this Mac and, with the next sync, from iCloud."
            : " \(these) from this Mac too. iCloud keeps \(names.count == 1 ? "the container's" : "the containers'") records, which then show under In iCloud only."
    }

    /// A space in Move to Space and Move to Profile: a container's says so, as
    /// a move there changes the tabs' session.
    func spaceMenuTitle(_ space: Space) -> String {
        store.container(ofSpace: space.id) == nil ? space.name : "\(space.name) (Container)"
    }

    /// The profile whose settings `id` follows: a container's parent.
    func settingsProfileID(for id: Profile.ID) -> Profile.ID {
        store.owningProfileID(of: id)
    }

    /// The command bar's search provider for the active space: the parent's for
    /// a container. Only the template comes from there; the search loads in the
    /// active space, so in the container's storage.
    var activeSearchProfileID: Profile.ID { store.activeOwningProfileID }

    /// Sets the default search engine of a profile and of its containers, which
    /// follow it. A container's engine list is its own (ids differ), so it gets
    /// the choice with the same name, once its list has loaded.
    func setDefaultSearchEngine(_ choice: SearchEngineChoice.ID, for profileID: Profile.ID) {
        guard let search = activeSearchEngineSettings else { return }
        let owner = settingsProfileID(for: profileID)
        search.setDefaultEngine(choice, for: owner)
        guard let name = search.engines(for: owner).first(where: { $0.id == choice })?.name else { return }
        for container in store.containers(of: owner) {
            if let match = search.engines(for: container.id).first(where: { $0.name == name }) {
                search.setDefaultEngine(match.id, for: container.id)
            }
        }
    }

    /// A new container takes its parent's default search engine when both lists are loaded.
    func alignContainerSearchEngine(_ id: Profile.ID) {
        guard let search = activeSearchEngineSettings, let parent = store.parentProfile(ofContainer: id),
              let current = search.defaultEngine(for: parent.id),
              let name = search.engines(for: parent.id).first(where: { $0.id == current })?.name,
              let match = search.engines(for: id).first(where: { $0.name == name }),
              search.defaultEngine(for: id) != match.id else { return }
        search.setDefaultEngine(match.id, for: id)
    }
}
