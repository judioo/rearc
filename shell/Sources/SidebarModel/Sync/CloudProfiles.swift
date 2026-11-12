import Foundation

// Settings › Profiles: each profile as iCloud's sidebar holds it, which of
// this Mac's profiles are there too, and deleting one profile from iCloud
// (docs/SYNC-RUNTIME.md, "Profiles in iCloud").

/// A space of a profile in iCloud.
public struct CloudSpace: Identifiable, Equatable, Sendable {
    public var id: Space.ID
    public var name: String
    public var pinnedTabs: Int

    public init(id: Space.ID, name: String, pinnedTabs: Int) {
        self.id = id
        self.name = name
        self.pinnedTabs = pinnedTabs
    }
}

/// A profile in iCloud: its name, avatar and colour from its record (a
/// space naming a profile with no record gets `Profile.recovered`'s), and
/// its spaces as sync would show them.
public struct CloudProfile: Identifiable, Equatable, Sendable {
    public var profile: Profile
    /// In sidebar order.
    public var spaces: [CloudSpace]
    /// The newest edit to the profile, its spaces, their rows or its favorites.
    public var lastEdited: Date?

    public init(profile: Profile, spaces: [CloudSpace], lastEdited: Date? = nil) {
        self.profile = profile
        self.spaces = spaces
        self.lastEdited = lastEdited
    }

    public var id: Profile.ID { profile.id }
    public var pinnedTabs: Int { spaces.reduce(0) { $0 + $1.pinnedTabs } }
}

/// Where one of this Mac's profiles is, by the session's look at iCloud.
public enum ProfileCloudPresence: Equatable, Sendable {
    /// iCloud has a live profile with the same id.
    case inICloud
    /// The look finished and iCloud has no profile with this id (one with
    /// the same name from another install is a different profile).
    case onlyHere
    /// A look is running, with the items read so far, or none finished yet.
    case looking(Int?)
    /// iCloud couldn't be read (signed out, offline, this build): why.
    case unknown(String)

    /// Never `.onlyHere` before a look has finished, nor while one runs.
    public static func of(_ id: Profile.ID, detection: CloudSidebarDetection?, looking: Bool, itemsRead: Int? = nil) -> ProfileCloudPresence {
        if looking { return .looking(itemsRead) }
        switch detection {
        case nil: return .looking(nil)
        case .empty?: return .onlyHere
        case .found(let found)?: return found.profiles.contains { $0.id == id } ? .inICloud : .onlyHere
        case .signedOut(let message)?, .unreachable(let message)?, .unavailable(let message)?: return .unknown(message)
        }
    }
}

extension CloudSidebarFound {
    /// iCloud's profiles that this Mac doesn't have (by id), by name.
    public func profiles(notIn local: [Profile]) -> [CloudProfile] {
        let ids = Set(local.map(\.id))
        return profiles.filter { !ids.contains($0.id) }
    }

    public func profile(_ id: Profile.ID) -> CloudProfile? {
        profiles.first { $0.id == id }
    }
}

/// How deleting one profile from iCloud went.
public enum CloudProfileDeletionResult: Equatable, Sendable {
    /// Done. `backup` holds the deleted records as they were read;
    /// `detection` is what iCloud holds now, so Settings shows it without
    /// reading again; `queued`: sync is on and the upload waits for iCloud.
    case deleted(backup: URL, detection: CloudSidebarDetection, queued: Bool)
    /// iCloud holds something else than what was confirmed: ask again with this.
    case changed(CloudProfileDeletion)
    /// iCloud holds nothing of the profile any more.
    case gone(CloudSidebarDetection)
    /// Nothing was deleted, or only part, as the message says.
    case failed(String)
}

/// iCloud's records on a scratch store, through the projection sync
/// applies, so counts here are the counts sync would show.
@MainActor
struct CloudProjection {
    let records: [String: SyncRecordPayload]
    let store: SidebarStore
    /// Spaces with a live record, not the scratch store's starter.
    let spaces: [Space]

    init(_ records: [String: SyncRecordPayload]) {
        self.records = records
        store = SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        store.applySnapshot(SidebarSyncProjection.apply(records, onto: store.makeSnapshot()))
        let synced = Set(records.filter { $0.value.isAlive && $0.value.kind == .space }.keys)
        spaces = store.spaces.filter { synced.contains(SyncRecordKind.space.recordName(for: $0.id)) }
    }

    var summary: CloudSidebarSummary {
        let pinned = spaces.reduce(0) { $0 + SidebarTree.leaves(store.content(for: $1.id).pinned).count }
        let favorites = store.profiles.reduce(0) { $0 + store.favorites(in: $1.id).count }
        let newest = records.values.compactMap(\.latestStamp).map(\.millis).max()
        let copies = ArcTwinSpaces.repair(store.makeSnapshot()).1
        return CloudSidebarSummary(spaces: spaces.count, pinnedTabs: pinned, favorites: favorites,
                                   lastUpdated: newest.map(CloudProfileDeletion.date(millis:)),
                                   arcCopies: copies.mergedSameProfile + copies.removedEmpty)
    }

    /// Profiles with a live record, and profiles a live space names.
    func profiles(_ wires: [String: SyncWireRecord]) -> [CloudProfile] {
        var ids = Set(records.compactMap { name, payload -> UUID? in
            guard payload.isAlive, payload.kind == .profile else { return nil }
            return SyncRecordKind.parse(recordName: name)?.id
        })
        ids.formUnion(spaces.map(\.profileID))
        return ids.map { id in
            let profile = store.profile(withID: id) ?? Profile.recovered(id, from: [])
            let own = spaces.filter { $0.profileID == id }.map {
                CloudSpace(id: $0.id, name: $0.name, pinnedTabs: SidebarTree.leaves(store.content(for: $0.id).pinned).count)
            }
            return CloudProfile(profile: profile, spaces: own, lastEdited: CloudProfileDeletion.lastEdited(of: id, in: wires))
        }
        .sorted { a, b in
            let order = a.profile.name.localizedStandardCompare(b.profile.name)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }
}

extension CloudSidebarDetection {
    /// What a look found in these records (already cleaned the T-03 way):
    /// a sidebar when one live space projects, otherwise empty.
    @MainActor
    static func of(accountID: String, records: [String: SyncWireRecord]) -> CloudSidebarDetection {
        let projection = CloudProjection(records.mapValues(\.payload))
        let summary = projection.summary
        guard summary.spaces > 0 else { return .empty(accountID: accountID) }
        return .found(CloudSidebarFound(accountID: accountID, records: records.values.sorted { $0.recordName < $1.recordName },
                                        summary: summary, profiles: projection.profiles(records)))
    }
}

/// Exactly what deleting one profile from iCloud changes, worked out from
/// the records a look read (docs/SYNC-RUNTIME.md):
///
/// - marked deleted: the profile's record, its spaces with their styles, the
///   rows in those spaces (folders with what is in them), its favorites and
///   its Boosts, as deleting the profile on a Mac that syncs does;
/// - moved: the rows of a space that has a copy imported from the same Arc
///   space in a profile that stays go to that copy (the one holding the most
///   rows), as the Arc copy repair would; only the space goes. 608's installs
///   gave every copy the same rows and favorites, kept in one place, so the
///   favorites then go to the profile taking the most rows, one per address;
/// - left as they are: everything of other profiles, and rows this version
///   can't place (an unknown parent, a folder cycle).
public struct CloudProfileDeletion: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case delete
        /// To another space: into its pinned section (`topLevel`), or along with the folder it is in.
        case move(toSpace: Space.ID, topLevel: Bool)
        /// A favorite, to another profile's favorites.
        case moveFavorite(toProfile: Profile.ID)
    }

    public var profileID: Profile.ID
    /// Every record touched, as read: the backup holds these.
    public var fetched: [String: SyncWireRecord]
    public var changes: [String: Change]
    /// The profile's spaces in iCloud.
    public var spaces: Int
    /// Pinned tabs and splits marked deleted, and moved to copies.
    public var deletedTabs: Int
    public var movedTabs: Int
    public var deletedFavorites: Int
    public var movedFavorites: Int
    /// Profiles whose spaces take moved rows.
    public var receivingProfiles: [Profile.ID]

    /// Nil when iCloud holds nothing live of the profile.
    public init?(profileID: Profile.ID, in records: [String: SyncWireRecord]) {
        let index = Index(records)
        let doomed = Set(index.spaceProfile.filter { $0.value == profileID }.keys)
        var twins: [Space.ID: Space.ID] = [:]
        for space in doomed {
            guard let source = index.spaceSource[space] else { continue }
            let copies = index.spaceSource.filter { $0.value == source && !doomed.contains($0.key) }.map(\.key)
            twins[space] = copies.max { (index.rows[$0, default: 0], $1.uuidString) < (index.rows[$1, default: 0], $0.uuidString) }
        }
        var changes: [String: Change] = [:]
        var deletedTabs = 0
        var movedTabs = 0
        var moved: [Profile.ID: Int] = [:]
        var favorites: [(name: String, url: String?)] = []
        for (name, wire) in index.alive {
            guard let (kind, id) = SyncRecordKind.parse(recordName: name) else { continue }
            let values = wire.payload.values
            switch kind {
            case .profile where id == profileID, .space where doomed.contains(id), .spaceStyle where doomed.contains(id):
                changes[name] = .delete
            case .boost where Index.uuid(values["profileID"]) == profileID:
                changes[name] = .delete
            case .item where index.favoriteOwner[id] == profileID:
                favorites.append((name, values["url"]?.stringValue))
            case .item:
                guard let home = index.homes[id], doomed.contains(home.space) else { continue }
                let tabs = ["tab", "split"].contains(values["type"]?.stringValue ?? "") ? 1 : 0
                if let twin = twins[home.space] {
                    changes[name] = .move(toSpace: twin, topLevel: home.topLevel)
                    movedTabs += tabs
                    if let owner = index.spaceProfile[twin] { moved[owner, default: 0] += 1 }
                } else {
                    changes[name] = .delete
                    deletedTabs += tabs
                }
            default:
                continue
            }
        }
        let receiver = moved.max { ($0.value, $1.key.uuidString) < ($1.value, $0.key.uuidString) }?.key
        var addresses = Set(index.favoriteOwner.filter { $0.value == receiver }.compactMap { index.favoriteKeys[$0.key] })
        var movedFavorites = 0
        for favorite in favorites.sorted(by: { $0.name < $1.name }) {
            let key = favorite.url.flatMap(URL.init(string:)).map(BookmarkImportPlan.key)
            if let receiver, key.map({ addresses.insert($0).inserted }) ?? true {
                changes[favorite.name] = .moveFavorite(toProfile: receiver)
                movedFavorites += 1
            } else {
                changes[favorite.name] = .delete
            }
        }
        guard !changes.isEmpty else { return nil }
        self.profileID = profileID
        deletedFavorites = favorites.count - movedFavorites
        self.movedFavorites = movedFavorites
        self.changes = changes
        fetched = records.filter { changes[$0.key] != nil }
        spaces = doomed.count
        self.deletedTabs = deletedTabs
        self.movedTabs = movedTabs
        receivingProfiles = moved.keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// What iCloud gets, in upload order: rows first and the profile last,
    /// so a delete cut short leaves a profile with fewer rows, never rows
    /// without their space. Every stamp comes from `clock`, which must have
    /// seen the records' stamps, so the change wins over each of them.
    public func writes(clock: inout HybridLogicalClock, now: Date) -> [SyncWireRecord] {
        let order: [SyncRecordKind] = [.item, .boost, .spaceStyle, .space, .profile]
        func rank(_ name: String) -> Int {
            SyncRecordKind.parse(recordName: name).flatMap { order.firstIndex(of: $0.kind) } ?? order.count
        }
        return changes.keys.sorted { (rank($0), $0) < (rank($1), $1) }.compactMap { name in
            guard var wire = fetched[name], let change = changes[name] else { return nil }
            wire.payload = Self.applying(change, to: wire.payload) { clock.tick(now: now) }
            return wire
        }
    }

    /// A record with the change made the way sync makes it: a tombstone, or
    /// a newer `parent` and `space`.
    static func applying(_ change: Change, to payload: SyncRecordPayload, stamp: () -> SyncStamp) -> SyncRecordPayload {
        var payload = payload
        switch change {
        case .delete:
            payload.tombstone = stamp()
        case .move(let space, let topLevel):
            if topLevel {
                payload.fields["parent"] = SyncField(value: .string(SidebarSyncProjection.Parent.pinned(space).key), stamp: stamp())
            }
            payload.fields["space"] = SyncField(value: .string(space.uuidString.lowercased()), stamp: stamp())
        case .moveFavorite(let profile):
            payload.fields["parent"] = SyncField(value: .string(SidebarSyncProjection.Parent.favorites(profile).key), stamp: stamp())
        }
        return payload
    }

    /// The newest live edit to the profile, its spaces, their rows or its favorites.
    static func lastEdited(of profileID: Profile.ID, in records: [String: SyncWireRecord]) -> Date? {
        guard let own = CloudProfileDeletion(profileID: profileID, in: records) else { return nil }
        return own.fetched.values.compactMap(\.payload.latestStamp).map(\.millis).max().map(date(millis:))
    }

    static func date(millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// The live records, and where each row shows: through its parent, as the
    /// projection places it (an orphan by its `space`), never past a cycle.
    private struct Index {
        var alive: [String: SyncWireRecord] = [:]
        var spaceProfile: [Space.ID: Profile.ID] = [:]
        var spaceSource: [Space.ID: String] = [:]
        var homes: [UUID: (space: Space.ID, topLevel: Bool)] = [:]
        var rows: [Space.ID: Int] = [:]
        /// Favorites (tabs whose parent is a profile's favorites), and their addresses.
        var favoriteOwner: [UUID: Profile.ID] = [:]
        var favoriteKeys: [UUID: String] = [:]

        static func uuid(_ value: SyncValue?) -> UUID? {
            value?.stringValue.flatMap(UUID.init(uuidString:))
        }

        init(_ records: [String: SyncWireRecord]) {
            var items: [UUID: [String: SyncValue]] = [:]
            for (name, wire) in records where wire.payload.isAlive {
                guard let (kind, id) = SyncRecordKind.parse(recordName: name), kind == wire.payload.kind else { continue }
                alive[name] = wire
                let values = wire.payload.values
                switch kind {
                case .space:
                    if let profile = Self.uuid(values["profileID"]) { spaceProfile[id] = profile }
                    if let source = values["arcSourceID"]?.stringValue { spaceSource[id] = source }
                case .item:
                    items[id] = values
                default:
                    break
                }
            }
            spaceSource = spaceSource.filter { spaceProfile[$0.key] != nil }
            let spaces = spaceProfile
            func home(_ id: UUID, depth: Int) -> (space: Space.ID, topLevel: Bool)? {
                guard depth < 64, let values = items[id] else { return nil }
                let isTab = values["type"]?.stringValue == "tab"
                switch values["parent"]?.stringValue.flatMap(SidebarSyncProjection.Parent.init(key:)) {
                case .pinned(let space)? where spaces[space] != nil:
                    return (space, true)
                case .folder(let folder)? where items[folder]?["type"]?.stringValue == "folder":
                    return home(folder, depth: depth + 1).map { ($0.space, false) }
                case .favorites? where isTab:
                    return nil
                default:
                    return Self.uuid(values["space"]).flatMap { spaces[$0] != nil ? ($0, true) : nil }
                }
            }
            for (id, values) in items where values["type"]?.stringValue == "tab" {
                guard case .favorites(let profile)? = values["parent"]?.stringValue.flatMap(SidebarSyncProjection.Parent.init(key:)) else { continue }
                favoriteOwner[id] = profile
                favoriteKeys[id] = values["url"]?.stringValue.flatMap(URL.init(string:)).map(BookmarkImportPlan.key)
            }
            for id in items.keys {
                guard let found = home(id, depth: 0) else { continue }
                homes[id] = found
                rows[found.space, default: 0] += 1
            }
        }
    }
}

/// What Settings › Profiles says about iCloud, in the Account pane's words;
/// kept out of the views so tests can read it.
public enum ProfileCloudText {
    public static let inICloud = "On this Mac and in iCloud"
    public static let onlyHere = "Only on this Mac"
    public static let cloudOnlySection = "In iCloud only"
    public static let syncOffNote = "Sync Sidebar is off, so changes here don't reach iCloud and iCloud's don't reach this Mac."
    public static let syncOnNote = "Sync Sidebar keeps it the same here and in iCloud."
    public static let cloudOnlyNote = "Not on this Mac. Its Spaces, pinned tabs and favorites are in iCloud, from another Mac or an earlier install."

    public static let deleteFromICloud = "Delete from iCloud"
    public static let deleteFromThisMac = "Delete from This Mac"
    public static let deleteFromBoth = "Delete from This Mac and iCloud"

    public static func status(_ presence: ProfileCloudPresence) -> String {
        switch presence {
        case .inICloud: return inICloud
        case .onlyHere: return onlyHere
        case .looking(nil): return "Looking at iCloud…"
        case .looking(let count?): return "Looking at iCloud… \(count.formatted()) items"
        case .unknown(let message): return message
        }
    }

    private static func part(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }

    /// "13 spaces and 2,104 pinned tabs".
    public static func counts(spaces: Int, pinnedTabs: Int) -> String {
        part(spaces, "space", "spaces") + " and " + part(pinnedTabs, "pinned tab", "pinned tabs")
    }

    /// "13 spaces and 2,104 pinned tabs in iCloud, last edited 3 days ago."
    public static func summary(_ profile: CloudProfile, now: Date = Date()) -> String {
        var text = counts(spaces: profile.spaces.count, pinnedTabs: profile.pinnedTabs) + " in iCloud"
        if let edited = profile.lastEdited {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            text += ", last edited " + formatter.localizedString(for: min(edited, now), relativeTo: now)
        }
        return text + "."
    }

    public static func deleteFromICloudTitle(_ name: String) -> String {
        "Delete “\(name)” from iCloud?"
    }

    public static func deleteTitle(_ name: String) -> String {
        "Delete “\(name)”?"
    }

    private static func list(_ parts: [String]) -> String {
        parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? ""
    }

    /// "Its 13 spaces and 2,104 pinned tabs are removed from iCloud.", and
    /// where moved rows go.
    static func removal(_ plan: CloudProfileDeletion, receiving: [String]) -> String {
        let gone = [(plan.spaces, "space", "spaces"), (plan.deletedTabs, "pinned tab", "pinned tabs"), (plan.deletedFavorites, "favorite", "favorites")]
            .filter { $0.0 > 0 }.map { part($0.0, $0.1, $0.2) }
        var text = gone.isEmpty ? "It is removed from iCloud." : "Its \(list(gone)) \(gone == ["1 space"] ? "is" : "are") removed from iCloud."
        let moving = [(plan.movedTabs, "pinned tab", "pinned tabs"), (plan.movedFavorites, "favorite", "favorites")]
            .filter { $0.0 > 0 }.map { part($0.0, $0.1, $0.2) }
        if !moving.isEmpty {
            let names = receiving.map { "“\($0)”" }
            let single = moving.count == 1 && (plan.movedTabs + plan.movedFavorites) == 1
            text += " \(list(moving)) \(single ? "moves" : "move") to \(names.isEmpty ? "another profile" : list(names)), which \(names.count > 1 ? "have" : "has") copies of the same Arc spaces."
        }
        return text
    }

    /// The confirmation for a profile only in iCloud.
    public static func deleteFromICloudMessage(_ plan: CloudProfileDeletion, receiving: [String], syncOn: Bool, backupFolder: String, changed: Bool = false) -> String {
        (changed ? "It changed in iCloud since you looked. " : "") + removal(plan, receiving: receiving)
            + (syncOn ? " Sync Sidebar is on, so this Mac and other Macs that sync lose them too." : " Other Macs that sync lose them too. This Mac is not changed.")
            + " A copy of what is deleted is saved first in \(backupFolder)."
    }

    /// "Delete from This Mac": one line.
    public static let thisMacConsequence = "Its Spaces and their tabs go from this Mac. iCloud keeps it."

    /// "Delete from This Mac and iCloud": one line, then the backup.
    public static func bothConsequence(_ plan: CloudProfileDeletion, receiving: [String], syncOn: Bool, backupFolder: String, changed: Bool = false) -> String {
        (changed ? "It changed in iCloud since you looked. " : "")
            + (syncOn ? "Sync Sidebar is on, so deleting it here deletes it from iCloud and other Macs that sync. " : "It also goes from iCloud and other Macs that sync. ")
            + removal(plan, receiving: receiving) + " A copy of iCloud's is saved first in \(backupFolder)."
    }

    /// A profile of this Mac whose place in iCloud isn't known: only this Mac changes.
    public static func localDeleteMessage(_ presence: ProfileCloudPresence) -> String {
        let base = "Its spaces and their tabs are deleted too. This can't be undone."
        switch presence {
        case .looking: return base + " iCloud is still being checked, so only this Mac changes."
        case .unknown: return base + " ReArc couldn't check iCloud, so only this Mac changes."
        case .inICloud, .onlyHere: return base
        }
    }
}
