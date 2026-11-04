import Foundation

public enum SpaceProfileChangeError: Error, Equatable {
    case spaceNotFound
    case profileNotFound
    case sameProfile
    /// A profile keeps at least one space; delete the profile instead.
    case lastSpaceInProfile
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
        guard spaces(in: space.profileID).count > 1 else { return .lastSpaceInProfile }
        return nil
    }

    /// Profiles a space can move to, in profile order.
    public func profileChoices(forSpace id: Space.ID) -> [Profile] {
        profiles.filter { profileChangeBlocker(forSpace: id, to: $0.id) == nil }
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
