import Foundation

/// A folder node in a snapshot: its children are ids resolved through the
/// snapshot's tab, folder, split and easel tables.
public struct SidebarFolderRecord: Equatable, Codable {
    public var id: UUID
    public var title: String
    public var childIDs: [UUID]
    public var sortRank: String
    public var customIcon: SidebarItemIcon?

    public init(id: UUID, title: String, childIDs: [UUID], sortRank: String, customIcon: SidebarItemIcon? = nil) {
        self.id = id
        self.title = title
        self.childIDs = childIDs
        self.sortRank = sortRank
        self.customIcon = customIcon
    }

    public init(_ folder: SidebarFolder) {
        self.init(id: folder.id, title: folder.title, childIDs: folder.children.map(\.id), sortRank: folder.sortRank, customIcon: folder.customIcon)
    }
}

/// Codable representation of full sidebar state. Persistence and future sync
/// backends exchange snapshots; `SidebarStore` command APIs stay unchanged.
///
/// Schema 10 adds folders, favorites keyed by profile, folder expansion, the
/// tab archive and per-profile auto-archive thresholds. Optional customIcon
/// fields are additive; older schema 10 files decode them as nil.
public struct SidebarSnapshot: Equatable, Codable {
    public static let schemaVersion = 10

    public var schemaVersion: Int
    /// Highest journal sequence durably synced to remote (0 = never flushed).
    public var lastFlushedSequence: UInt64
    /// Unflushed journal entries for crash recovery (tail beyond `lastFlushedSequence`).
    public var journalPersistedTail: [SidebarJournalEntry]
    public var profiles: [Profile]
    public var activeProfileID: Profile.ID
    public var lastActiveSpaceByProfile: [Profile.ID: Space.ID]
    public var spaces: [Space]
    public var activeSpaceID: Space.ID
    public var selectedItemID: UUID?
    public var selectionBySpace: [Space.ID: UUID]

    /// Explicit container nodes (`topApps` + per-space pinned/unpinned).
    public var topAppsContainer: ItemContainerRecord
    public var spaceContainers: [Space.ID: SpaceContainerBundle]

    /// Tab payloads keyed by id (includes tabs nested in splits).
    public var tabsByID: [UUID: Tab]
    /// Split payloads keyed by split item id.
    public var splitsByID: [UUID: SplitViewItem]

    public var closedTabStack: ClosedTabStack
    public var commandBarUsageBumps: [String: Int]
    public var littleArcWindows: [LittleArcWindow]
    public var archivedLittleArcWindows: [ArchivedLittleArcWindow]
    /// Boost libraries keyed by profile id (packages live in-profile, not on spaces).
    public var boostLibrariesByProfileID: [Profile.ID: ProfileBoostLibrary]
    /// Easel sidebar rows keyed by sidebar item id (document bodies live under easels/).
    public var easelRefsByID: [UUID: SidebarEaselRef]
    /// Capture library index (PNG bytes live under Captures/).
    public var capturesByID: [UUID: CaptureRecord]
    /// Favorites strip per profile (schema 10). `topAppsContainer` keeps the
    /// first profile's strip; before 10 it was the only, global one.
    public var topAppsContainersByProfileID: [Profile.ID: ItemContainerRecord] = [:]
    public var foldersByID: [UUID: SidebarFolderRecord] = [:]
    public var expandedFolderIDs: [UUID] = []
    public var archivedTabs: [ArchivedTabRecord] = []
    public var autoArchiveThresholdByProfile: [Profile.ID: AutoArchiveThreshold] = [:]

    public struct SpaceContainerBundle: Equatable, Codable {
        public var pinned: ItemContainerRecord
        public var unpinned: ItemContainerRecord

        public init(pinned: ItemContainerRecord, unpinned: ItemContainerRecord) {
            self.pinned = pinned
            self.unpinned = unpinned
        }
    }

    public init(
        schemaVersion: Int = SidebarSnapshot.schemaVersion,
        lastFlushedSequence: UInt64 = 0,
        journalPersistedTail: [SidebarJournalEntry] = [],
        profiles: [Profile],
        activeProfileID: Profile.ID,
        lastActiveSpaceByProfile: [Profile.ID: Space.ID],
        spaces: [Space],
        activeSpaceID: Space.ID,
        selectedItemID: UUID?,
        selectionBySpace: [Space.ID: UUID],
        topAppsContainer: ItemContainerRecord,
        spaceContainers: [Space.ID: SpaceContainerBundle],
        tabsByID: [UUID: Tab],
        splitsByID: [UUID: SplitViewItem],
        closedTabStack: ClosedTabStack = ClosedTabStack(),
        commandBarUsageBumps: [String: Int] = [:],
        littleArcWindows: [LittleArcWindow] = [],
        archivedLittleArcWindows: [ArchivedLittleArcWindow] = [],
        boostLibrariesByProfileID: [Profile.ID: ProfileBoostLibrary] = [:],
        easelRefsByID: [UUID: SidebarEaselRef] = [:],
        capturesByID: [UUID: CaptureRecord] = [:],
        topAppsContainersByProfileID: [Profile.ID: ItemContainerRecord] = [:],
        foldersByID: [UUID: SidebarFolderRecord] = [:],
        expandedFolderIDs: [UUID] = [],
        archivedTabs: [ArchivedTabRecord] = [],
        autoArchiveThresholdByProfile: [Profile.ID: AutoArchiveThreshold] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.lastFlushedSequence = lastFlushedSequence
        self.journalPersistedTail = journalPersistedTail
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.lastActiveSpaceByProfile = lastActiveSpaceByProfile
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.selectedItemID = selectedItemID
        self.selectionBySpace = selectionBySpace
        self.topAppsContainer = topAppsContainer
        self.spaceContainers = spaceContainers
        self.tabsByID = tabsByID
        self.splitsByID = splitsByID
        self.closedTabStack = closedTabStack
        self.commandBarUsageBumps = commandBarUsageBumps
        self.littleArcWindows = littleArcWindows
        self.archivedLittleArcWindows = archivedLittleArcWindows
        self.boostLibrariesByProfileID = boostLibrariesByProfileID
        self.easelRefsByID = easelRefsByID
        self.capturesByID = capturesByID
        self.topAppsContainersByProfileID = topAppsContainersByProfileID
        self.foldersByID = foldersByID
        self.expandedFolderIDs = expandedFolderIDs
        self.archivedTabs = archivedTabs
        self.autoArchiveThresholdByProfile = autoArchiveThresholdByProfile
    }

    public init(from store: SidebarStore) {
        self = store.makeSnapshot()
    }

    // MARK: - Decoding (v1 → v4 migration)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastFlushedSequence, journalPersistedTail
        case profiles, activeProfileID, lastActiveSpaceByProfile
        case spaces, activeSpaceID
        case selectedItemID, selectedTabID
        case selectionBySpace
        case topAppsContainer, spaceContainers, tabsByID, splitsByID
        case closedTabStack, commandBarUsageBumps
        case littleArcWindows, archivedLittleArcWindows
        case boostLibrariesByProfileID
        case easelRefsByID, capturesByID
        case topAppsContainersByProfileID, foldersByID, expandedFolderIDs
        case archivedTabs, autoArchiveThresholdByProfile
        case favorites, contentBySpace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if version > SidebarSnapshot.schemaVersion {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "Unsupported future schema version \(version)"
            )
        }
        if version <= 1 {
            self = try SidebarSnapshot.migrateFromV1(c)
            self = Self.applyV3ToV4Migration(self)
            self = Self.applyV4ToV5Migration(self)
            self = Self.applyV5ToV6Migration(self)
            self = Self.applyV6ToV7Migration(self)
            self = Self.applyV7ToV8Migration(self)
            self = Self.applyV8ToV9Migration(self)
            self = Self.applyV9ToV10Migration(self)
            return
        }

        spaces = try c.decode([Space].self, forKey: .spaces)
        lastFlushedSequence = try c.decodeIfPresent(UInt64.self, forKey: .lastFlushedSequence) ?? 0
        journalPersistedTail = try c.decodeIfPresent([SidebarJournalEntry].self, forKey: .journalPersistedTail) ?? []
        activeSpaceID = try c.decode(Space.ID.self, forKey: .activeSpaceID)
        selectedItemID = try c.decodeIfPresent(UUID.self, forKey: .selectedItemID)
        selectionBySpace = try c.decode([Space.ID: UUID].self, forKey: .selectionBySpace)
        topAppsContainer = try c.decode(ItemContainerRecord.self, forKey: .topAppsContainer)
        spaceContainers = try c.decode([Space.ID: SpaceContainerBundle].self, forKey: .spaceContainers)
        tabsByID = try c.decode([UUID: Tab].self, forKey: .tabsByID)
        splitsByID = try c.decode([UUID: SplitViewItem].self, forKey: .splitsByID)
        closedTabStack = try c.decodeIfPresent(ClosedTabStack.self, forKey: .closedTabStack) ?? ClosedTabStack()
        commandBarUsageBumps = try c.decodeIfPresent([String: Int].self, forKey: .commandBarUsageBumps) ?? [:]

        if version >= 4,
           let decodedProfiles = try c.decodeIfPresent([Profile].self, forKey: .profiles),
           let activeProfile = try c.decodeIfPresent(Profile.ID.self, forKey: .activeProfileID) {
            profiles = decodedProfiles
            activeProfileID = activeProfile
            lastActiveSpaceByProfile = try c.decodeIfPresent(
                [Profile.ID: Space.ID].self,
                forKey: .lastActiveSpaceByProfile
            ) ?? [:]
            if version >= 5 {
                littleArcWindows = try c.decodeIfPresent([LittleArcWindow].self, forKey: .littleArcWindows) ?? []
                archivedLittleArcWindows = try c.decodeIfPresent(
                    [ArchivedLittleArcWindow].self,
                    forKey: .archivedLittleArcWindows
                ) ?? []
                if version >= 6 {
                    boostLibrariesByProfileID = try c.decodeIfPresent(
                        [Profile.ID: ProfileBoostLibrary].self,
                        forKey: .boostLibrariesByProfileID
                    ) ?? [:]
                    if version >= 7 {
                        easelRefsByID = try c.decodeIfPresent(
                            [UUID: SidebarEaselRef].self,
                            forKey: .easelRefsByID
                        ) ?? [:]
                        capturesByID = try c.decodeIfPresent(
                            [UUID: CaptureRecord].self,
                            forKey: .capturesByID
                        ) ?? [:]
                        if version >= 9 {
                            schemaVersion = SidebarSnapshot.schemaVersion
                        } else if version >= 8 {
                            schemaVersion = 8
                            var migrated = SidebarSnapshot(
                                schemaVersion: 8,
                                lastFlushedSequence: lastFlushedSequence,
                                journalPersistedTail: journalPersistedTail,
                                profiles: profiles,
                                activeProfileID: activeProfileID,
                                lastActiveSpaceByProfile: lastActiveSpaceByProfile,
                                spaces: spaces,
                                activeSpaceID: activeSpaceID,
                                selectedItemID: selectedItemID,
                                selectionBySpace: selectionBySpace,
                                topAppsContainer: topAppsContainer,
                                spaceContainers: spaceContainers,
                                tabsByID: tabsByID,
                                splitsByID: splitsByID,
                                closedTabStack: closedTabStack,
                                commandBarUsageBumps: commandBarUsageBumps,
                                littleArcWindows: littleArcWindows,
                                archivedLittleArcWindows: archivedLittleArcWindows,
                                boostLibrariesByProfileID: boostLibrariesByProfileID,
                                easelRefsByID: easelRefsByID,
                                capturesByID: capturesByID
                            )
                            self = Self.applyV8ToV9Migration(migrated)
                        } else {
                            schemaVersion = 7
                            var migrated = SidebarSnapshot(
                                schemaVersion: 7,
                                profiles: profiles,
                                activeProfileID: activeProfileID,
                                lastActiveSpaceByProfile: lastActiveSpaceByProfile,
                                spaces: spaces,
                                activeSpaceID: activeSpaceID,
                                selectedItemID: selectedItemID,
                                selectionBySpace: selectionBySpace,
                                topAppsContainer: topAppsContainer,
                                spaceContainers: spaceContainers,
                                tabsByID: tabsByID,
                                splitsByID: splitsByID,
                                closedTabStack: closedTabStack,
                                commandBarUsageBumps: commandBarUsageBumps,
                                littleArcWindows: littleArcWindows,
                                archivedLittleArcWindows: archivedLittleArcWindows,
                                boostLibrariesByProfileID: boostLibrariesByProfileID,
                                easelRefsByID: easelRefsByID,
                                capturesByID: capturesByID
                            )
                            self = Self.applyV7ToV8Migration(migrated)
                            self = Self.applyV8ToV9Migration(self)
                        }
                    } else {
                        easelRefsByID = [:]
                        capturesByID = [:]
                        var migrated = SidebarSnapshot(
                            schemaVersion: 6,
                            profiles: profiles,
                            activeProfileID: activeProfileID,
                            lastActiveSpaceByProfile: lastActiveSpaceByProfile,
                            spaces: spaces,
                            activeSpaceID: activeSpaceID,
                            selectedItemID: selectedItemID,
                            selectionBySpace: selectionBySpace,
                            topAppsContainer: topAppsContainer,
                            spaceContainers: spaceContainers,
                            tabsByID: tabsByID,
                            splitsByID: splitsByID,
                            closedTabStack: closedTabStack,
                            commandBarUsageBumps: commandBarUsageBumps,
                            littleArcWindows: littleArcWindows,
                            archivedLittleArcWindows: archivedLittleArcWindows,
                            boostLibrariesByProfileID: boostLibrariesByProfileID,
                            easelRefsByID: [:],
                            capturesByID: [:]
                        )
                        self = Self.applyV6ToV7Migration(migrated)
                        self = Self.applyV7ToV8Migration(self)
                        self = Self.applyV8ToV9Migration(self)
                    }
                } else {
                    boostLibrariesByProfileID = [:]
                    easelRefsByID = [:]
                    capturesByID = [:]
                    var migrated = SidebarSnapshot(
                        schemaVersion: 5,
                        profiles: profiles,
                        activeProfileID: activeProfileID,
                        lastActiveSpaceByProfile: lastActiveSpaceByProfile,
                        spaces: spaces,
                        activeSpaceID: activeSpaceID,
                        selectedItemID: selectedItemID,
                        selectionBySpace: selectionBySpace,
                        topAppsContainer: topAppsContainer,
                        spaceContainers: spaceContainers,
                        tabsByID: tabsByID,
                        splitsByID: splitsByID,
                        closedTabStack: closedTabStack,
                        commandBarUsageBumps: commandBarUsageBumps,
                        littleArcWindows: littleArcWindows,
                        archivedLittleArcWindows: archivedLittleArcWindows,
                        boostLibrariesByProfileID: boostLibrariesByProfileID
                    )
                    self = Self.applyV5ToV6Migration(migrated)
                    self = Self.applyV6ToV7Migration(self)
                    self = Self.applyV7ToV8Migration(self)
                    self = Self.applyV8ToV9Migration(self)
                }
            } else {
                boostLibrariesByProfileID = [:]
                littleArcWindows = []
                archivedLittleArcWindows = []
                self = Self.applyV4ToV5Migration(
                    SidebarSnapshot(
                        schemaVersion: 4,
                        profiles: profiles,
                        activeProfileID: activeProfileID,
                        lastActiveSpaceByProfile: lastActiveSpaceByProfile,
                        spaces: spaces,
                        activeSpaceID: activeSpaceID,
                        selectedItemID: selectedItemID,
                        selectionBySpace: selectionBySpace,
                        topAppsContainer: topAppsContainer,
                        spaceContainers: spaceContainers,
                        tabsByID: tabsByID,
                        splitsByID: splitsByID,
                        closedTabStack: closedTabStack,
                        commandBarUsageBumps: commandBarUsageBumps,
                        littleArcWindows: [],
                        archivedLittleArcWindows: []
                    )
                )
                self = Self.applyV5ToV6Migration(self)
                self = Self.applyV6ToV7Migration(self)
                self = Self.applyV7ToV8Migration(self)
                self = Self.applyV8ToV9Migration(self)
            }
        } else {
            self = Self.applyV3ToV4Migration(
                SidebarSnapshot(
                    schemaVersion: 3,
                    profiles: [],
                    activeProfileID: UUID(),
                    lastActiveSpaceByProfile: [:],
                    spaces: spaces,
                    activeSpaceID: activeSpaceID,
                    selectedItemID: selectedItemID,
                    selectionBySpace: selectionBySpace,
                    topAppsContainer: topAppsContainer,
                    spaceContainers: spaceContainers,
                    tabsByID: tabsByID,
                    splitsByID: splitsByID,
                    closedTabStack: closedTabStack,
                    commandBarUsageBumps: commandBarUsageBumps
                )
            )
            self = Self.applyV4ToV5Migration(self)
            self = Self.applyV5ToV6Migration(self)
            self = Self.applyV6ToV7Migration(self)
            self = Self.applyV7ToV8Migration(self)
            self = Self.applyV8ToV9Migration(self)
        }
        if version >= 10 {
            topAppsContainersByProfileID = try c.decodeIfPresent(
                [Profile.ID: ItemContainerRecord].self,
                forKey: .topAppsContainersByProfileID
            ) ?? [:]
            foldersByID = try c.decodeIfPresent([UUID: SidebarFolderRecord].self, forKey: .foldersByID) ?? [:]
            expandedFolderIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedFolderIDs) ?? []
            archivedTabs = try c.decodeIfPresent([ArchivedTabRecord].self, forKey: .archivedTabs) ?? []
            autoArchiveThresholdByProfile = try c.decodeIfPresent(
                [Profile.ID: AutoArchiveThreshold].self,
                forKey: .autoArchiveThresholdByProfile
            ) ?? [:]
            schemaVersion = SidebarSnapshot.schemaVersion
        } else {
            self = Self.applyV9ToV10Migration(self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(SidebarSnapshot.schemaVersion, forKey: .schemaVersion)
        try c.encode(lastFlushedSequence, forKey: .lastFlushedSequence)
        try c.encode(journalPersistedTail, forKey: .journalPersistedTail)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(activeProfileID, forKey: .activeProfileID)
        try c.encode(lastActiveSpaceByProfile, forKey: .lastActiveSpaceByProfile)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(activeSpaceID, forKey: .activeSpaceID)
        try c.encode(selectedItemID, forKey: .selectedItemID)
        try c.encode(selectionBySpace, forKey: .selectionBySpace)
        try c.encode(topAppsContainer, forKey: .topAppsContainer)
        try c.encode(spaceContainers, forKey: .spaceContainers)
        try c.encode(tabsByID, forKey: .tabsByID)
        try c.encode(splitsByID, forKey: .splitsByID)
        try c.encode(closedTabStack, forKey: .closedTabStack)
        try c.encode(commandBarUsageBumps, forKey: .commandBarUsageBumps)
        try c.encode(littleArcWindows, forKey: .littleArcWindows)
        try c.encode(archivedLittleArcWindows, forKey: .archivedLittleArcWindows)
        try c.encode(boostLibrariesByProfileID, forKey: .boostLibrariesByProfileID)
        try c.encode(easelRefsByID, forKey: .easelRefsByID)
        try c.encode(capturesByID, forKey: .capturesByID)
        try c.encode(topAppsContainersByProfileID, forKey: .topAppsContainersByProfileID)
        try c.encode(foldersByID, forKey: .foldersByID)
        try c.encode(expandedFolderIDs, forKey: .expandedFolderIDs)
        try c.encode(archivedTabs, forKey: .archivedTabs)
        try c.encode(autoArchiveThresholdByProfile, forKey: .autoArchiveThresholdByProfile)
    }

    /// Favorites were one global strip before schema 10; Arc keys `topApps`
    /// by profile (DATA-SCHEMA §1.7), so the strip moves to the default
    /// (first) profile. Other profiles start with an empty strip.
    private static func applyV9ToV10Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = SidebarSnapshot.schemaVersion
        if migrated.topAppsContainersByProfileID.isEmpty, let defaultProfile = migrated.profiles.first {
            migrated.topAppsContainersByProfileID = [defaultProfile.id: migrated.topAppsContainer]
        }
        return migrated
    }

    private static func applyV6ToV7Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = 7
        if migrated.easelRefsByID.isEmpty {
            migrated.easelRefsByID = [:]
        }
        if migrated.capturesByID.isEmpty {
            migrated.capturesByID = [:]
        }
        return migrated
    }

    private static let legacyLittleArcProfilePlaceholder = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func applyV7ToV8Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = 8
        let fallbackProfile = migrated.activeProfileID
        migrated.littleArcWindows = migrated.littleArcWindows.map { window in
            var copy = window
            if copy.profileID == legacyLittleArcProfilePlaceholder {
                copy.profileID = fallbackProfile
            }
            return copy
        }
        migrated.archivedLittleArcWindows = migrated.archivedLittleArcWindows.map { archived in
            var copy = archived
            if copy.window.profileID == legacyLittleArcProfilePlaceholder {
                copy.window.profileID = fallbackProfile
            }
            return copy
        }
        return migrated
    }

    private static func applyV8ToV9Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = SidebarSnapshot.schemaVersion
        let spaceRanks = LexoRank.initialSequence(count: migrated.spaces.count)
        for index in migrated.spaces.indices where migrated.spaces[index].sortRank.isEmpty {
            migrated.spaces[index].sortRank = spaceRanks[index]
        }
        assignRanksFromChildOrder(
            childIDs: migrated.topAppsContainer.childIDs,
            tabsByID: &migrated.tabsByID,
            splitsByID: &migrated.splitsByID,
            easelRefsByID: &migrated.easelRefsByID
        )
        for bundle in migrated.spaceContainers.values {
            assignRanksFromChildOrder(
                childIDs: bundle.pinned.childIDs,
                tabsByID: &migrated.tabsByID,
                splitsByID: &migrated.splitsByID,
                easelRefsByID: &migrated.easelRefsByID
            )
            assignRanksFromChildOrder(
                childIDs: bundle.unpinned.childIDs,
                tabsByID: &migrated.tabsByID,
                splitsByID: &migrated.splitsByID,
                easelRefsByID: &migrated.easelRefsByID
            )
        }
        return migrated
    }

    private static func assignRanksFromChildOrder(
        childIDs: [UUID],
        tabsByID: inout [UUID: Tab],
        splitsByID: inout [UUID: SplitViewItem],
        easelRefsByID: inout [UUID: SidebarEaselRef]
    ) {
        let ranks = LexoRank.initialSequence(count: childIDs.count)
        for (index, id) in childIDs.enumerated() {
            if var tab = tabsByID[id], tab.sortRank.isEmpty {
                tab.sortRank = ranks[index]
                tabsByID[id] = tab
            } else if var split = splitsByID[id], split.sortRank.isEmpty {
                split.sortRank = ranks[index]
                splitsByID[id] = split
            } else if var easel = easelRefsByID[id], easel.sortRank.isEmpty {
                easel.sortRank = ranks[index]
                easelRefsByID[id] = easel
            }
        }
    }

    private static func applyV5ToV6Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = SidebarSnapshot.schemaVersion
        var libraries = migrated.boostLibrariesByProfileID
        for profile in migrated.profiles where libraries[profile.id] == nil {
            libraries[profile.id] = BoostLibraryOps.empty(for: profile.id)
        }
        migrated.boostLibrariesByProfileID = libraries
        return migrated
    }

    private static func applyV4ToV5Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        migrated.schemaVersion = SidebarSnapshot.schemaVersion
        if migrated.littleArcWindows.isEmpty && migrated.archivedLittleArcWindows.isEmpty {
            // Fields already default-empty for older payloads.
        }
        return migrated
    }

    private struct V1SpaceContent: Codable {
        var pinned: [Tab]
        var today: [Tab]
    }

    private static func applyV3ToV4Migration(_ snapshot: SidebarSnapshot) -> SidebarSnapshot {
        var migrated = snapshot
        let defaultProfile = Profile.personalDefault()
        migrated.profiles = [defaultProfile]
        migrated.activeProfileID = defaultProfile.id
        migrated.spaces = snapshot.spaces.map { space in
            var copy = space
            copy.profileID = defaultProfile.id
            return copy
        }
        if migrated.spaces.isEmpty {
            migrated.spaces = [Space(name: "Personal", profileID: defaultProfile.id)]
        }
        let active = migrated.spaces.contains(where: { $0.id == migrated.activeSpaceID })
            ? migrated.activeSpaceID
            : migrated.spaces[0].id
        migrated.activeSpaceID = active
        migrated.lastActiveSpaceByProfile = [defaultProfile.id: active]
        migrated.schemaVersion = SidebarSnapshot.schemaVersion
        return migrated
    }

    private static func migrateFromV1(_ c: KeyedDecodingContainer<CodingKeys>) throws -> SidebarSnapshot {
        let spaces = try c.decode([Space].self, forKey: .spaces)
        let activeSpaceID = try c.decode(Space.ID.self, forKey: .activeSpaceID)
        let favorites = try c.decode([Tab].self, forKey: .favorites)
        let rawContent = try c.decode([String: V1SpaceContent].self, forKey: .contentBySpace)
        let contentBySpace = Dictionary(uniqueKeysWithValues: rawContent.compactMap { key, value -> (Space.ID, V1SpaceContent)? in
            guard let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        })
        let selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        let rawSelection = try c.decodeIfPresent([String: UUID].self, forKey: .selectionBySpace) ?? [:]
        let selectionBySpaceTab = Dictionary(uniqueKeysWithValues: rawSelection.compactMap { key, value -> (Space.ID, UUID)? in
            guard let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        })

        var tabsByID: [UUID: Tab] = [:]
        for tab in favorites { tabsByID[tab.id] = tab }
        for (_, content) in contentBySpace {
            for tab in content.pinned + content.today {
                tabsByID[tab.id] = tab
            }
        }

        let topApps = ItemContainerRecord(
            id: UUID(),
            kind: .topApps,
            childIDs: favorites.map(\.id)
        )

        var spaceContainers: [Space.ID: SpaceContainerBundle] = [:]
        let repairedSpaces = spaces
        for space in repairedSpaces {
            let content = contentBySpace[space.id] ?? V1SpaceContent(pinned: [], today: [])
            let pinnedContainer = ItemContainerRecord(
                id: space.pinnedContainerID,
                kind: .spaceItems(spaceID: space.id, section: .pinned),
                childIDs: content.pinned.map(\.id)
            )
            let unpinnedContainer = ItemContainerRecord(
                id: space.unpinnedContainerID,
                kind: .spaceItems(spaceID: space.id, section: .unpinned),
                childIDs: content.today.map(\.id),
                unpinnedShared: space.unpinnedShared
            )
            spaceContainers[space.id] = SpaceContainerBundle(pinned: pinnedContainer, unpinned: unpinnedContainer)
        }

        return SidebarSnapshot(
            schemaVersion: SidebarSnapshot.schemaVersion,
            profiles: [],
            activeProfileID: UUID(),
            lastActiveSpaceByProfile: [:],
            spaces: repairedSpaces,
            activeSpaceID: activeSpaceID,
            selectedItemID: selectedTabID,
            selectionBySpace: selectionBySpaceTab,
            topAppsContainer: topApps,
            spaceContainers: spaceContainers,
            tabsByID: tabsByID,
            splitsByID: [:],
            closedTabStack: ClosedTabStack(),
            commandBarUsageBumps: [:]
        )
    }
}
