import Foundation

public enum SpaceProfileChangeError: Error, Equatable {
    case spaceNotFound
    case profileNotFound
    case sameProfile
    /// A container is not a profile to move a space to: it has its one space.
    case profileIsContainer
}

/// Changing an existing space's profile (Arc `changeProfileForCurrentSpace`,
/// `ChangeProfileDialog`, PROFILES §2). The space keeps its tabs, folders,
/// splits and selection; it moves to the end of the new profile's spaces.
/// Its tabs then belong to the new profile's engine storage, so the shell
/// drops their engines and reloads them there (cookies, sign-ins and site
/// data stay with the old profile; that is what the confirmation says).
/// A container's space takes its container along instead (SidebarStore+Containers).
extension SidebarStore {

    /// The space a page created in `profileID` lands in (a popup or target=_blank tab, or
    /// "Open Link in New Tab" from a Little ReArc or Peek): `preferred` when it belongs to that
    /// profile, then the active space, then the profile's first space. Nil when the profile
    /// has no space, so the caller declines instead of relabeling the page's storage
    /// (security RC-0.1.0-564 S-01, S-03).
    public func space(forNewTabIn profileID: Profile.ID, preferring preferred: Space.ID? = nil) -> Space.ID? {
        // Storage, not listing: a container's pages stay in the container's space.
        ([preferred, activeSpaceID].compactMap { $0 } + spaces.map(\.id))
            .first { listedSpace(withID: $0)?.profileID == profileID }
    }

    /// Why `changeProfile(ofSpace:to:)` would refuse, or nil when it can run.
    public func profileChangeBlocker(forSpace id: Space.ID, to profileID: Profile.ID) -> SpaceProfileChangeError? {
        guard let space = space(withID: id) else { return .spaceNotFound }
        guard profile(withID: profileID) != nil else { return .profileNotFound }
        guard space.profileID != profileID, owningProfileID(of: space.profileID) != profileID else { return .sameProfile }
        guard !isContainer(profileID) else { return .profileIsContainer }
        return nil
    }

    /// All profiles but containers, including the current/default profile, in picker order.
    public func profileChoices(forSpace id: Space.ID) -> [Profile] {
        space(withID: id) == nil ? [] : listedProfiles
    }

    /// A fresh persistent profile, without the extra starter space used by New Profile.
    /// Name collisions are disambiguated; identity is always a new UUID. With
    /// `parentID` it is a container of that profile.
    public func createContainerProfile(name: String, theme: SpaceTheme, of parentID: Profile.ID? = nil) -> Profile {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "Container" : base
        var name = stem
        var suffix = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(stem) \(suffix)"
            suffix += 1
        }
        var profile = addProfile(name: name, themeColor: theme, createInitialSpace: false)
        if let parentID = parentID.map(owningProfileID(of:)), let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index].containerOf = parentID
            profile = profiles[index]
        }
        return profile
    }

    /// Whether `changeProfile(ofSpace:to:)` keeps the space's storage: a
    /// container's space moves with its container, so its tabs need no reload.
    public func profileChangeKeepsStorage(forSpace id: Space.ID) -> Bool {
        space(withID: id).map { isContainer($0.profileID) } ?? false
    }

    @discardableResult
    public func changeProfile(ofSpace id: Space.ID, to profileID: Profile.ID) -> SpaceProfileChangeError? {
        if let blocker = profileChangeBlocker(forSpace: id, to: profileID) { return blocker }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return .spaceNotFound }
        if isContainer(spaces[index].profileID) {
            moveContainer(ofSpaceAt: index, to: profileID)
            return nil
        }
        let rank = rankForNewSpace()
        reassignSpaceProfile(at: index, to: profileID, sortRank: rank)
        mutationJournal.record(.moveSpace(id: id, sortRank: rank))
        notifyMutation(.upsertSpace(id: id))
        return nil
    }
}
