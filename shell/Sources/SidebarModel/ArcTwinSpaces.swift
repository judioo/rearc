import Foundation

/// Spaces imported from the same Arc space more than once.
///
/// Up to 608, each install imported Arc into new spaces with random ids,
/// in a main profile of its own, while the rows took ids derived from
/// Arc's (`ArcSidebarImport.arcItemID`). A first sync then merged in every
/// earlier install's spaces by record name: one copy of each Arc space per
/// install, all claiming the same rows. A row is in one place only, so one
/// copy kept everything and the others came up empty; the copies sit in
/// different profiles, and a profile's own copies could all be empty.
///
/// `repair` merges such copies in a sidebar already holding them;
/// `matchingServer` keeps a first join from making them.
public enum ArcTwinSpaces {
    /// What `repair` changed, in counts.
    public struct Report: Equatable, Sendable {
        /// Arc spaces that had more than one copy.
        public var duplicatedSources = 0
        /// Copies merged into a copy in the same profile.
        public var mergedSameProfile = 0
        /// Empty copies in another profile, removed.
        public var removedEmpty = 0
        /// Rows moved into the copy kept.
        public var movedRows = 0
        /// Copies left as they were: content of their own in another
        /// profile, or the last space of a profile.
        public var keptCopies = 0
        /// Row ids listed in more than one place, now listed once.
        public var droppedRepeats = 0

        public var changed: Bool { mergedSameProfile + removedEmpty + droppedRepeats > 0 }
    }

    /// One Arc space per profile, and every row listed once. Of each
    /// group of copies the one holding the most rows stays. A copy in the
    /// same profile merges into it (its rows move, nothing is lost); an
    /// empty copy in another profile goes, unless it is the last space
    /// there; a copy with rows of its own in another profile stays.
    /// Running it again changes nothing.
    public static func repair(_ snapshot: SidebarSnapshot) -> (SidebarSnapshot, Report) {
        var s = snapshot
        var report = Report()
        var groups: [String: [Space.ID]] = [:]
        for space in s.spaces {
            guard let source = space.arcSourceID else { continue }
            groups[source, default: []].append(space.id)
        }
        for (source, ids) in groups.sorted(by: { $0.key < $1.key }) where ids.count > 1 {
            report.duplicatedSources += 1
            let keeper = ids.max { lhs, rhs in
                let (a, b) = (s.reachableIDs(in: lhs).count, s.reachableIDs(in: rhs).count)
                if a != b { return a < b }
                // Equal: the active profile's copy, then the first in the sidebar.
                let (activeA, activeB) = (s.profileID(of: lhs) == s.activeProfileID, s.profileID(of: rhs) == s.activeProfileID)
                if activeA != activeB { return !activeA }
                return (ids.firstIndex(of: lhs) ?? 0) > (ids.firstIndex(of: rhs) ?? 0)
            }!
            let keeperProfile = s.profileID(of: keeper)
            for id in ids where id != keeper {
                let profile = s.profileID(of: id)
                if profile == keeperProfile {
                    report.movedRows += s.fold(space: id, into: keeper)
                    report.mergedSameProfile += 1
                } else if s.reachableIDs(in: id).isEmpty, !source.hasSuffix(":__favorites"),
                          s.spaces.filter({ $0.profileID == profile }).count > 1 {
                    s.fold(space: id, into: keeper)
                    report.removedEmpty += 1
                } else {
                    report.keptCopies += 1
                }
            }
        }
        report.droppedRepeats = s.listEachRowOnce()
        return (report.changed ? s : snapshot, report)
    }

    /// A first join, before this Mac's rows are stamped: a local space
    /// imported from the same Arc space as one already in iCloud becomes
    /// that one (its id, its profile), bringing its Today tabs and any rows
    /// iCloud lacks, so the Arc space is there once. A profile of this Mac
    /// that iCloud does not have, all of whose spaces now live in iCloud's
    /// profiles, folds into the profile that took most of them, with its
    /// favorites (one per address).
    static func matchingServer(_ snapshot: SidebarSnapshot, records: [String: SyncRecordPayload]) -> SidebarSnapshot {
        var serverSpaces: [UUID: (profile: UUID?, source: String?)] = [:]
        var rows: [String: Int] = [:]
        var favoriteURLs: [UUID: Set<String>] = [:]
        for (name, payload) in records where payload.isAlive {
            guard let (kind, id) = SyncRecordKind.parse(recordName: name) else { continue }
            let values = payload.values
            switch kind {
            case .space:
                serverSpaces[id] = (values["profileID"]?.stringValue.flatMap(UUID.init(uuidString:)), values["arcSourceID"]?.stringValue)
            case .item:
                if let space = values["space"]?.stringValue { rows[space.lowercased(), default: 0] += 1 }
                if let parent = values["parent"]?.stringValue, parent.hasPrefix("favorites:"),
                   let profile = UUID(uuidString: String(parent.dropFirst("favorites:".count))),
                   let url = values["url"]?.stringValue.flatMap(URL.init(string:)) {
                    favoriteURLs[profile, default: []].insert(BookmarkImportPlan.key(url))
                }
            default:
                break
            }
        }
        guard !serverSpaces.isEmpty else { return snapshot }
        var s = snapshot
        let local = Set(s.spaces.map(\.id))
        var claimed = Set<UUID>()
        for space in snapshot.spaces where serverSpaces[space.id] == nil {
            guard let source = space.arcSourceID else { continue }
            let twin = serverSpaces.filter { $0.value.source == source && !local.contains($0.key) && !claimed.contains($0.key) }
                .max { (rows[$0.key.uuidString.lowercased()] ?? 0, $1.key.uuidString) < (rows[$1.key.uuidString.lowercased()] ?? 0, $0.key.uuidString) }
            guard let twin else { continue }
            claimed.insert(twin.key)
            s.rename(space: space.id, to: twin.key, profile: twin.value.profile ?? space.profileID)
        }

        for profile in snapshot.profiles where records[SyncRecordKind.profile.recordName(for: profile.id)] == nil {
            let spaces = s.spaces.filter { $0.profileID == profile.id }
            // Where each space lives once the join applies: iCloud's profile, or stays here.
            let homes = spaces.map { serverSpaces[$0.id]?.profile ?? profile.id }
            guard !homes.isEmpty, !homes.contains(profile.id),
                  s.boostLibrariesByProfileID[profile.id]?.packages.isEmpty ?? true else { continue }
            let counts = Dictionary(homes.map { ($0, 1) }, uniquingKeysWith: +)
            let target = counts.max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }!.key
            s.fold(profile: profile.id, into: target, knownFavoriteURLs: favoriteURLs[target] ?? [])
        }
        return s
    }
}

extension SidebarSnapshot {
    func profileID(of space: Space.ID) -> Profile.ID? {
        spaces.first { $0.id == space }?.profileID
    }

    /// Every row reachable from the space's pinned and Today sections.
    func reachableIDs(in space: Space.ID) -> Set<UUID> {
        var seen = Set<UUID>()
        func walk(_ ids: [UUID]) {
            for id in ids where seen.insert(id).inserted {
                if let folder = foldersByID[id] { walk(folder.childIDs) }
                if let split = splitsByID[id] { split.tabs.forEach { seen.insert($0.id) } }
            }
        }
        guard let bundle = spaceContainers[space] else { return [] }
        walk(bundle.pinned.childIDs)
        walk(bundle.unpinned.childIDs)
        return seen
    }

    /// Moves `from`'s rows that `into` does not already hold to the end of
    /// its sections and removes `from`; what named `from` names `into`.
    /// Returns how many rows moved.
    @discardableResult
    mutating func fold(space from: Space.ID, into: Space.ID) -> Int {
        guard from != into, let target = spaces.firstIndex(where: { $0.id == into }) else { return 0 }
        let held = reachableIDs(in: into)
        var moved = 0
        if let source = spaceContainers[from], var bundle = spaceContainers[into] {
            let pinned = source.pinned.childIDs.filter { !held.contains($0) }
            let today = source.unpinned.childIDs.filter { !held.contains($0) }
            moved = pinned.count + today.count
            bundle.pinned.childIDs += pinned
            bundle.unpinned.childIDs += today
            spaceContainers[into] = bundle
        }
        if let old = spaces.first(where: { $0.id == from }) {
            if let ids = old.arcImportedItemIDs { spaces[target].arcImportedItemIDs = (spaces[target].arcImportedItemIDs ?? []).union(ids) }
            if let mapping = old.arcItemMapping {
                spaces[target].arcItemMapping = (spaces[target].arcItemMapping ?? [:]).merging(mapping) { kept, _ in kept }
            }
        }
        spaceContainers[from] = nil
        spaces.removeAll { $0.id == from }
        redirect(space: from, to: into)
        return moved
    }

    /// The space takes another id and profile, keeping its rows.
    mutating func rename(space from: Space.ID, to: Space.ID, profile: Profile.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == from }), !spaces.contains(where: { $0.id == to }) else { return }
        if !profiles.contains(where: { $0.id == profile }) { profiles.append(Profile.recovered(profile, from: profiles)) }
        spaces[index] = spaces[index].withID(to)
        spaces[index].profileID = profile
        if var bundle = spaceContainers.removeValue(forKey: from) {
            bundle.pinned.kind = .spaceItems(spaceID: to, section: .pinned)
            bundle.unpinned.kind = .spaceItems(spaceID: to, section: .unpinned)
            spaceContainers[to] = bundle
        }
        redirect(space: from, to: to)
    }

    private mutating func redirect(space from: Space.ID, to: Space.ID) {
        let profile = profileID(of: to)
        if activeSpaceID == from {
            activeSpaceID = to
            if let profile { activeProfileID = profile }
        }
        for (owner, space) in lastActiveSpaceByProfile where space == from {
            lastActiveSpaceByProfile[owner] = owner == profile ? to : spaces.first { $0.profileID == owner }?.id
        }
        if let selection = selectionBySpace.removeValue(forKey: from), selectionBySpace[to] == nil { selectionBySpace[to] = selection }
        for index in archivedTabs.indices where archivedTabs[index].spaceID == from { archivedTabs[index].spaceID = to }
        for index in closedTabStack.records.indices where closedTabStack.records[index].spaceID == from {
            closedTabStack.records[index].spaceID = to
        }
    }

    /// The profile goes; its favorites move to `into` (one per address).
    mutating func fold(profile from: Profile.ID, into: Profile.ID, knownFavoriteURLs: Set<String>) {
        guard from != into else { return }
        if !profiles.contains(where: { $0.id == into }) { profiles.append(Profile.recovered(into, from: profiles)) }
        var target = topAppsContainersByProfileID[into] ?? ItemContainerRecord(kind: .topApps)
        var urls = knownFavoriteURLs.union(target.childIDs.compactMap { tabsByID[$0] }.map { BookmarkImportPlan.key($0.savedURL ?? $0.url) })
        for id in topAppsContainersByProfileID[from]?.childIDs ?? [] {
            guard let tab = tabsByID[id] else { continue }
            if urls.insert(BookmarkImportPlan.key(tab.savedURL ?? tab.url)).inserted {
                target.childIDs.append(id)
            } else {
                tabsByID[id] = nil
            }
        }
        topAppsContainersByProfileID[into] = target
        topAppsContainersByProfileID[from] = nil
        for index in spaces.indices where spaces[index].profileID == from { spaces[index].profileID = into }
        profiles.removeAll { $0.id == from }
        if activeProfileID == from { activeProfileID = into }
        if let space = lastActiveSpaceByProfile.removeValue(forKey: from), lastActiveSpaceByProfile[into] == nil {
            lastActiveSpaceByProfile[into] = space
        }
        boostLibrariesByProfileID[from] = nil
        if let threshold = autoArchiveThresholdByProfile.removeValue(forKey: from), autoArchiveThresholdByProfile[into] == nil {
            autoArchiveThresholdByProfile[into] = threshold
        }
    }

    /// A row listed in two places shows in one: favorites first, then the
    /// spaces in order, pinned before Today. Returns how many listings went.
    mutating func listEachRowOnce() -> Int {
        var seen = Set<UUID>()
        var dropped = 0
        func keep(_ ids: [UUID]) -> [UUID] {
            ids.filter { id in
                guard seen.insert(id).inserted else { dropped += 1; return false }
                if let folder = foldersByID[id] {
                    let children = keep(folder.childIDs)
                    foldersByID[id]?.childIDs = children
                }
                if let split = splitsByID[id] { split.tabs.forEach { seen.insert($0.id) } }
                return true
            }
        }
        for profile in profiles {
            if let container = topAppsContainersByProfileID[profile.id] { topAppsContainersByProfileID[profile.id]?.childIDs = keep(container.childIDs) }
        }
        for space in spaces {
            guard let bundle = spaceContainers[space.id] else { continue }
            spaceContainers[space.id]?.pinned.childIDs = keep(bundle.pinned.childIDs)
            spaceContainers[space.id]?.unpinned.childIDs = keep(bundle.unpinned.childIDs)
        }
        return dropped
    }
}

extension Space {
    /// The same space under another id.
    func withID(_ id: UUID) -> Space {
        var copy = Space(id: id, name: name, theme: theme, iconName: iconName, pinnedContainerID: pinnedContainerID,
                         unpinnedContainerID: unpinnedContainerID, unpinnedShared: unpinnedShared, profileID: profileID,
                         sortRank: sortRank, boostsEnabled: boostsEnabled)
        copy.arcSourceID = arcSourceID
        copy.arcImportedItemIDs = arcImportedItemIDs
        copy.arcItemMapping = arcItemMapping
        copy.bookmarkSourceID = bookmarkSourceID
        copy.archivedAt = archivedAt
        return copy
    }
}
