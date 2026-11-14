import Foundation

public enum SpaceArchiveError: Error, Equatable {
    case spaceNotFound
    case alreadyArchived
    case notArchived
    /// Delete's rule: the last listed space stays.
    case lastSpace
    /// A container has exactly one space; archiving it would leave the container empty.
    case containerSpace
}

/// Archive Space (docs/FEATURE-SPECS/ARCHIVE-SPACE.md), a ReArc addition: the
/// space leaves every list of spaces and waits, exactly as it was, in its
/// profile's Archived Spaces (Settings › Profiles) until Restore or Delete.
/// Only `archivedAt` changes. Pinned and Today tabs, folders, theme, icon,
/// boosts, profile and position (`sortRank`) all stay. The shell releases
/// the space's engines (`reconcileEngineOwnership` keeps listed spaces' only).
extension SidebarStore {

    /// Why `archiveSpace(_:)` would refuse, or nil when it can run.
    public func archiveBlocker(forSpace id: Space.ID) -> SpaceArchiveError? {
        guard let space = space(withID: id) else { return .spaceNotFound }
        guard !space.isArchived else { return .alreadyArchived }
        guard !isContainer(space.profileID) else { return .containerSpace }
        guard visibleSpaces.count > 1 else { return .lastSpace }
        return nil
    }

    /// Takes the space out of every list. The active space hands over to a
    /// neighbour, as Delete does; its selection is remembered for Restore.
    @discardableResult
    public func archiveSpace(_ id: Space.ID) -> SpaceArchiveError? {
        if let blocker = archiveBlocker(forSpace: id) { return blocker }
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return .spaceNotFound }
        let owner = owningProfileID(of: spaces[index].profileID)
        if activeSpaceID == id, let selected = selectedItemID {
            selectionBySpace[id] = selected
        }
        spaces[index].archivedAt = now()
        if activeSpaceID == id { leaveSpace(ownedBy: owner) }
        for (profile, remembered) in lastActiveSpaceByProfile where remembered == id {
            lastActiveSpaceByProfile[profile] = spaces(listedIn: profile).first?.id
        }
        for (window, focused) in focusedSpaceByWindow where focused == id {
            focusedSpaceByWindow[window] = activeSpaceID
        }
        notifyMutation(.upsertSpace(id: id))
        return nil
    }

    /// Puts an archived space back where it was in its profile's order (at
    /// the end when that slot is gone), exactly as it was. The caller
    /// switches to it.
    @discardableResult
    public func restoreArchivedSpace(_ id: Space.ID) -> SpaceArchiveError? {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return .spaceNotFound }
        guard spaces[index].isArchived else { return .notArchived }
        spaces[index].archivedAt = nil
        let rank = spaces[index].sortRank
        if rank.isEmpty || spaces.contains(where: { $0.id != id && $0.sortRank == rank }) {
            spaces[index].sortRank = rankForNewSpace()
            mutationJournal.record(.moveSpace(id: id, sortRank: spaces[index].sortRank))
        }
        notifyMutation(.upsertSpace(id: id))
        return nil
    }

    /// A profile's archived spaces, most recently archived first.
    public func archivedSpaces(in profileID: Profile.ID) -> [Space] {
        spaces.filter { $0.isArchived && $0.profileID == profileID }
            .sorted { ($0.archivedAt ?? .distantPast, $0.id.uuidString) > ($1.archivedAt ?? .distantPast, $1.id.uuidString) }
    }
}
