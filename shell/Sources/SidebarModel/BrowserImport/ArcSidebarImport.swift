import Foundation
import CryptoKit

/// Where an Arc profile's spaces and favorites go.
public enum ArcProfileTarget: Hashable, Sendable {
    case existing(Profile.ID)
    /// A new ReArc profile named after the Arc one.
    case newProfile
}

/// The import preview's choices (PROFILE-IMPORT §1.3).
public struct ArcImportChoices: Equatable, Sendable {
    /// Arc space ids to import.
    public var spaceIDs: Set<String>
    /// Today (unpinned) tabs too. Off by default: Arc archives them on its own.
    public var includeToday = false
    public var includeFavorites = true
    public var profileTargets: [ArcProfileRef: ArcProfileTarget]

    public init(spaceIDs: Set<String>, includeToday: Bool = false, includeFavorites: Bool = true,
                profileTargets: [ArcProfileRef: ArcProfileTarget] = [:]) {
        self.spaceIDs = spaceIDs
        self.includeToday = includeToday
        self.includeFavorites = includeFavorites
        self.profileTargets = profileTargets
    }
}

/// Counts for the preview and the toast.
public struct ArcImportSummary: Equatable, Sendable {
    public var spaces = 0
    public var pinnedTabs = 0
    public var folders = 0
    public var todayTabs = 0
    public var favorites = 0
    public var newProfiles = 0

    public init() {}

    public var isEmpty: Bool { spaces == 0 && favorites == 0 && pinnedTabs == 0 && folders == 0 && todayTabs == 0 }
}

/// Arc's sidebar plus the names of its profiles (Arc's `User Data/Local State`).
public struct ArcSidebarImport: Sendable {
    public var export: ArcSidebarExport
    /// Profile directory to the name Arc shows.
    public var profileNames: [String: String]

    public init(export: ArcSidebarExport, profileNames: [String: String] = [:]) {
        self.export = export
        self.profileNames = profileNames
    }

    /// Reads Arc's files under `applicationSupport` (read-only).
    public static func load(from applicationSupport: URL) throws -> ArcSidebarImport {
        let export = try ArcSidebarReader.read(applicationSupport.appendingPathComponent("Arc/\(ArcSidebarReader.fileName)"))
        let localState = applicationSupport.appendingPathComponent("\(ImportBrowser.arc.userDataPath)/Local State")
        return ArcSidebarImport(export: export, profileNames: BrowserImportDiscovery.LocalState.read(localState).names)
    }

    public func name(of profile: ArcProfileRef) -> String {
        profileNames[profile.directory].flatMap { $0.isEmpty ? nil : $0 }
            ?? (profile == .default ? "Personal" : profile.directory)
    }

    public func spaces(in profile: ArcProfileRef) -> [ArcSidebarSpace] {
        export.spaces.filter { $0.profile == profile }
    }

    /// Only the spaces and favorites of these Arc profile folders.
    public func only(directories: Set<String>) -> ArcSidebarImport {
        var copy = self
        copy.export.spaces = export.spaces.filter { directories.contains($0.profile.directory) }
        copy.export.favorites = export.favorites.filter { directories.contains($0.key.directory) }
        copy.export.profiles = export.profiles.filter { directories.contains($0.directory) }
        return copy
    }

    /// The favorites an import brings: each profile's that has a space
    /// coming over (or is Arc's default), each URL once. Into a profile with
    /// favorites already, a URL it has is skipped too.
    public func favoritesToImport() -> Int {
        let used = Set(export.spaces.map(\.profile))
        return export.profiles.filter { used.contains($0) || $0 == .default }.reduce(0) { sum, profile in
            sum + Set((export.favorites[profile] ?? []).map(\.url.absoluteString)).count
        }
    }

    /// Every space; Arc's default profile into the active ReArc profile, any
    /// other into the ReArc profile of the same name, else a new one.
    public func defaultChoices(for store: SidebarStore) -> ArcImportChoices {
        var targets: [ArcProfileRef: ArcProfileTarget] = [:]
        for profile in export.profiles {
            let name = name(of: profile)
            if let match = store.profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                targets[profile] = .existing(match.id)
            } else {
                targets[profile] = profile == .default ? .existing(store.activeProfileID) : .newProfile
            }
        }
        return ArcImportChoices(spaceIDs: Set(export.spaces.map(\.id)), profileTargets: targets)
    }

    public func summary(for choices: ArcImportChoices) -> ArcImportSummary {
        var summary = ArcImportSummary()
        var used = Set<ArcProfileRef>()
        for space in export.spaces where choices.spaceIDs.contains(space.id) {
            summary.spaces += 1
            summary.pinnedTabs += space.pinnedTabCount
            summary.folders += space.folderCount
            if choices.includeToday { summary.todayTabs += space.todayTabCount }
            used.insert(space.profile)
        }
        if choices.includeFavorites {
            for (profile, tabs) in export.favorites where !tabs.isEmpty && (used.contains(profile) || profile == .default) {
                summary.favorites += tabs.count
                used.insert(profile)
            }
        }
        summary.newProfiles = used.filter { (choices.profileTargets[$0] ?? .newProfile) == .newProfile }.count
        return summary
    }
}

extension SidebarStore {
    /// Arc's spaces as new ReArc spaces, with their pinned tabs, folders,
    /// splits, icons and themes, and each profile's favorites (skipping any
    /// URL already a favorite there). Existing spaces are never changed.
    @discardableResult
    public func importArcSidebar(_ source: ArcSidebarImport, choices: ArcImportChoices) -> ArcImportSummary {
        var summary = ArcImportSummary()
        var resolved: [ArcProfileRef: Profile.ID] = [:]
        var placeholders: [Profile.ID: Space.ID] = [:]

        func profileID(for profile: ArcProfileRef) -> Profile.ID {
            if let id = resolved[profile] { return id }
            let id: Profile.ID
            if let imported = spaces.first(where: { $0.arcSourceID?.hasPrefix("\(profile.directory):") == true }) {
                id = imported.profileID
            } else if case .existing(let existing) = choices.profileTargets[profile] ?? .newProfile, self.profile(withID: existing) != nil {
                id = existing
            } else {
                let created = addProfile(name: source.name(of: profile))
                id = created.id
                placeholders[id] = spaces(in: id).first?.id
                summary.newProfiles += 1
            }
            resolved[profile] = id
            return id
        }

        var firstSpace: Space.ID?
        for arcSpace in source.export.spaces where choices.spaceIDs.contains(arcSpace.id) {
            let target = profileID(for: arcSpace.profile)
            let sourceID = "\(arcSpace.profile.directory):\(arcSpace.id)"
            let incoming = importedEntries(arcSpace.pinned, kind: .pinned)
            // Older imports did not save source IDs. Adopt only an exact tree
            // match in the target profile; names alone never claim a space.
            let prior = spaces.first { $0.arcSourceID == sourceID } ?? spaces.first {
                $0.profileID == target && $0.arcSourceID == nil && $0.name == arcSpace.name &&
                !incoming.isEmpty && arcEntriesMatch(incoming, content(for: $0.id).pinned)
            }
            // The id follows from the Arc space, like its rows' ids: two Macs
            // importing it make one space, which sync then knows as one.
            let space = prior ?? addSpace(name: arcSpace.name, theme: arcSpace.theme ?? .arcDefault,
                                         iconName: arcSpace.icon ?? "circle.fill", profileID: target,
                                         id: Self.arcSpaceID(sourceID))
            firstSpace = firstSpace ?? space.id
            var mapping = space.arcItemMapping ?? [:]
            if prior != nil && space.arcSourceID == nil {
                mapArcEntries(incoming, to: content(for: space.id).pinned, mapping: &mapping)
            }
            var known = space.arcImportedItemIDs ?? Set(mapping.values)
            let previousIDs = known
            let pinned = remapArcEntries(incoming, mapping: mapping)
            let oldContent = content(for: space.id)
            let merged = mergeArcEntries(pinned, into: oldContent.pinned, known: &known, summary: &summary)
            setSectionEntries(merged, for: .pinned, spaceID: space.id)
            if prior == nil { summary.spaces += 1 }
            if choices.includeToday {
                let incomingToday = importedEntries(arcSpace.today, kind: .today)
                if prior != nil && space.arcSourceID == nil && arcEntriesMatch(incomingToday, oldContent.today) {
                    mapArcEntries(incomingToday, to: oldContent.today, mapping: &mapping)
                    known.formUnion(mapping.values)
                }
                let today = remapArcEntries(incomingToday, mapping: mapping)
                let merged = mergeArcEntries(today, into: oldContent.today, known: &known, summary: &summary)
                setSectionEntries(merged, for: .unpinned, spaceID: space.id)
            }
            let mergedContent = content(for: space.id)
            journalArcAdditions(mergedContent.pinned, excluding: previousIDs, spaceID: space.id, container: .pinned)
            journalArcAdditions(mergedContent.today, excluding: previousIDs, spaceID: space.id, container: .unpinned)
            if let index = spaces.firstIndex(where: { $0.id == space.id }) {
                spaces[index].arcItemMapping = mapping.isEmpty ? nil : mapping
                spaces[index].arcSourceID = sourceID
                spaces[index].arcImportedItemIDs = known
            }

        }

        if choices.includeFavorites {
            let importedProfiles = Set(source.export.spaces.filter { choices.spaceIDs.contains($0.id) }.map(\.profile))
            for profile in source.export.profiles where importedProfiles.contains(profile) || profile == .default {
                guard let tabs = source.export.favorites[profile], !tabs.isEmpty else { continue }
                let target = profileID(for: profile)
                guard let anchor = spaces(in: target).first?.id else { continue }
                var existing = Set(favorites(in: target).map(\.url.absoluteString))
                for arcTab in tabs {
                    let sourceID = Self.arcItemID(arcTab.sourceID ?? arcTab.url.absoluteString)
                    guard let index = spaces.firstIndex(where: { $0.id == anchor }) else { continue }
                    if spaces[index].arcImportedItemIDs?.contains(sourceID) == true { continue }
                    if spaces[index].arcSourceID == nil { spaces[index].arcSourceID = "\(profile.directory):__favorites" }
                    if spaces[index].arcImportedItemIDs == nil { spaces[index].arcImportedItemIDs = [] }
                    spaces[index].arcImportedItemIDs?.insert(sourceID)
                    guard existing.insert(arcTab.url.absoluteString).inserted else { continue }
                    let tab = addTab(kind: .favorite, title: arcTab.title, url: arcTab.url, in: anchor)
                    if let customTitle = arcTab.customTitle { renameTab(tab.id, to: customTitle) }
                    if let icon = arcTab.icon { setCustomIcon(icon, for: tab.id) }
                    summary.favorites += 1
                }
            }
        }

        // A new profile's own first space is empty; the imported ones replace it.
        for (profile, placeholder) in placeholders where spaces(in: profile).count > 1 {
            if content(for: placeholder).allLeaves.isEmpty { removeSpace(placeholder) }
        }
        notifyMutation()
        if let firstSpace, let owner = space(withID: firstSpace)?.profileID {
            if owner != activeProfileID { selectProfile(owner) }
            selectSpace(firstSpace)
        }
        return summary
    }

    /// Entries for one level, ranked in Arc's order. Imported folders start
    /// closed, as Arc's expansion is per window and not carried over.
    func importedEntries(_ nodes: [ArcSidebarNode], kind: Tab.Kind) -> [SidebarEntry] {
        let ranks = LexoRank.initialSequence(count: nodes.count)
        let date = now()
        func tab(_ arcTab: ArcSidebarTab, rank: String) -> Tab {
            var tab = Tab(id: Self.arcItemID(arcTab.sourceID ?? arcTab.url.absoluteString), kind: kind, title: arcTab.title, url: arcTab.url, isUnread: arcTab.isUnread, sortRank: rank,
                          customTitle: arcTab.customTitle, lastActiveAt: date, customIcon: arcTab.icon)
            if kind == .pinned {
                tab.savedURL = arcTab.url
                tab.savedTitle = arcTab.title
            }
            return tab
        }
        return zip(nodes, ranks).map { node, rank in
            switch node {
            case .tab(let arcTab):
                return .tab(tab(arcTab, rank: rank))
            case .folder(let title, let icon, let children, let sourceID):
                return .folder(SidebarFolder(id: Self.arcItemID(sourceID ?? "folder:\(title)"), title: title, children: importedEntries(children, kind: .pinned),
                                             sortRank: rank, customIcon: icon))
            case .split(let title, let orientation, let tabs, let sourceID):
                let memberRanks = LexoRank.initialSequence(count: tabs.count)
                return .split(SplitViewItem(id: Self.arcItemID(sourceID ?? "split:\(title ?? "")"), orientation: orientation, tabs: zip(tabs, memberRanks).map { tab($0, rank: $1) },
                                            sortRank: rank, title: title))
            }
        }
    }

    private func arcEntriesMatch(_ lhs: [SidebarEntry], _ rhs: [SidebarEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            switch (a, b) {
            case (.tab(let a), .tab(let b)): return a.url == b.url && a.title == b.title && a.customTitle == b.customTitle
            case (.folder(let a), .folder(let b)): return a.title == b.title && arcEntriesMatch(a.children, b.children)
            case (.split(let a), .split(let b)): return a.title == b.title && a.orientation == b.orientation && arcEntriesMatch(a.tabs.map(SidebarEntry.tab), b.tabs.map(SidebarEntry.tab))
            default: return false
            }
        }
    }

    private func mapArcEntries(_ source: [SidebarEntry], to target: [SidebarEntry], mapping: inout [UUID: UUID]) {
        for (a, b) in zip(source, target) {
            mapping[a.id] = b.id
            if case .folder(let a) = a, case .folder(let b) = b {
                mapArcEntries(a.children, to: b.children, mapping: &mapping)
            } else if case .split(let a) = a, case .split(let b) = b {
                mapArcEntries(a.tabs.map(SidebarEntry.tab), to: b.tabs.map(SidebarEntry.tab), mapping: &mapping)
            }
        }
    }

    private func remapArcEntries(_ entries: [SidebarEntry], mapping: [UUID: UUID]) -> [SidebarEntry] {
        entries.map { entry in
            switch entry {
            case .tab(let tab):
                return .tab(Tab(id: mapping[tab.id] ?? tab.id, kind: tab.kind, title: tab.title, url: tab.url,
                                faviconToken: tab.faviconToken, isUnread: tab.isUnread, sortRank: tab.sortRank,
                                customTitle: tab.customTitle, lastActiveAt: tab.lastActiveAt,
                                savedURL: tab.savedURL, savedTitle: tab.savedTitle, customIcon: tab.customIcon))
            case .folder(let folder):
                return .folder(SidebarFolder(id: mapping[folder.id] ?? folder.id, title: folder.title,
                    children: remapArcEntries(folder.children, mapping: mapping), sortRank: folder.sortRank, customIcon: folder.customIcon))
            case .split(let split):
                let tabs = remapArcEntries(split.tabs.map(SidebarEntry.tab), mapping: mapping).compactMap { if case .tab(let tab) = $0 { return tab }; return nil }
                return .split(SplitViewItem(id: mapping[split.id] ?? split.id, orientation: split.orientation,
                    tabs: tabs, sortRank: split.sortRank, customIcon: split.customIcon, title: split.title))
            case .easel: return entry
            }
        }
    }

    /// A space imported from the Arc space `sourceID` ("<profile directory>:<Arc id>").
    static func arcSpaceID(_ sourceID: String) -> UUID {
        arcItemID("space:\(sourceID)")
    }

    static func arcItemID(_ source: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("rearc:arc:\(source)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func mergeArcEntries(_ incoming: [SidebarEntry], into existing: [SidebarEntry],
                                 known: inout Set<UUID>, summary: inout ArcImportSummary) -> [SidebarEntry] {
        var out = existing
        for entry in incoming {
            if let index = out.firstIndex(where: { $0.id == entry.id }) {
                if case .folder(var folder) = out[index], case .folder(let source) = entry {
                    folder.children = mergeArcEntries(source.children, into: folder.children, known: &known, summary: &summary)
                    out[index] = .folder(folder)
                } else if case .split(var split) = out[index], case .split(let source) = entry {
                    for tab in source.tabs where !known.contains(tab.id) && split.tabs.count < 4 {
                        split.tabs.append(tab)
                        known.insert(tab.id)
                        summary.pinnedTabs += 1
                    }
                    out[index] = .split(split)
                }
                continue
            }
            guard known.insert(entry.id).inserted else { continue }
            switch entry {
            case .tab(let tab):
                if tab.kind == .today { summary.todayTabs += 1 } else { summary.pinnedTabs += 1 }
            case .folder(let folder):
                summary.folders += 1
                _ = mergeArcEntries(folder.children, into: [], known: &known, summary: &summary)
            case .split(let split):
                for tab in split.tabs { known.insert(tab.id) }
                summary.pinnedTabs += split.tabs.count
            case .easel: break
            }
            out.append(entry)
        }
        // Preserve the user's order; new rows follow existing ones.
        let ranks = LexoRank.initialSequence(count: out.count)
        return zip(out, ranks).map { entry, rank in
            var entry = entry
            switch entry {
            case .tab(var tab): tab.sortRank = rank; entry = .tab(tab)
            case .folder(var folder): folder.sortRank = rank; entry = .folder(folder)
            case .split(var split): split.sortRank = rank; entry = .split(split)
            case .easel: break
            }
            return entry
        }
    }

    /// Preview against a snapshot, including the persisted source ledger.
    public func remainingArcImport(_ source: ArcSidebarImport, choices: ArcImportChoices) -> ArcImportSummary {
        let copy = SidebarStore(spaces: spaces)
        copy.applySnapshot(makeSnapshot())
        return copy.importArcSidebar(source, choices: choices)
    }

    private func journalArcAdditions(_ entries: [SidebarEntry], excluding known: Set<UUID>,
                                     spaceID: Space.ID, container: SidebarItemContainer, folderID: UUID? = nil) {
        for entry in entries {
            if !known.contains(entry.id) {
                if let folderID {
                    mutationJournal.record(.placeItemInFolder(id: entry.id, folderID: folderID, sortRank: rank(of: entry)))
                } else {
                    mutationJournal.record(.insertItem(id: entry.id, spaceID: spaceID, container: container, sortRank: rank(of: entry)))
                }
            }
            if case .folder(let folder) = entry {
                journalArcAdditions(folder.children, excluding: known, spaceID: spaceID, container: container, folderID: folder.id)
            }
        }
    }

    /// Sync sees each imported row as an insert, as if placed by hand.
    func journalImported(_ entries: [SidebarEntry], spaceID: Space.ID, container: SidebarItemContainer, folderID: UUID? = nil) {
        for entry in entries {
            let rank = rank(of: entry)
            if let folderID {
                mutationJournal.record(.placeItemInFolder(id: entry.id, folderID: folderID, sortRank: rank))
            } else {
                mutationJournal.record(.insertItem(id: entry.id, spaceID: spaceID, container: container, sortRank: rank))
            }
            if case .folder(let folder) = entry {
                journalImported(folder.children, spaceID: spaceID, container: container, folderID: folder.id)
            }
        }
    }
}
