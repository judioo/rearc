import Foundation

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

    public var isEmpty: Bool { spaces == 0 && favorites == 0 }
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
            if case .existing(let existing) = choices.profileTargets[profile] ?? .newProfile, self.profile(withID: existing) != nil {
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
            let space = addSpace(name: arcSpace.name, theme: arcSpace.theme ?? .arcDefault,
                                 iconName: arcSpace.icon ?? "circle.fill", profileID: target)
            firstSpace = firstSpace ?? space.id
            let pinned = importedEntries(arcSpace.pinned, kind: .pinned)
            setSectionEntries(pinned, for: .pinned, spaceID: space.id)
            journalImported(pinned, spaceID: space.id, container: .pinned)
            summary.spaces += 1
            summary.pinnedTabs += arcSpace.pinnedTabCount
            summary.folders += arcSpace.folderCount
            if choices.includeToday, !arcSpace.today.isEmpty {
                let today = importedEntries(arcSpace.today, kind: .today)
                setSectionEntries(today, for: .unpinned, spaceID: space.id)
                journalImported(today, spaceID: space.id, container: .unpinned)
                summary.todayTabs += arcSpace.todayTabCount
            }
        }

        if choices.includeFavorites {
            let importedProfiles = Set(source.export.spaces.filter { choices.spaceIDs.contains($0.id) }.map(\.profile))
            for profile in source.export.profiles where importedProfiles.contains(profile) || profile == .default {
                guard let tabs = source.export.favorites[profile], !tabs.isEmpty else { continue }
                let target = profileID(for: profile)
                guard let anchor = spaces(in: target).first?.id else { continue }
                var existing = Set(favorites(in: target).map(\.url.absoluteString))
                for arcTab in tabs where existing.insert(arcTab.url.absoluteString).inserted {
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
            var tab = Tab(kind: kind, title: arcTab.title, url: arcTab.url, isUnread: arcTab.isUnread, sortRank: rank,
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
            case .folder(let title, let icon, let children):
                return .folder(SidebarFolder(title: title, children: importedEntries(children, kind: .pinned),
                                             sortRank: rank, customIcon: icon))
            case .split(let title, let orientation, let tabs):
                let memberRanks = LexoRank.initialSequence(count: tabs.count)
                return .split(SplitViewItem(orientation: orientation, tabs: zip(tabs, memberRanks).map { tab($0, rank: $1) },
                                            sortRank: rank, title: title))
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
