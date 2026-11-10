import Foundation

public enum SpaceProfileChangeError: Error, Equatable {
    case spaceNotFound
    case profileNotFound
    case sameProfile
}

/// Changing an existing space's profile (Arc `changeProfileForCurrentSpace`,
/// `ChangeProfileDialog`, PROFILES §2). The space keeps its tabs, folders,
/// splits and selection; it moves to the end of the new profile's spaces.
/// Its tabs then belong to the new profile's engine storage, so the shell
/// drops their engines and reloads them there (cookies, sign-ins and site
/// data stay with the old profile; that is what the confirmation says).
extension SidebarStore {

    /// Why `changeProfile(ofSpace:to:)` would refuse, or nil when it can run.
    public func profileChangeBlocker(forSpace id: Space.ID, to profileID: Profile.ID) -> SpaceProfileChangeError? {
        guard let space = space(withID: id) else { return .spaceNotFound }
        guard profile(withID: profileID) != nil else { return .profileNotFound }
        guard space.profileID != profileID else { return .sameProfile }
        return nil
    }

    /// All profiles, including the current/default profile, in picker order.
    public func profileChoices(forSpace id: Space.ID) -> [Profile] {
        space(withID: id) == nil ? [] : profiles
    }

    /// A fresh persistent profile, without the extra starter space used by New Profile.
    /// Name collisions are disambiguated; identity is always a new UUID.
    public func createContainerProfile(name: String, theme: SpaceTheme) -> Profile {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "Container" : base
        var name = stem
        var suffix = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(stem) \(suffix)"
            suffix += 1
        }
        return addProfile(name: name, themeColor: theme, createInitialSpace: false)
    }

    @discardableResult
    public func createContainer(forSpace id: Space.ID) -> Profile? {
        guard let space = space(withID: id) else { return nil }
        let profile = createContainerProfile(name: space.name, theme: space.theme)
        _ = changeProfile(ofSpace: id, to: profile.id)
        return profile
    }

    @discardableResult
    public func changeProfile(ofSpace id: Space.ID, to profileID: Profile.ID) -> SpaceProfileChangeError? {
        if let blocker = profileChangeBlocker(forSpace: id, to: profileID) { return blocker }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return .spaceNotFound }
        let rank = rankForNewSpace()
        reassignSpaceProfile(at: index, to: profileID, sortRank: rank)
        mutationJournal.record(.moveSpace(id: id, sortRank: rank))
        notifyMutation(.upsertSpace(id: id))
        return nil
    }
}
