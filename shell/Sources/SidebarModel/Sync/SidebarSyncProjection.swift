import Foundation

/// The synced values of one record, before stamping.
public struct SyncRecordBody: Equatable, Sendable {
    public var kind: SyncRecordKind
    public var values: [String: SyncValue]

    public init(kind: SyncRecordKind, values: [String: SyncValue]) {
        self.kind = kind
        self.values = values
    }
}

/// Maps the sidebar to sync records and back (docs/SYNC-RECORDS.md).
///
/// Synced: profiles, spaces (with their themes), favorites, pinned tabs,
/// folders, splits in Favorites or Pinned, and Boosts. Not synced: Today
/// (unpinned) tabs, easels, selection, archive, closed-tab stack, Little Arc
/// windows and other per-Mac state; `apply` leaves those where they are.
///
/// `apply` is a pure function of the merged records plus the local-only
/// state, and rescues rows whose parent is gone or forms a cycle the same way
/// on every Mac, so devices holding the same records show the same sidebar.
public enum SidebarSyncProjection {
    static let tabFields = ["title", "url", "customTitle", "savedURL", "savedTitle"]
    /// Per-Mac tab state kept out of records: it changes on every visit.
    static let localTabKeys: Set<String> = ["lastActiveAt", "isUnread", "faviconToken"]

    enum Parent: Hashable {
        case favorites(UUID)
        case pinned(UUID)
        case folder(UUID)

        var key: String {
            switch self {
            case .favorites(let id): return "favorites:\(id.uuidString.lowercased())"
            case .pinned(let id): return "pinned:\(id.uuidString.lowercased())"
            case .folder(let id): return "folder:\(id.uuidString.lowercased())"
            }
        }

        init?(key: String) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            switch parts[0] {
            case "favorites": self = .favorites(id)
            case "pinned": self = .pinned(id)
            case "folder": self = .folder(id)
            default: return nil
            }
        }
    }

    // MARK: - Extract

    public static func extract(_ snapshot: SidebarSnapshot) -> [String: SyncRecordBody] {
        var records: [String: SyncRecordBody] = [:]
        for (index, profile) in snapshot.profiles.enumerated() {
            var values = objectFields(profile, dropping: ["id"])
            let library = snapshot.boostLibrariesByProfileID[profile.id]
            values["boostsEnabled"] = .bool(library?.masterEnabled ?? true)
            records[SyncRecordKind.profile.recordName(for: profile.id)] = SyncRecordBody(kind: .profile, values: values)

            let container = snapshot.topAppsContainersByProfileID[profile.id]
                ?? (index == 0 ? snapshot.topAppsContainer : nil)
            let favorites = (container?.childIDs ?? []).compactMap { snapshot.tabsByID[$0] }
            let ranks = SyncRanks.normalized(favorites.map(\.sortRank))
            for (tab, rank) in zip(favorites, ranks) {
                records[SyncRecordKind.item.recordName(for: tab.id)] =
                    tabBody(tab, parent: .favorites(profile.id), spaceID: nil, rank: rank)
            }

            for package in library?.packages ?? [] {
                var boost: [String: SyncValue] = ["profileID": .string(profile.id.uuidString)]
                boost["package"] = (try? SyncValue.encoding(package)) ?? .null
                boost["installation"] = library?.installation(for: package.manifest.id).map(installationValue) ?? .null
                records[SyncRecordKind.boost.recordName(for: package.manifest.id)] = SyncRecordBody(kind: .boost, values: boost)
            }
        }

        let spaceRanks = SyncRanks.normalized(snapshot.spaces.map(\.sortRank))
        for (space, rank) in zip(snapshot.spaces, spaceRanks) {
            var values = objectFields(space, dropping: ["id"])
            values["sortRank"] = .string(rank)
            records[SyncRecordKind.space.recordName(for: space.id)] = SyncRecordBody(kind: .space, values: values)
            var visited = Set<UUID>()
            let pinned = (snapshot.spaceContainers[space.id]?.pinned.childIDs ?? [])
                .compactMap { resolve($0, in: snapshot, visited: &visited) }
            extractEntries(pinned, parent: .pinned(space.id), spaceID: space.id, into: &records)
        }
        return records
    }

    private static func extractEntries(
        _ entries: [SidebarEntry],
        parent: Parent,
        spaceID: UUID,
        into records: inout [String: SyncRecordBody]
    ) {
        let synced = entries.filter { if case .easel = $0 { return false } else { return true } }
        let ranks = SyncRanks.normalized(synced.map(rank(of:)))
        for (entry, rank) in zip(synced, ranks) {
            let name = SyncRecordKind.item.recordName(for: entry.id)
            switch entry {
            case .tab(let tab):
                records[name] = tabBody(tab, parent: parent, spaceID: spaceID, rank: rank)
            case .split(let split):
                var values = splitValues(split)
                values.merge(placement(type: "split", parent: parent, spaceID: spaceID, rank: rank)) { $1 }
                records[name] = SyncRecordBody(kind: .item, values: values)
            case .folder(let folder):
                var values = placement(type: "folder", parent: parent, spaceID: spaceID, rank: rank)
                values["title"] = .string(folder.title)
                records[name] = SyncRecordBody(kind: .item, values: values)
                extractEntries(folder.children, parent: .folder(folder.id), spaceID: spaceID, into: &records)
            case .easel:
                break
            }
        }
    }

    private static func tabBody(_ tab: Tab, parent: Parent, spaceID: UUID?, rank: String) -> SyncRecordBody {
        var values = placement(type: "tab", parent: parent, spaceID: spaceID, rank: rank)
        values["title"] = .string(tab.title)
        values["url"] = .string(tab.url.absoluteString)
        values["customTitle"] = tab.customTitle.map(SyncValue.string) ?? .null
        values["savedURL"] = tab.savedURL.map { .string($0.absoluteString) } ?? .null
        values["savedTitle"] = tab.savedTitle.map(SyncValue.string) ?? .null
        return SyncRecordBody(kind: .item, values: values)
    }

    private static func placement(type: String, parent: Parent, spaceID: UUID?, rank: String) -> [String: SyncValue] {
        [
            "type": .string(type),
            "parent": .string(parent.key),
            "space": spaceID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "sortRank": .string(rank),
        ]
    }

    // MARK: - Apply

    /// The local snapshot with its synced parts replaced by `records` (alive ones).
    public static func apply(_ records: [String: SyncRecordPayload], onto snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var profileValues: [UUID: [String: SyncValue]] = [:]
        var spaceValues: [UUID: [String: SyncValue]] = [:]
        var items: [UUID: ItemRecord] = [:]
        var boosts: [UUID: [String: SyncValue]] = [:]
        for (name, payload) in records where payload.isAlive {
            guard let (kind, id) = SyncRecordKind.parse(recordName: name) else { continue }
            switch kind {
            case .profile: profileValues[id] = payload.values
            case .space: spaceValues[id] = payload.values
            case .boost: boosts[id] = payload.values
            case .item:
                guard let parentKey = payload.values["parent"]?.stringValue, let parent = Parent(key: parentKey) else { continue }
                items[id] = ItemRecord(
                    id: id,
                    name: name,
                    values: payload.values,
                    parent: parent,
                    parentStamp: payload.fields["parent"]?.stamp
                )
            }
        }

        var out = snapshot
        let local = LocalIndex(snapshot)

        // Profiles: local order first, then new ones by id.
        var profiles: [Profile] = []
        let orderedProfileIDs = snapshot.profiles.map(\.id).filter { profileValues[$0] != nil }
            + profileValues.keys.filter { id in !snapshot.profiles.contains { $0.id == id } }.sorted { $0.uuidString < $1.uuidString }
        for id in orderedProfileIDs {
            var values = profileValues[id] ?? [:]
            values["boostsEnabled"] = nil
            let base = snapshot.profiles.first { $0.id == id }.map { objectFields($0, dropping: []) } ?? [:]
            if let profile: Profile = decode(base: base, overlay: values, id: id) { profiles.append(profile) }
        }
        if profiles.isEmpty { profiles = snapshot.profiles }
        let profileIDs = Set(profiles.map(\.id))

        var spaces: [Space] = []
        for (id, values) in spaceValues {
            let base = snapshot.spaces.first { $0.id == id }.map { objectFields($0, dropping: []) } ?? [:]
            if var space: Space = decode(base: base, overlay: values, id: id) {
                if !profileIDs.contains(space.profileID) { space.profileID = profiles[0].id }
                spaces.append(space)
            }
        }
        spaces.sort { ($0.sortRank, $0.id.uuidString) < ($1.sortRank, $1.id.uuidString) }
        if spaces.isEmpty {
            spaces = snapshot.spaces.filter { profileIDs.contains($0.profileID) }
            if spaces.isEmpty { spaces = [Space(name: "Personal", profileID: profiles[0].id)] }
        }
        let spaceIDs = Set(spaces.map(\.id))
        let firstSpaceID = spaces[0].id

        // Effective parents: orphans and cycle members go to their space's
        // pinned root (SYNC-DESIGN §5.3 rules 3 and 4).
        func pinnedRoot(for item: ItemRecord) -> Parent {
            if let text = item.values["space"]?.stringValue, let id = UUID(uuidString: text), spaceIDs.contains(id) {
                return .pinned(id)
            }
            return .pinned(firstSpaceID)
        }
        var parents: [UUID: Parent] = [:]
        for item in items.values {
            switch item.parent {
            case .favorites(let pid):
                if item.type != "tab" { parents[item.id] = pinnedRoot(for: item) }
                else { parents[item.id] = .favorites(profileIDs.contains(pid) ? pid : profiles[0].id) }
            case .pinned(let sid):
                parents[item.id] = spaceIDs.contains(sid) ? .pinned(sid) : pinnedRoot(for: item)
            case .folder(let fid):
                parents[item.id] = items[fid]?.type == "folder" ? .folder(fid) : pinnedRoot(for: item)
            }
        }
        breakCycles(items: items, parents: &parents, root: pinnedRoot)

        var children: [Parent: [ItemRecord]] = [:]
        for item in items.values { children[parents[item.id]!, default: []].append(item) }
        for key in children.keys {
            children[key]!.sort { ($0.rank, $0.name) < ($1.rank, $1.name) }
        }
        var claimed = Set(items.keys)
        for item in items.values where item.type == "split" {
            if case .array(let tabs)? = item.values["tabs"] {
                for case .object(let fields) in tabs {
                    if let text = fields["id"]?.stringValue, let id = UUID(uuidString: text) { claimed.insert(id) }
                }
            }
        }

        // Local easels keep their place among the synced rows by rank.
        var easels: [Parent: [SidebarEntry]] = [:]
        for (parent, ref) in local.easels {
            let target: Parent
            switch parent {
            case .folder(let fid) where items[fid]?.type == "folder": target = parent
            case .pinned(let sid) where spaceIDs.contains(sid): target = parent
            default: target = .pinned(local.spaceOfEasel[ref.id].flatMap { spaceIDs.contains($0) ? $0 : nil } ?? firstSpaceID)
            }
            easels[target, default: []].append(.easel(ref))
        }

        func entries(under parent: Parent) -> [SidebarEntry] {
            var built: [SidebarEntry] = []
            for item in children[parent] ?? [] {
                if let entry = makeEntry(item, local: local, children: entries(under:)) { built.append(entry) }
            }
            for easel in easels[parent] ?? [] {
                let rank = rank(of: easel)
                let index = built.firstIndex { self.rank(of: $0) > rank } ?? built.count
                built.insert(easel, at: index)
            }
            return built
        }

        // Today stays local; a deleted space's Today rows move to the first space.
        var today: [UUID: [SidebarEntry]] = [:]
        for space in snapshot.spaces {
            let target = spaceIDs.contains(space.id) ? space.id : firstSpaceID
            let rows = local.today[space.id, default: []].filter { !overlaps($0, claimed) }
            today[target, default: []].append(contentsOf: rows)
        }

        var tabsByID: [UUID: Tab] = [:]
        var splitsByID: [UUID: SplitViewItem] = [:]
        var foldersByID: [UUID: SidebarFolderRecord] = [:]
        var easelRefsByID: [UUID: SidebarEaselRef] = [:]
        func ingest(_ entry: SidebarEntry) {
            switch entry {
            case .tab(let tab): tabsByID[tab.id] = tab
            case .split(let split):
                splitsByID[split.id] = split
                for tab in split.tabs { tabsByID[tab.id] = tab }
            case .easel(let ref): easelRefsByID[ref.id] = ref
            case .folder(let folder):
                foldersByID[folder.id] = SidebarFolderRecord(folder)
                folder.children.forEach(ingest)
            }
        }

        var topApps: [Profile.ID: ItemContainerRecord] = [:]
        for profile in profiles {
            let favorites = entries(under: .favorites(profile.id)).filter {
                if case .tab = $0 { return true } else { return false }
            }
            favorites.forEach(ingest)
            topApps[profile.id] = ItemContainerRecord(
                id: local.topAppsContainerID[profile.id] ?? UUID(),
                kind: .topApps,
                childIDs: favorites.map(\.id)
            )
        }
        var containers: [Space.ID: SidebarSnapshot.SpaceContainerBundle] = [:]
        for space in spaces {
            let pinned = entries(under: .pinned(space.id))
            let rows = today[space.id] ?? []
            pinned.forEach(ingest)
            rows.forEach(ingest)
            containers[space.id] = SidebarSnapshot.SpaceContainerBundle(
                pinned: ItemContainerRecord(id: space.pinnedContainerID, kind: .spaceItems(spaceID: space.id, section: .pinned), childIDs: pinned.map(\.id)),
                unpinned: ItemContainerRecord(
                    id: space.unpinnedContainerID,
                    kind: .spaceItems(spaceID: space.id, section: .unpinned),
                    childIDs: rows.map(\.id),
                    unpinnedShared: space.unpinnedShared
                )
            )
        }

        var libraries: [Profile.ID: ProfileBoostLibrary] = [:]
        for profile in profiles {
            var library = snapshot.boostLibrariesByProfileID[profile.id] ?? BoostLibraryOps.empty(for: profile.id)
            if case .bool(let enabled)? = profileValues[profile.id]?["boostsEnabled"] { library.masterEnabled = enabled }
            var pairs: [(BoostPackage, BoostInstallation)] = []
            for (id, values) in boosts where values["profileID"]?.stringValue.flatMap(UUID.init(uuidString:)) == profile.id {
                guard let package = try? values["package"]?.decoded(as: BoostPackage.self), package.manifest.id == id else { continue }
                let installation = values["installation"].flatMap(installation(from:))
                    ?? BoostInstallation(packageID: id, order: pairs.count)
                pairs.append((package, installation))
            }
            pairs.sort { ($0.1.order, $0.0.manifest.id.uuidString) < ($1.1.order, $1.0.manifest.id.uuidString) }
            library.packages = pairs.map(\.0)
            library.installations = pairs.map(\.1)
            libraries[profile.id] = library
        }

        out.profiles = profiles
        out.spaces = spaces
        out.topAppsContainersByProfileID = topApps
        out.topAppsContainer = topApps[profiles[0].id]!
        out.spaceContainers = containers
        out.tabsByID = tabsByID
        out.splitsByID = splitsByID
        out.foldersByID = foldersByID
        out.easelRefsByID = easelRefsByID
        out.boostLibrariesByProfileID = libraries
        out.lastActiveSpaceByProfile = snapshot.lastActiveSpaceByProfile.filter { profileIDs.contains($0.key) && spaceIDs.contains($0.value) }
        out.selectionBySpace = snapshot.selectionBySpace.filter { spaceIDs.contains($0.key) }
        out.expandedFolderIDs = snapshot.expandedFolderIDs.filter { foldersByID[$0] != nil }
        if !spaceIDs.contains(out.activeSpaceID) { out.activeSpaceID = firstSpaceID }
        if !profileIDs.contains(out.activeProfileID) { out.activeProfileID = profiles[0].id }
        return out
    }

    /// A fresh install: an empty sidebar or the untouched starter sidebar
    /// (`SidebarStore.sample()`). It adopts the iCloud sidebar on first sync
    /// instead of adding a second copy of the starter rows to it.
    public static func isPristine(_ snapshot: SidebarSnapshot) -> Bool {
        starterPrints.contains(StarterPrint(extract(snapshot)))
    }

    private static let starterPrints: [StarterPrint] = [
        StarterPrint(extract(SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID())).makeSnapshot())),
        StarterPrint(extract(SidebarStore.sample().makeSnapshot())),
    ]

    /// The id-free shape of the synced rows: what makes two starter sidebars equal.
    private struct StarterPrint: Equatable {
        var counts: [SyncRecordKind: Int] = [:]
        var texts: [String] = []

        init(_ records: [String: SyncRecordBody]) {
            for body in records.values {
                counts[body.kind, default: 0] += 1
                let text = body.values["url"]?.stringValue ?? body.values["name"]?.stringValue ?? body.values["title"]?.stringValue
                if let text { texts.append("\(body.kind.rawValue):\(text)") }
            }
            texts.sort()
        }
    }

    /// False for a record this version cannot turn into a sidebar row (an
    /// unknown item type, or values a newer ReArc wrote). Such records are
    /// left alone: never shown, never tombstoned for being absent here.
    public static func canMaterialize(_ name: String, _ payload: SyncRecordPayload) -> Bool {
        guard let (kind, id) = SyncRecordKind.parse(recordName: name) else { return false }
        let values = payload.values
        switch kind {
        case .profile:
            var fields = values
            fields["boostsEnabled"] = nil
            let profile: Profile? = decode(base: [:], overlay: fields, id: id)
            return profile != nil
        case .space:
            let space: Space? = decode(base: [:], overlay: values, id: id)
            return space != nil
        case .boost:
            return (try? values["package"]?.decoded(as: BoostPackage.self)) != nil
        case .item:
            guard values["parent"]?.stringValue.flatMap(Parent.init(key:)) != nil else { return false }
            switch values["type"]?.stringValue {
            case "tab"?:
                return values["url"]?.stringValue.flatMap(URL.init(string:)) != nil
            case "folder"?:
                return true
            case "split"?:
                return makeSplit(id: id, values: values, rank: "") != nil
            default:
                return false
            }
        }
    }

    // MARK: - Helpers

    // UUID-keyed dictionaries encode as arrays in hash order, so they are
    // written as string-keyed objects: equal data must give equal values.

    static func splitValues(_ split: SplitViewItem) -> [String: SyncValue] {
        [
            "orientation": (try? SyncValue.encoding(split.orientation)) ?? .null,
            "focusTabID": .string(split.focusTabID.uuidString),
            "widthFactors": .object(Dictionary(uniqueKeysWithValues: split.widthFactors.map { ($0.key.uuidString, .number($0.value)) })),
            "memberPlacements": .object(Dictionary(uniqueKeysWithValues: split.memberPlacements.map {
                ($0.key.uuidString, (try? SyncValue.encoding($0.value)) ?? .null)
            })),
            "tabs": .array(split.tabs.map { .object(objectFields($0, dropping: localTabKeys)) }),
        ]
    }

    static func makeSplit(id: UUID, values: [String: SyncValue], rank: String) -> SplitViewItem? {
        guard let tabs = try? values["tabs"]?.decoded(as: [Tab].self), (2 ... 4).contains(tabs.count),
              let orientation = try? values["orientation"]?.decoded(as: SplitLayoutOrientation.self) else { return nil }
        var factors: [Tab.ID: Double] = [:]
        for (key, value) in values["widthFactors"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), case .number(let factor) = value { factors[id] = factor }
        }
        var placements: [Tab.ID: TabPlacement] = [:]
        for (key, value) in values["memberPlacements"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let placement = try? value.decoded(as: TabPlacement.self) { placements[id] = placement }
        }
        let focus = values["focusTabID"]?.stringValue.flatMap(UUID.init(uuidString:)).flatMap { focus in
            tabs.contains { $0.id == focus } ? focus : nil
        }
        var split = SplitViewItem(id: id, orientation: orientation, focusTabID: focus, tabs: tabs, memberPlacements: placements, sortRank: rank)
        // As written, not re-normalized: re-normalizing would drift the values a little on every sync.
        if Set(factors.keys) == Set(tabs.map(\.id)) { split.widthFactors = factors }
        return split
    }

    static func installationValue(_ installation: BoostInstallation) -> SyncValue {
        .object([
            "packageID": .string(installation.packageID.uuidString),
            "enabled": .bool(installation.enabled),
            "order": .number(Double(installation.order)),
            "allowPrivate": .bool(installation.allowPrivate),
            "spacePolicy": .object(Dictionary(uniqueKeysWithValues: installation.spacePolicy.map { ($0.key.uuidString, .string($0.value.rawValue)) })),
        ])
    }

    static func installation(from value: SyncValue) -> BoostInstallation? {
        guard let fields = value.objectValue,
              let packageID = fields["packageID"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
        var policy: [Space.ID: BoostSpacePolicy] = [:]
        for (key, raw) in fields["spacePolicy"]?.objectValue ?? [:] {
            if let id = UUID(uuidString: key), let value = raw.stringValue.flatMap(BoostSpacePolicy.init(rawValue:)) { policy[id] = value }
        }
        func number(_ key: String) -> Double? { if case .number(let n)? = fields[key] { return n } else { return nil } }
        func bool(_ key: String) -> Bool? { if case .bool(let b)? = fields[key] { return b } else { return nil } }
        return BoostInstallation(
            packageID: packageID,
            enabled: bool("enabled") ?? true,
            order: Int(number("order") ?? 0),
            allowPrivate: bool("allowPrivate") ?? false,
            spacePolicy: policy
        )
    }

    struct ItemRecord {
        var id: UUID
        var name: String
        var values: [String: SyncValue]
        var parent: Parent
        var parentStamp: SyncStamp?

        var type: String { values["type"]?.stringValue ?? "tab" }
        var rank: String { values["sortRank"]?.stringValue ?? "" }
    }

    /// Local-only rows and per-Mac tab state, indexed from the snapshot.
    struct LocalIndex {
        var tabs: [UUID: Tab] = [:]
        /// Synced-kind rows as this Mac has them, for records it cannot read.
        var entries: [UUID: SidebarEntry] = [:]
        var today: [UUID: [SidebarEntry]] = [:]
        var easels: [(SidebarSyncProjection.Parent, SidebarEaselRef)] = []
        var spaceOfEasel: [UUID: UUID] = [:]
        var topAppsContainerID: [UUID: UUID] = [:]

        init(_ snapshot: SidebarSnapshot) {
            tabs = snapshot.tabsByID
            for split in snapshot.splitsByID.values {
                for tab in split.tabs { tabs[tab.id] = tab }
                entries[split.id] = .split(split)
            }
            for (id, tab) in snapshot.tabsByID { entries[id] = .tab(tab) }
            for (index, profile) in snapshot.profiles.enumerated() {
                topAppsContainerID[profile.id] = snapshot.topAppsContainersByProfileID[profile.id]?.id
                    ?? (index == 0 ? snapshot.topAppsContainer.id : nil)
            }
            for space in snapshot.spaces {
                var visited = Set<UUID>()
                let bundle = snapshot.spaceContainers[space.id]
                today[space.id] = (bundle?.unpinned.childIDs ?? []).compactMap {
                    SidebarSyncProjection.resolve($0, in: snapshot, visited: &visited)
                }
                let pinned = (bundle?.pinned.childIDs ?? []).compactMap {
                    SidebarSyncProjection.resolve($0, in: snapshot, visited: &visited)
                }
                collectEasels(pinned, parent: .pinned(space.id), spaceID: space.id)
            }
        }

        private mutating func collectEasels(_ entries: [SidebarEntry], parent: SidebarSyncProjection.Parent, spaceID: UUID) {
            for entry in entries {
                switch entry {
                case .easel(let ref):
                    easels.append((parent, ref))
                    spaceOfEasel[ref.id] = spaceID
                case .folder(let folder):
                    collectEasels(folder.children, parent: .folder(folder.id), spaceID: spaceID)
                default:
                    break
                }
            }
        }
    }

    private static func makeEntry(
        _ item: ItemRecord,
        local: LocalIndex,
        children: (Parent) -> [SidebarEntry]
    ) -> SidebarEntry? {
        switch item.type {
        case "folder":
            let title = item.values["title"]?.stringValue ?? "New Folder"
            return .folder(SidebarFolder(id: item.id, title: title, children: children(.folder(item.id)), sortRank: item.rank))
        case "split":
            guard var split = makeSplit(id: item.id, values: item.values, rank: item.rank) else { return local.entries[item.id] }
            split.tabs = split.tabs.map { tab in
                var copy = tab
                if let existing = local.tabs[tab.id] {
                    copy.lastActiveAt = existing.lastActiveAt
                    copy.isUnread = existing.isUnread
                }
                return copy
            }
            return .split(split)
        default:
            guard let urlText = item.values["url"]?.stringValue, let url = URL(string: urlText) else {
                return local.entries[item.id]
            }
            let isFavorite: Bool
            if case .favorites = item.parent { isFavorite = true } else { isFavorite = false }
            let existing = local.tabs[item.id]
            var tab = Tab(
                id: item.id,
                kind: isFavorite ? .favorite : .pinned,
                title: item.values["title"]?.stringValue ?? urlText,
                url: url,
                isUnread: existing?.isUnread ?? false,
                sortRank: item.rank,
                customTitle: item.values["customTitle"]?.stringValue,
                lastActiveAt: existing?.lastActiveAt ?? Date(),
                savedURL: item.values["savedURL"]?.stringValue.flatMap(URL.init(string:)),
                savedTitle: item.values["savedTitle"]?.stringValue
            )
            if isFavorite {
                tab.savedURL = nil
                tab.savedTitle = nil
            }
            return .tab(tab)
        }
    }

    /// Any folder chain that loops is cut where its most recent-but-earliest
    /// move landed: the member whose parent was written first goes to the root.
    private static func breakCycles(items: [UUID: ItemRecord], parents: inout [UUID: Parent], root: (ItemRecord) -> Parent) {
        for start in items.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var path: [UUID] = []
            var onPath = Set<UUID>()
            var cursor = start
            while case .folder(let next)? = parents[cursor] {
                path.append(cursor)
                onPath.insert(cursor)
                if onPath.contains(next) {
                    let cycle = path.drop { $0 != next }
                    let victim = cycle.min { lhs, rhs in
                        let a = items[lhs]?.parentStamp, b = items[rhs]?.parentStamp
                        if a != b { return (a ?? SyncStamp(millis: .min, device: "")) < (b ?? SyncStamp(millis: .min, device: "")) }
                        return lhs.uuidString < rhs.uuidString
                    }!
                    parents[victim] = root(items[victim]!)
                    break
                }
                cursor = next
            }
        }
    }

    private static func overlaps(_ entry: SidebarEntry, _ claimed: Set<UUID>) -> Bool {
        if claimed.contains(entry.id) { return true }
        if case .split(let split) = entry { return split.tabs.contains { claimed.contains($0.id) } }
        return false
    }

    static func resolve(_ id: UUID, in snapshot: SidebarSnapshot, visited: inout Set<UUID>) -> SidebarEntry? {
        guard visited.insert(id).inserted else { return nil }
        if let record = snapshot.foldersByID[id] {
            let children = record.childIDs.compactMap { resolve($0, in: snapshot, visited: &visited) }
            return .folder(SidebarFolder(id: record.id, title: record.title, children: children, sortRank: record.sortRank))
        }
        if let split = snapshot.splitsByID[id] { return .split(split) }
        if let easel = snapshot.easelRefsByID[id] { return .easel(easel) }
        if let tab = snapshot.tabsByID[id] { return .tab(tab) }
        return nil
    }

    static func rank(of entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.sortRank
        case .split(let split): return split.sortRank
        case .easel(let ref): return ref.sortRank
        case .folder(let folder): return folder.sortRank
        }
    }

    static func objectFields<T: Encodable>(_ value: T, dropping keys: Set<String>) -> [String: SyncValue] {
        guard case .object(var fields)? = try? SyncValue.encoding(value) else { return [:] }
        for key in keys { fields[key] = nil }
        return fields
    }

    private static func decode<T: Decodable>(base: [String: SyncValue], overlay: [String: SyncValue], id: UUID) -> T? {
        var fields = base
        fields.merge(overlay) { $1 }
        fields["id"] = .string(id.uuidString)
        return try? SyncValue.object(fields.filter { $0.value != .null }).decoded(as: T.self)
    }
}
