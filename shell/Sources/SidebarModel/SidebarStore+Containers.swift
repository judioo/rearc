import Foundation

public enum ContainerChangeError: Error, Equatable {
    case profileNotFound
    /// The profile already is a container, or already is not.
    case unchanged
    /// A container has exactly one space; this profile has `count`.
    case needsExactlyOneSpace(count: Int)
    /// A container cannot be the parent of another container.
    case parentIsContainer
    /// The profile is the parent of containers, so it cannot become one.
    case hasContainers
    /// The first profile holds the startup engine folder (S-07); it stays a profile.
    case firstProfile
}

/// What a container chip shows: the container a page runs in, named and
/// coloured as its space was when the container was made.
public struct ContainerLabel: Equatable, Sendable {
    public let containerID: Profile.ID
    public let name: String
    public let theme: SpaceTheme

    public init(containerID: Profile.ID, name: String, theme: SpaceTheme) {
        self.containerID = containerID
        self.name = name
        self.theme = theme
    }
}

/// Containers (SPACE-CONTAINERS.md): a separate browsing session for one space,
/// inside a profile. Underneath, a container is a `Profile` whose `containerOf`
/// names its parent; `Space.profileID` stays the storage key, so tabs, Peek,
/// Little ReArc and Boosts keep routing by it. Everything that lists spaces by
/// profile, or reads a per-profile setting, goes through the owning profile:
/// the profile › space › container hierarchy the person sees.
extension SidebarStore {

    // MARK: - Lookup

    /// The parent of container `id`, when that link holds: the parent exists, is
    /// not `id` and is not itself a container. A link that does not hold (its
    /// parent deleted on another Mac, or a chain) leaves `id` a plain profile, as
    /// builds before containers show it.
    public func parentProfile(ofContainer id: Profile.ID) -> Profile? {
        guard let parentID = profile(withID: id)?.containerOf, parentID != id,
              let parent = profile(withID: parentID), parent.containerOf == nil else { return nil }
        return parent
    }

    public func isContainer(_ id: Profile.ID) -> Bool {
        parentProfile(ofContainer: id) != nil
    }

    /// The profile `id`'s spaces are listed under and whose settings it follows:
    /// a container's parent, otherwise `id` itself.
    public func owningProfileID(of id: Profile.ID) -> Profile.ID {
        parentProfile(ofContainer: id)?.id ?? id
    }

    /// The profile the window's profile button shows for the active space.
    public var activeOwningProfileID: Profile.ID { owningProfileID(of: activeProfileID) }

    public var activeOwningProfile: Profile {
        profile(withID: activeOwningProfileID) ?? activeProfile
    }

    /// Profiles as the person sees them: every profile but the containers, in order.
    public var listedProfiles: [Profile] {
        profiles.filter { !isContainer($0.id) }
    }

    /// The containers of `parentID`, in profile order.
    public func containers(of parentID: Profile.ID) -> [Profile] {
        profiles.filter { $0.id != parentID && parentProfile(ofContainer: $0.id)?.id == parentID }
    }

    /// The container space `id` is in, when its profile is one.
    public func container(ofSpace id: Space.ID) -> Profile? {
        guard let profileID = space(withID: id)?.profileID, isContainer(profileID) else { return nil }
        return profile(withID: profileID)
    }

    /// How Settings and menus name a container: by its space, as it has no
    /// profile of its own to the person.
    public func containerTitle(_ id: Profile.ID) -> String {
        spaces(in: id).first.map { "Container for \($0.name)" } ?? "Container (no space)"
    }

    /// The chip for a page whose engine uses `profileID`'s storage: nil unless
    /// that is a container. Callers pass the engine's own profile, not its
    /// space's, so a space changing container never labels a page wrongly.
    public func containerLabel(forEngineProfile profileID: Profile.ID?) -> ContainerLabel? {
        guard let profileID, isContainer(profileID), let container = profile(withID: profileID) else { return nil }
        return ContainerLabel(containerID: profileID, name: spaces(in: profileID).first?.name ?? container.name,
                              theme: container.themeColor)
    }

    /// A profile's spaces as its strip, pager, Spaces menu and ⌃1…9 list them:
    /// its own and its containers', in space order. `spaces(in:)` stays the
    /// spaces whose pages use one profile's storage.
    public func spaces(listedIn profileID: Profile.ID) -> [Space] {
        let owner = owningProfileID(of: profileID)
        var owners: [Profile.ID: Profile.ID] = [:]
        for profile in profiles { owners[profile.id] = owningProfileID(of: profile.id) }
        return RankedSortable.sortedSpaces(spaces.filter { (owners[$0.profileID] ?? $0.profileID) == owner })
    }

    /// Makes active a space whose pages use `profileID`'s storage: the profile's
    /// last active one of its own, else its first, else a new landing space.
    /// Unlike `selectProfile`, never a container's space of that profile, so a
    /// page handed to the active space stays in its session (S-01, S-03).
    public func selectSpace(usingStorageOf profileID: Profile.ID) {
        guard profile(withID: profileID) != nil, activeSpace.profileID != profileID else { return }
        let own = spaces(in: profileID)
        if let remembered = lastActiveSpaceByProfile[owningProfileID(of: profileID)], own.contains(where: { $0.id == remembered }) {
            return selectSpace(remembered)
        }
        selectSpace((own.first ?? addSpace(name: "Space 1", profileID: profileID)).id)
    }

    // MARK: - Create and remove

    /// New Container for This Space: the space keeps its profile and its place in
    /// the strip; only its storage changes, to a new container of that profile.
    /// Nil when the space is already in a container. The caller reloads its tabs.
    @discardableResult
    public func createContainer(forSpace id: Space.ID) -> Profile? {
        guard let index = spaces.firstIndex(where: { $0.id == id }), !isContainer(spaces[index].profileID) else { return nil }
        let space = spaces[index]
        let container = createContainerProfile(name: space.name, theme: space.theme, of: space.profileID)
        reassignSpaceProfile(at: index, to: container.id, sortRank: space.sortRank)
        notifyMutation(.upsertSpace(id: id))
        return container
    }

    /// Remove Container: the space goes back to its parent's own session, in the
    /// same place. Returns the container, which the caller then deletes with its
    /// data (`deleteProfile`, S-05/S-07) and whose tabs it reloads.
    @discardableResult
    public func moveSpaceOutOfContainer(_ id: Space.ID) -> Profile.ID? {
        guard let index = spaces.firstIndex(where: { $0.id == id }),
              let parent = parentProfile(ofContainer: spaces[index].profileID) else { return nil }
        let container = spaces[index].profileID
        reassignSpaceProfile(at: index, to: parent.id, sortRank: spaces[index].sortRank)
        notifyMutation(.upsertSpace(id: id))
        return container
    }

    /// Change Profile ▸ for a container's space: the container goes with it (same
    /// storage, new parent), so nothing reloads. The space moves to the end of
    /// the new profile's spaces, as any Change Profile does.
    func moveContainer(ofSpaceAt index: Int, to parentID: Profile.ID) {
        let id = spaces[index].id
        let containerID = spaces[index].profileID
        let sourceOwner = owningProfileID(of: containerID)
        guard let containerIndex = profiles.firstIndex(where: { $0.id == containerID }) else { return }
        profiles[containerIndex].containerOf = parentID
        let rank = rankForNewSpace()
        spaces[index].sortRank = rank
        if lastActiveSpaceByProfile[sourceOwner] == id {
            lastActiveSpaceByProfile[sourceOwner] = spaces(listedIn: sourceOwner).first?.id
        }
        if activeSpaceID == id { lastActiveSpaceByProfile[parentID] = id }
        mutationJournal.record(.moveSpace(id: id, sortRank: rank))
        notifyMutation(.upsertSpace(id: id))
    }

    // MARK: - Profiles made by earlier builds

    /// Why `makeContainer(_:of:)` would refuse, or nil when it can run.
    public func containerConversionBlocker(_ id: Profile.ID, of parentID: Profile.ID) -> ContainerChangeError? {
        guard profile(withID: id) != nil, profile(withID: parentID) != nil, id != parentID else { return .profileNotFound }
        guard !isContainer(id) else { return .unchanged }
        guard profiles.first?.id != id else { return .firstProfile }
        guard containers(of: id).isEmpty else { return .hasContainers }
        guard profile(withID: parentID)?.containerOf == nil else { return .parentIsContainer }
        let count = spaces(in: id).count
        guard count == 1 else { return .needsExactlyOneSpace(count: count) }
        return nil
    }

    /// The profiles `id` could become a container of (Settings › Profiles,
    /// Make This a Container of ▸). Empty when it cannot become one.
    public func containerParentChoices(for id: Profile.ID) -> [Profile] {
        listedProfiles.filter { containerConversionBlocker(id, of: $0.id) == nil }
    }

    /// A profile the earlier New Container for This Space probably made: nothing
    /// recorded that, so this is a guess the person confirms. It has exactly one
    /// space, named as the profile was (the command named it after the space, with
    /// " 2", " 3"… on a clash), and it could become a container.
    public func looksLikeEarlierContainer(_ id: Profile.ID) -> Bool {
        guard let profile = profile(withID: id), !containerParentChoices(for: id).isEmpty,
              let space = spaces(in: id).first else { return false }
        let stem = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.name != stem else { return true }
        guard profile.name.hasPrefix(stem + " "), let suffix = Int(profile.name.dropFirst(stem.count + 1)) else { return false }
        return suffix >= 2
    }

    /// Make This a Container of ▸ `parentID`: the profile's one space joins the
    /// parent's strip, keeping its storage, so nothing reloads. Only when the
    /// person chooses it.
    @discardableResult
    public func makeContainer(_ id: Profile.ID, of parentID: Profile.ID) -> ContainerChangeError? {
        if let blocker = containerConversionBlocker(id, of: parentID) { return blocker }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return .profileNotFound }
        let spaceID = spaces(in: id).first?.id
        profiles[index].containerOf = parentID
        // One profile's memory now: the parent's.
        if let spaceID, lastActiveSpaceByProfile[parentID] == nil || activeSpaceID == spaceID {
            lastActiveSpaceByProfile[parentID] = spaceID
        }
        lastActiveSpaceByProfile[id] = nil
        notifyMutation(spaceID.map { .upsertSpace(id: $0) })
        return nil
    }

    /// Make This a Profile: the container's space leaves the parent's strip for
    /// its own profile's, with the same storage.
    @discardableResult
    public func makeProfile(_ id: Profile.ID) -> ContainerChangeError? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return .profileNotFound }
        guard let parent = parentProfile(ofContainer: id) else { return .unchanged }
        let spaceIDs = Set(spaces(in: id).map(\.id))
        profiles[index].containerOf = nil
        if let remembered = lastActiveSpaceByProfile[parent.id], spaceIDs.contains(remembered) {
            lastActiveSpaceByProfile[parent.id] = spaces(listedIn: parent.id).first?.id
            lastActiveSpaceByProfile[id] = remembered
        }
        notifyMutation(spaceIDs.first.map { .upsertSpace(id: $0) })
        return nil
    }
}

/// Settings › Profiles' "In iCloud only": a profile only iCloud has that is a
/// container of another profile only iCloud has lists under it, when the
/// container's record names that parent; any other one lists as a plain
/// profile, as builds before containers show it.
public enum CloudContainerNesting {
    public static func rows(_ profiles: [CloudProfile]) -> [(profile: CloudProfile, nested: Bool)] {
        let parents = Set(profiles.filter { $0.profile.containerOf == nil }.map(\.id))
        func parent(of cloud: CloudProfile) -> Profile.ID? {
            cloud.profile.containerOf.flatMap { $0 != cloud.id && parents.contains($0) ? $0 : nil }
        }
        var rows: [(profile: CloudProfile, nested: Bool)] = []
        for cloud in profiles where parent(of: cloud) == nil {
            rows.append((cloud, false))
            rows += profiles.filter { parent(of: $0) == cloud.id }.map { ($0, true) }
        }
        return rows
    }
}
