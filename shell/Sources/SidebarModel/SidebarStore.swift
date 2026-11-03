import Foundation
import Observation

/// The sidebar's single source of truth. Pure Swift, no UI-framework imports,
/// so the whole model is unit-testable and could later be shared with an
/// engine layer or sync layer.
@Observable
public final class SidebarStore {

    /// The per-space tab sections. Entries may be plain tabs, split items,
    /// easels, or folders; folders live in `pinned` and nest.
    public struct SpaceContent: Equatable, Codable {
        public var pinned: [SidebarEntry]
        public var today: [SidebarEntry]

        public init(pinned: [SidebarEntry] = [], today: [SidebarEntry] = []) {
            self.pinned = pinned
            self.today = today
        }

        /// Non-folder pinned entries in display order (folder contents included).
        public var pinnedLeaves: [SidebarEntry] { SidebarTree.leaves(pinned) }
        public var todayLeaves: [SidebarEntry] { SidebarTree.leaves(today) }
        public var allLeaves: [SidebarEntry] { pinnedLeaves + todayLeaves }

        enum CodingKeys: String, CodingKey {
            case pinned, today
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let entries = try? c.decode([SidebarEntry].self, forKey: .pinned) {
                pinned = entries
                today = try c.decode([SidebarEntry].self, forKey: .today)
            } else {
                let legacyPinned = try c.decode([Tab].self, forKey: .pinned)
                let legacyToday = try c.decode([Tab].self, forKey: .today)
                pinned = legacyPinned.map { .tab($0) }
                today = legacyToday.map { .tab($0) }
            }
        }
    }

    enum TabLocation: Equatable {
        case favorite
        /// In the space's pinned section, at top level or inside a folder.
        case pinned(Space.ID)
        case today(Space.ID)
        case splitPane(spaceID: Space.ID, splitID: SplitViewItem.ID)
    }

    /// Where `moveItem` places an entry.
    public enum ItemDestination: Equatable, Hashable {
        /// A profile's favorites strip; nil means the active profile.
        case favorites(Profile.ID?)
        case section(spaceID: Space.ID, section: ItemContainerKind.SpaceSection)
        case folder(UUID)
    }

    /// The container directly holding an entry.
    public enum ItemParent: Equatable, Hashable {
        case favorites(Profile.ID)
        case section(spaceID: Space.ID, section: ItemContainerKind.SpaceSection)
        case folder(UUID)
    }

    public private(set) var profiles: [Profile]
    public private(set) var activeProfileID: Profile.ID
    public private(set) var lastActiveSpaceByProfile: [Profile.ID: Space.ID]
    public private(set) var spaces: [Space]
    public private(set) var activeSpaceID: Space.ID
    /// Favorites strip per profile (Arc `topAppsContainerIDs` keyed by profile).
    public private(set) var favoritesByProfile: [Profile.ID: [Tab]]
    public private(set) var topAppsContainerIDByProfile: [Profile.ID: UUID]
    public private(set) var contentBySpace: [Space.ID: SpaceContent]
    public internal(set) var selectedItemID: UUID?
    public private(set) var closedTabStack = ClosedTabStack()
    public internal(set) var commandBarUsageBumps: [String: Int] = [:]
    public internal(set) var littleArcWindows: [LittleArcWindow] = []
    public internal(set) var archivedLittleArcWindows: [ArchivedLittleArcWindow] = []
    public private(set) var boostLibrariesByProfileID: [Profile.ID: ProfileBoostLibrary] = [:]
    public internal(set) var easelRefsByID: [UUID: SidebarEaselRef] = [:]
    public internal(set) var capturesByID: [UUID: CaptureRecord] = [:]
    /// Expanded folders. Arc keeps this per window (`StorableWindows.expandedItems`);
    /// ReArc windows share one sidebar, so it is per store.
    public internal(set) var expandedFolderIDs: Set<UUID> = []
    /// Closed and auto-archived tabs, newest last (Arc archive store).
    public internal(set) var archivedTabs: [ArchivedTabRecord] = []
    public internal(set) var autoArchiveThresholdByProfile: [Profile.ID: AutoArchiveThreshold] = [:]
    public var autoPiPPolicy = AutoPiPPolicyState()
    /// Clock for last-active stamps and archive times (tests inject a fixed date).
    @ObservationIgnored public var now: () -> Date = { Date() }
    private var selectionBySpace: [Space.ID: UUID]

    var onDidMutate: (() -> Void)?
    public private(set) var mutationJournal: SidebarMutationJournal

    public init(spaces: [Space]? = nil, topAppsContainerID: UUID = UUID(), mutationJournal: SidebarMutationJournal? = nil) {
        self.mutationJournal = mutationJournal ?? SidebarMutationJournal()
        let defaultProfile = Profile.personalDefault()
        self.profiles = [defaultProfile]
        self.activeProfileID = defaultProfile.id
        self.lastActiveSpaceByProfile = [:]
        let initial: [Space]
        if let spaces, !spaces.isEmpty {
            initial = spaces.map { space in
                var copy = space
                copy.profileID = defaultProfile.id
                return copy
            }
        } else {
            initial = [Space(name: "Personal", profileID: defaultProfile.id)]
        }
        self.spaces = initial
        self.activeSpaceID = initial[0].id
        self.favoritesByProfile = [defaultProfile.id: []]
        self.topAppsContainerIDByProfile = [defaultProfile.id: topAppsContainerID]
        self.contentBySpace = [:]
        self.selectedItemID = nil
        self.selectionBySpace = [:]
        self.lastActiveSpaceByProfile = [defaultProfile.id: initial[0].id]
        self.boostLibrariesByProfileID = [defaultProfile.id: BoostLibraryOps.empty(for: defaultProfile.id)]
    }

    // MARK: - Profiles

    public var activeProfile: Profile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
    }

    public func profile(withID id: Profile.ID) -> Profile? {
        profiles.first(where: { $0.id == id })
    }

    public func spaces(in profileID: Profile.ID) -> [Space] {
        RankedSortable.sortedSpaces(spaces.filter { $0.profileID == profileID })
    }

    public var spacesInActiveProfile: [Space] {
        spaces(in: activeProfileID)
    }

    @discardableResult
    public func addProfile(
        name: String,
        avatar: ProfileAvatarDescriptor = .personalDefault(),
        themeColor: SpaceTheme = .default
    ) -> Profile {
        let profile = Profile(name: name, avatar: avatar, themeColor: themeColor)
        profiles.append(profile)
        boostLibrariesByProfileID[profile.id] = BoostLibraryOps.empty(for: profile.id)
        favoritesByProfile[profile.id] = []
        topAppsContainerIDByProfile[profile.id] = UUID()
        let space = Space(name: "Space 1", theme: themeColor, profileID: profile.id, sortRank: rankForNewSpace())
        spaces.append(space)
        contentBySpace[space.id] = SpaceContent()
        lastActiveSpaceByProfile[profile.id] = space.id
        notifyMutation(.insertSpace(id: space.id, sortRank: space.sortRank))
        return profile
    }

    public func renameProfile(_ id: Profile.ID, to name: String) -> ProfileMutationError? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return .profileNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .duplicateName }
        profiles[index].name = trimmed
        notifyMutation()
        return nil
    }

    /// Deletes a profile. Without `deletingSpaces` it must own no spaces; with
    /// it, the profile's spaces (and their tabs) go too (Arc DeleteProfileDialog).
    @discardableResult
    public func deleteProfile(_ id: Profile.ID, deletingSpaces: Bool = false) -> ProfileMutationError? {
        guard profiles.contains(where: { $0.id == id }) else { return .profileNotFound }
        guard profiles.count > 1 else { return .cannotDeleteLastProfile }
        let owned = spaces(in: id)
        if !owned.isEmpty, !deletingSpaces { return .profileOwnsSpaces(count: owned.count) }
        for space in owned {
            spaces.removeAll { $0.id == space.id }
            dropSpaceState(space.id)
            mutationJournal.record(.deleteSpace(id: space.id))
        }
        profiles.removeAll { $0.id == id }
        lastActiveSpaceByProfile[id] = nil
        favoritesByProfile[id] = nil
        topAppsContainerIDByProfile[id] = nil
        autoArchiveThresholdByProfile[id] = nil
        if spaces.isEmpty {
            let fallback = Space(name: "Personal", profileID: profiles[0].id, sortRank: LexoRank.initial)
            spaces = [fallback]
            contentBySpace[fallback.id] = SpaceContent()
        }
        if activeProfileID == id || !spaces.contains(where: { $0.id == activeSpaceID }) {
            activeProfileID = spaces.contains(where: { $0.profileID == profiles[0].id })
                ? profiles[0].id
                : spaces[0].profileID
            activeSpaceID = spaces(in: activeProfileID).first?.id ?? spaces[0].id
            activateProfileSpaceMemory(for: activeProfileID)
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        notifyMutation()
        return nil
    }

    public func moveProfile(from source: Int, to destination: Int) {
        guard profiles.indices.contains(source),
              destination >= 0, destination <= profiles.count,
              source != destination else { return }
        let profile = profiles.remove(at: source)
        let insertIndex = destination > source ? destination - 1 : destination
        profiles.insert(profile, at: min(max(insertIndex, 0), profiles.count))
        notifyMutation()
    }

    public func selectProfile(_ id: Profile.ID) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        if spaces.contains(where: { $0.id == activeSpaceID }) {
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
        }
        activeProfileID = id
        let candidates = spaces(in: id)
        if candidates.isEmpty {
            selectedItemID = nil
            notifyMutation()
            return
        }
        activateProfileSpaceMemory(for: id)
        notifyMutation()
    }

    private func activateProfileSpaceMemory(for profileID: Profile.ID) {
        let candidates = spaces(in: profileID)
        guard !candidates.isEmpty else { return }
        let target: Space.ID
        if let remembered = lastActiveSpaceByProfile[profileID],
           candidates.contains(where: { $0.id == remembered }) {
            target = remembered
        } else {
            target = candidates[0].id
        }
        selectSpaceWithinProfile(target)
    }

    private func selectSpaceWithinProfile(_ id: Space.ID) {
        guard id != activeSpaceID,
              spaces.contains(where: { $0.id == id }),
              space(withID: id)?.profileID == activeProfileID else { return }
        if let selected = selectedItemID {
            selectionBySpace[activeSpaceID] = selected
        }
        activeSpaceID = id
        lastActiveSpaceByProfile[activeProfileID] = id
        selectedItemID = restoredSelection(for: id)
    }

    // MARK: - Favorites

    public var favorites: [Tab] { favorites(in: activeProfileID) }

    public var topAppsContainerID: UUID { topAppsContainerID(for: activeProfileID) }

    public func favorites(in profileID: Profile.ID) -> [Tab] {
        RankedSortable.sortedTabs(favoritesByProfile[profileID] ?? [])
    }

    public func topAppsContainerID(for profileID: Profile.ID) -> UUID {
        topAppsContainerIDByProfile[profileID] ?? profileID
    }

    /// The profile whose favorites strip holds `tabID`.
    public func favoriteOwner(of tabID: Tab.ID) -> Profile.ID? {
        favoritesByProfile.first(where: { $0.value.contains(where: { $0.id == tabID }) })?.key
    }

    // MARK: - Spaces

    public var activeSpace: Space {
        spaces.first(where: { $0.id == activeSpaceID }) ?? spaces[0]
    }

    public func space(withID id: Space.ID) -> Space? {
        spaces.first(where: { $0.id == id })
    }

    @discardableResult
    public func addSpace(
        name: String,
        theme: SpaceTheme = .default,
        iconName: String = "circle.fill"
    ) -> Space {
        let space = Space(
            name: name,
            theme: theme,
            iconName: iconName,
            profileID: activeProfileID,
            sortRank: rankForNewSpace()
        )
        spaces.append(space)
        notifyMutation(.insertSpace(id: space.id, sortRank: space.sortRank))
        return space
    }

    /// Deletes a space and its tabs; the last remaining space cannot be deleted.
    @discardableResult
    public func removeSpace(_ id: Space.ID) -> Bool {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return false }
        let wasActive = activeSpaceID == id
        let owner = space(withID: id)?.profileID
        spaces.removeAll { $0.id == id }
        dropSpaceState(id)
        if wasActive {
            // Stay in the same profile when it still has a space.
            let next = owner.flatMap { spaces(in: $0).first } ?? spaces[0]
            activeSpaceID = next.id
            activeProfileID = next.profileID
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        notifyMutation(.deleteSpace(id: id))
        return true
    }

    private func dropSpaceState(_ id: Space.ID) {
        if let content = contentBySpace[id] {
            for folder in SidebarTree.folders(content.pinned) { expandedFolderIDs.remove(folder.id) }
        }
        contentBySpace[id] = nil
        selectionBySpace[id] = nil
        lastActiveSpaceByProfile = lastActiveSpaceByProfile.filter { $0.value != id }
    }

    @discardableResult
    public func renameSpace(_ id: Space.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        guard spaces[index].name != trimmed else { return true }
        spaces[index].name = trimmed
        notifyMutation(.upsertSpace(id: id))
        return true
    }

    public func setSpaceTheme(_ id: Space.ID, theme: SpaceTheme) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces[index].theme != theme else { return }
        spaces[index].theme = theme
        notifyMutation(.upsertSpace(id: id))
    }

    /// An SF Symbol name or a short text glyph (emoji).
    public func setSpaceIcon(_ id: Space.ID, iconName: String) {
        let trimmed = iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = spaces.firstIndex(where: { $0.id == id }),
              spaces[index].iconName != trimmed else { return }
        spaces[index].iconName = Space.isSymbolName(trimmed) ? trimmed : String(trimmed.prefix(2))
        notifyMutation(.upsertSpace(id: id))
    }

    public func selectSpace(_ id: Space.ID) {
        guard id != activeSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        if let selected = selectedItemID {
            selectionBySpace[activeSpaceID] = selected
        }
        if let profileID = space(withID: id)?.profileID, profileID != activeProfileID {
            activeProfileID = profileID
        }
        activeSpaceID = id
        if let profileID = space(withID: id)?.profileID {
            lastActiveSpaceByProfile[profileID] = id
        }
        selectedItemID = restoredSelection(for: id)
        notifyMutation(.focusSpace(spaceID: id))
    }

    /// Ctrl+1…9: the Nth space (0-based) of the active profile.
    @discardableResult
    public func selectSpace(atIndex index: Int) -> Bool {
        let profileSpaces = spacesInActiveProfile
        guard profileSpaces.indices.contains(index) else { return false }
        selectSpace(profileSpaces[index].id)
        return true
    }

    public func cycleSpace(forward: Bool = true) {
        let profileSpaces = spacesInActiveProfile
        guard profileSpaces.count > 1,
              let index = profileSpaces.firstIndex(where: { $0.id == activeSpaceID }) else { return }
        let count = profileSpaces.count
        let next = forward ? (index + 1) % count : (index - 1 + count) % count
        selectSpace(profileSpaces[next].id)
    }

    public func setUnpinnedShared(_ shared: Bool, for spaceID: Space.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].unpinnedShared = shared
        notifyMutation()
    }

    // MARK: - Lookup

    public func content(for spaceID: Space.ID) -> SpaceContent {
        var content = contentBySpace[spaceID] ?? SpaceContent()
        content.pinned = SidebarTree.sortedRecursively(content.pinned)
        content.today = SidebarTree.sortedRecursively(content.today)
        return content
    }

    /// Selectable sidebar rows in display order: the space's profile
    /// favorites, then pinned (folder contents inline), then today. Splits
    /// count as one row; folders themselves are not rows here.
    public func displayEntries(in spaceID: Space.ID? = nil) -> [SidebarEntry] {
        let id = spaceID ?? activeSpaceID
        let content = content(for: id)
        let profileID = space(withID: id)?.profileID ?? activeProfileID
        let favEntries = favorites(in: profileID).map { SidebarEntry.tab($0) }
        return favEntries + content.pinnedLeaves + content.todayLeaves
    }

    public func displayTabs(in spaceID: Space.ID? = nil) -> [Tab] {
        displayEntries(in: spaceID).flatMap { entry -> [Tab] in
            switch entry {
            case .tab(let tab): return [tab]
            case .split(let split): return split.tabs
            case .easel, .folder: return []
            }
        }
    }

    public var selectedTab: Tab? {
        guard let selectedItemID else { return nil }
        if easelRef(withSidebarID: selectedItemID) != nil { return nil }
        if let split = split(withID: selectedItemID) {
            return tab(withID: split.focusTabID)
        }
        return tab(withID: selectedItemID)
    }

    public var selectedTabID: Tab.ID? { selectedTab?.id }

    public func split(withID id: UUID) -> SplitViewItem? {
        for space in spaces {
            for entry in content(for: space.id).allLeaves {
                if case .split(let split) = entry, split.id == id { return split }
            }
        }
        return nil
    }

    public func tab(withID id: Tab.ID) -> Tab? {
        for favorites in favoritesByProfile.values {
            if let favorite = favorites.first(where: { $0.id == id }) { return favorite }
        }
        for space in spaces {
            let content = content(for: space.id)
            if let tab = SidebarTree.tabs(content.pinned + content.today).first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    public func kind(of id: Tab.ID) -> Tab.Kind? {
        switch locate(id) {
        case .favorite: return .favorite
        case .pinned: return .pinned
        case .today: return .today
        case .splitPane: return nil
        case nil: return nil
        }
    }

    /// The entry with `id` anywhere in a space tree or favorites strip.
    public func entry(withID id: UUID) -> SidebarEntry? {
        if let favorite = favoritesByProfile.values.lazy.compactMap({ $0.first(where: { $0.id == id }) }).first {
            return .tab(favorite)
        }
        for space in spaces {
            let content = content(for: space.id)
            if let found = SidebarTree.find(id, in: content.pinned + content.today) { return found }
        }
        return nil
    }

    /// The container directly holding `id` (folder, section or favorites strip).
    public func parent(of id: UUID) -> ItemParent? {
        if let owner = favoriteOwner(of: id) { return .favorites(owner) }
        for space in spaces {
            let content = contentBySpace[space.id] ?? SpaceContent()
            if let parent = SidebarTree.parentFolderID(of: id, in: content.pinned) {
                return parent.map { .folder($0) } ?? .section(spaceID: space.id, section: .pinned)
            }
            if let parent = SidebarTree.parentFolderID(of: id, in: content.today) {
                return parent.map { .folder($0) } ?? .section(spaceID: space.id, section: .unpinned)
            }
        }
        return nil
    }

    /// Sorted children of a container.
    public func entries(in parent: ItemParent) -> [SidebarEntry] {
        switch parent {
        case .favorites(let profileID):
            return favorites(in: profileID).map { .tab($0) }
        case .section(let spaceID, let section):
            return sectionEntries(for: section, spaceID: spaceID)
        case .folder(let folderID):
            return folder(withID: folderID)?.children ?? []
        }
    }

    // MARK: - Tab mutation

    @discardableResult
    public func addTab(
        kind: Tab.Kind,
        title: String,
        url: URL,
        in spaceID: Space.ID? = nil
    ) -> Tab {
        switch kind {
        case .favorite:
            let profileID = spaceID.flatMap { space(withID: $0)?.profileID } ?? activeProfileID
            var tab = Tab(kind: kind, title: title, url: url, lastActiveAt: now())
            let existing = favorites(in: profileID)
            tab.sortRank = rankForNewFavorite(at: existing.count, profileID: profileID)
            favoritesByProfile[profileID, default: []].append(tab)
            notifyMutation(.insertItem(
                id: tab.id,
                spaceID: nil,
                container: .favorite,
                sortRank: tab.sortRank
            ))
            return tab
        case .pinned:
            let id = spaceID ?? activeSpaceID
            var content = contentBySpace[id] ?? SpaceContent()
            let rank = rankForNewItem(in: content.pinned, atIndex: content.pinned.count)
            let tab = Tab(kind: kind, title: title, url: url, sortRank: rank, lastActiveAt: now())
            content.pinned.append(.tab(tab))
            contentBySpace[id] = content
            notifyMutation(.insertItem(id: tab.id, spaceID: id, container: .pinned, sortRank: rank))
            return tab
        case .today:
            let id = spaceID ?? activeSpaceID
            var content = contentBySpace[id] ?? SpaceContent()
            let rank = rankForNewItem(in: content.today, atIndex: 0)
            let tab = Tab(kind: kind, title: title, url: url, sortRank: rank, lastActiveAt: now())
            content.today.insert(.tab(tab), at: 0)
            contentBySpace[id] = content
            notifyMutation(.insertItem(id: tab.id, spaceID: id, container: .unpinned, sortRank: rank))
            return tab
        }
    }

    /// Removes a tab. Pinned and Today tabs go to the closed-tab stack and the
    /// archive (Arc keywords for Archive Tab include "Close"); a favorite is
    /// deleted outright (`unloadFavorite` is the Cmd+W path for favorites).
    public func closeTab(_ id: Tab.ID) {
        recordClosedTabIfNeeded(tabID: id)
        if let splitLocation = splitContaining(tabID: id) {
            let split = splitLocation.split
            if split.tabs.count == 2, let location = locateSplit(split.id) {
                let remaining = split.tabs.first(where: { $0.id != id })!
                var entries = sectionEntries(for: location.section, spaceID: location.spaceID)
                entries.removeAll { $0.id == split.id }
                let target = split.memberPlacements[remaining.id].map { index(for: $0) } ?? entries.count
                entries.insert(.tab(remaining), at: min(target, entries.count))
                setSectionEntries(entries, for: location.section, spaceID: location.spaceID)
                if selectedItemID == id || selectedItemID == split.id {
                    selectedItemID = remaining.id
                }
                notifyMutation()
                return
            }
            if split.tabs.count <= 2 {
                closeSplit(split.id)
            } else {
                var remaining = split
                let removedIndex = remaining.tabs.firstIndex(where: { $0.id == id })!
                remaining.tabs.remove(at: removedIndex)
                remaining.widthFactors.removeValue(forKey: id)
                remaining.memberPlacements.removeValue(forKey: id)
                if remaining.focusTabID == id {
                    remaining.focusTabID = remaining.tabs[min(removedIndex, remaining.tabs.count - 1)].id
                }
                remaining.widthFactors = SplitViewItem.normalizedFactors(remaining.widthFactors, tabIDs: remaining.tabs.map(\.id))
                replaceSplit(remaining)
                notifyMutation()
            }
            return
        }
        guard let location = locate(id) else { return }
        if let tab = tab(withID: id), case .pinned(let spaceID) = location {
            appendArchiveRecord(tab, spaceID: spaceID, reason: .manual)
        } else if let tab = tab(withID: id), case .today(let spaceID) = location {
            appendArchiveRecord(tab, spaceID: spaceID, reason: .manual)
        }
        let ordered = displayEntries()
        let index = ordered.firstIndex(where: { $0.id == id })
        removeFromContainer(id)
        reconcileSelectionAfterRemoval(removedID: id, priorIndex: index)
        notifyMutation(.deleteItem(id: id))
    }

    /// Cmd+W on a favorite: Arc unloads it and keeps it in the strip. The model
    /// only moves selection away; the shell drops the tab's engine.
    @discardableResult
    public func unloadFavorite(_ id: Tab.ID) -> Bool {
        guard case .favorite = locate(id) else { return false }
        if selectedItemID == id {
            let ordered = displayEntries()
            let index = ordered.firstIndex(where: { $0.id == id }) ?? 0
            let others = ordered.filter { $0.id != id }
            selectedItemID = others.isEmpty ? nil : others[min(index, others.count - 1)].id
            notifyMutation()
        }
        return true
    }

    /// Closes the split item and all contained tabs (tabs are not restored).
    public func closeSplit(_ splitID: SplitViewItem.ID) {
        guard let location = locateSplit(splitID),
              let split = split(withID: splitID) else { return }
        let priorIndex = displayEntries(in: location.spaceID).firstIndex(where: { $0.id == splitID })
        var section = sectionEntries(for: location.section, spaceID: location.spaceID)
        section.removeAll { $0.id == splitID }
        setSectionEntries(section, for: location.section, spaceID: location.spaceID)
        let tabIDs = Set(split.tabs.map(\.id))
        if let selected = selectedItemID, tabIDs.contains(selected) || selected == splitID {
            reconcileSelectionAfterRemoval(removedID: splitID, priorIndex: priorIndex)
        }
        notifyMutation(.deleteItem(id: splitID))
    }

    /// Reorders an entry within the container that holds it (favorites strip,
    /// section, or folder). `destinationIndex` is the index after removal.
    @discardableResult
    public func moveTab(_ id: Tab.ID, to destinationIndex: Int) -> Bool {
        guard let parent = parent(of: id) else { return false }
        return moveItem(id, to: destination(for: parent), index: destinationIndex)
    }

    @discardableResult
    public func moveEntry(_ id: UUID, to destinationIndex: Int, in spaceID: Space.ID, section: ItemContainerKind.SpaceSection) -> Bool {
        moveItem(id, to: .section(spaceID: spaceID, section: section), index: destinationIndex)
    }

    /// Moves an entry to any container: reorder, pin/unpin across sections,
    /// favorite/unfavorite, into or out of folders, or to another space.
    /// Rules: favorites hold plain tabs; folders hold tabs and folders and live
    /// in the pinned section; Today holds no folders; split panes move with
    /// their split. Tab kinds follow the destination. `index` counts the
    /// destination's children after the entry is removed.
    @discardableResult
    public func moveItem(_ id: UUID, to destination: ItemDestination, index: Int) -> Bool {
        guard let source = parent(of: id), let entry = entry(withID: id) else { return false }
        let target = resolvedParent(destination)
        guard canPlace(entry, in: target) else { return false }

        var removed = entry
        if case .favorites(let profileID) = source {
            favoritesByProfile[profileID]?.removeAll { $0.id == id }
        } else {
            removeFromContainer(id)
        }

        let kind: Tab.Kind
        switch target {
        case .favorites: kind = .favorite
        case .section(_, .pinned), .folder: kind = .pinned
        case .section(_, .unpinned): kind = .today
        }
        removed = SidebarTree.settingKind(kind, on: removed)

        let siblings = entries(in: target)
        let clamped = max(0, min(index, siblings.count))
        let rank = rankForNewItem(in: siblings, atIndex: clamped)
        var single = [removed]
        updateEntryRank(id, in: &single, newRank: rank)
        removed = single[0]

        switch target {
        case .favorites(let profileID):
            guard case .tab(let tab) = removed else { return false }
            favoritesByProfile[profileID, default: []].append(tab)
            notifyMutation(.moveItem(id: id, spaceID: nil, container: .favorite, sortRank: rank))
        case .section(let spaceID, let section):
            var entries = sectionEntries(for: section, spaceID: spaceID)
            entries.append(removed)
            setSectionEntries(entries, for: section, spaceID: spaceID)
            let container: SidebarItemContainer = section == .pinned ? .pinned : .unpinned
            notifyMutation(.moveItem(id: id, spaceID: spaceID, container: container, sortRank: rank))
        case .folder(let folderID):
            insertIntoFolder(removed, folderID: folderID)
            notifyMutation(.placeItemInFolder(id: id, folderID: folderID, sortRank: rank))
        }

        if let selected = selectedItemID, !displayEntries().contains(where: { $0.id == selected }) {
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        return true
    }

    /// Drop before or after a row: moves `id` into the container holding
    /// `targetID`, next to it (sidebar drag feedback line).
    @discardableResult
    public func moveItem(_ id: UUID, relativeTo targetID: UUID, after: Bool) -> Bool {
        guard id != targetID, let parent = parent(of: targetID) else { return false }
        let siblings = entries(in: parent).filter { $0.id != id }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
        return moveItem(id, to: destination(for: parent), index: after ? targetIndex + 1 : targetIndex)
    }

    @discardableResult
    public func pinTab(_ id: Tab.ID) -> Bool {
        guard case .today(let spaceID) = locate(id), case .tab = entry(withID: id) else { return false }
        let count = sectionEntries(for: .pinned, spaceID: spaceID).count
        return moveItem(id, to: .section(spaceID: spaceID, section: .pinned), index: count)
    }

    /// Moves a pinned tab (top level or in a folder) to the top of Today.
    @discardableResult
    public func unpinTab(_ id: Tab.ID) -> Bool {
        guard case .pinned(let spaceID) = locate(id), case .tab = entry(withID: id) else { return false }
        return moveItem(id, to: .section(spaceID: spaceID, section: .unpinned), index: 0)
    }

    /// Adds a pinned or Today tab to its space's profile favorites (end of strip).
    @discardableResult
    public func addToFavorites(_ id: Tab.ID) -> Bool {
        guard let spaceID = spaceContaining(tabID: id),
              case .tab = entry(withID: id),
              let profileID = space(withID: spaceID)?.profileID else { return false }
        return moveItem(id, to: .favorites(profileID), index: favorites(in: profileID).count)
    }

    public func updateTab(_ id: Tab.ID, title: String? = nil, url: URL? = nil) {
        guard updateTabInStore(id, { tab in
            if let title { tab.title = title }
            if let url {
                tab.url = url
                tab.faviconToken = Tab.makeFaviconToken(for: url)
            }
        }) else { return }
        notifyMutation(.upsertItem(id: id))
    }

    /// Sets (or with nil/blank clears) the user title that overrides the page title.
    @discardableResult
    public func renameTab(_ id: Tab.ID, to title: String?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard updateTabInStore(id, { $0.customTitle = custom }) else { return false }
        notifyMutation(.upsertItem(id: id))
        return true
    }

    public func setUnread(_ isUnread: Bool, for id: Tab.ID) {
        guard updateTabInStore(id, { $0.isUnread = isUnread }) else { return }
        notifyMutation()
    }

    /// Copies a tab right below itself; a favorite's copy opens at the top of Today.
    @discardableResult
    public func duplicateTab(_ id: Tab.ID) -> Tab? {
        guard let original = tab(withID: id), let parent = parent(of: id) else { return nil }
        if case .favorites = parent {
            let copy = addTab(kind: .today, title: original.title, url: original.url)
            renameTab(copy.id, to: original.customTitle)
            return tab(withID: copy.id)
        }
        let siblings = entries(in: parent)
        guard let sourceIndex = siblings.firstIndex(where: { $0.id == id }) else { return nil }
        let rank = rankForNewItem(in: siblings, atIndex: sourceIndex + 1)
        let copy = Tab(
            kind: original.kind,
            title: original.title,
            url: original.url,
            sortRank: rank,
            customTitle: original.customTitle,
            lastActiveAt: now()
        )
        switch parent {
        case .favorites:
            return nil
        case .section(let spaceID, let section):
            var entries = sectionEntries(for: section, spaceID: spaceID)
            entries.append(.tab(copy))
            setSectionEntries(entries, for: section, spaceID: spaceID)
            let container: SidebarItemContainer = section == .pinned ? .pinned : .unpinned
            notifyMutation(.insertItem(id: copy.id, spaceID: spaceID, container: container, sortRank: rank))
        case .folder(let folderID):
            insertIntoFolder(.tab(copy), folderID: folderID)
            notifyMutation(.placeItemInFolder(id: copy.id, folderID: folderID, sortRank: rank))
        }
        return copy
    }

    // MARK: - Selection

    public func selectTab(_ id: Tab.ID) {
        guard tab(withID: id) != nil else { return }
        if let splitLoc = splitContaining(tabID: id) {
            selectSplit(splitLoc.split.id, focusTabID: id)
            return
        }
        guard displayEntries().contains(where: { $0.id == id }) else { return }
        selectedItemID = id
        markActive(id)
        setUnread(false, for: id)
        notifyMutation()
    }

    public func selectSplit(_ splitID: SplitViewItem.ID, focusTabID: Tab.ID? = nil) {
        guard var split = split(withID: splitID) else { return }
        if let focusTabID, split.tabs.contains(where: { $0.id == focusTabID }) {
            split.focusTabID = focusTabID
            replaceSplit(split)
        }
        selectedItemID = splitID
        if let focus = tab(withID: split.focusTabID) {
            markActive(focus.id)
            setUnread(false, for: focus.id)
        }
        notifyMutation()
    }

    @discardableResult
    public func focusTab(_ id: Tab.ID) -> Bool {
        guard tab(withID: id) != nil else { return false }
        if let splitLoc = splitContaining(tabID: id) {
            if activeSpaceID != splitLoc.spaceID { selectSpace(splitLoc.spaceID) }
            selectSplit(splitLoc.split.id, focusTabID: id)
            return true
        }
        guard let location = locate(id) else { return false }
        switch location {
        case .favorite:
            if let owner = favoriteOwner(of: id), owner != activeProfileID { selectProfile(owner) }
            selectTab(id)
        case .pinned(let spaceID), .today(let spaceID):
            if activeSpaceID != spaceID { selectSpace(spaceID) }
            revealInFolders(id)
            selectTab(id)
        case .splitPane:
            break
        }
        return true
    }

    public func selectNextTab() { advanceSelection(by: 1) }
    public func selectPreviousTab() { advanceSelection(by: -1) }

    /// Stamps the tab's last-active time (auto-archive clock), without notifying.
    private func markActive(_ id: Tab.ID) {
        let stamp = now()
        updateTabInStore(id) { $0.lastActiveAt = stamp }
    }

    // MARK: - Closed tabs

    private func recordClosedTabIfNeeded(tabID: Tab.ID) {
        guard let tab = tab(withID: tabID) else { return }
        switch locate(tabID) {
        case .favorite:
            return
        case .splitPane:
            return
        case .pinned(let spaceID), .today(let spaceID):
            closedTabStack.push(ClosedTabRecord(tab: tab, spaceID: spaceID))
            notifyMutation()
        case nil:
            break
        }
    }

    @discardableResult
    public func reopenMostRecentClosedTab() -> Tab? {
        guard let record = closedTabStack.popMostRecent() else { return nil }
        archivedTabs.removeAll { $0.id == record.tab.id }
        let restored = Tab(
            kind: record.tab.kind == .pinned ? .pinned : .today,
            title: record.tab.title,
            url: record.tab.url,
            faviconToken: record.tab.faviconToken,
            isUnread: record.tab.isUnread,
            customTitle: record.tab.customTitle,
            lastActiveAt: now()
        )
        switch restored.kind {
        case .favorite:
            return nil
        case .pinned:
            var content = content(for: record.spaceID)
            content.pinned.append(.tab(restored))
            contentBySpace[record.spaceID] = content
        case .today:
            var content = content(for: record.spaceID)
            content.today.insert(.tab(restored), at: 0)
            contentBySpace[record.spaceID] = content
        }
        if spaces.contains(where: { $0.id == record.spaceID }) {
            selectSpace(record.spaceID)
        }
        selectTab(restored.id)
        notifyMutation()
        return restored
    }

    /// Moves a plain tab (from anywhere in a space, folders included) to the
    /// top of another space's Today section.
    @discardableResult
    public func moveTab(_ id: Tab.ID, toSpace destinationSpaceID: Space.ID) -> Bool {
        guard spaces.contains(where: { $0.id == destinationSpaceID }),
              tab(withID: id) != nil,
              let location = locate(id) else { return false }
        let wasSelected = selectedTabID == id
        switch location {
        case .favorite, .splitPane:
            return false
        case .pinned(let sid), .today(let sid):
            guard sid != destinationSpaceID else { return false }
        }
        guard moveItem(id, to: .section(spaceID: destinationSpaceID, section: .unpinned), index: 0) else {
            return false
        }
        if wasSelected {
            selectSpace(destinationSpaceID)
            selectTab(id)
        } else if selectedItemID == id {
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        notifyMutation()
        return true
    }

    public func bumpCommandUsage(_ commandID: String) {
        commandBarUsageBumps[commandID, default: 0] += 1
        notifyMutation()
    }

    // MARK: - Boosts

    public func boostLibrary(for profileID: Profile.ID? = nil) -> ProfileBoostLibrary {
        let id = profileID ?? activeProfileID
        return boostLibrariesByProfileID[id] ?? BoostLibraryOps.empty(for: id)
    }

    private func updateBoostLibrary(_ library: ProfileBoostLibrary) {
        boostLibrariesByProfileID[library.profileID] = library
        notifyMutation()
    }

    @discardableResult
    public func addBoost(_ package: BoostPackage, enabled: Bool? = nil) -> BoostLibraryMutationError? {
        var library = boostLibrary(for: activeProfileID)
        library.profileID = activeProfileID
        let defaultEnabled = enabled ?? !package.hasScript
        if let err = BoostLibraryOps.add(package, to: &library, enabled: defaultEnabled) {
            return err
        }
        updateBoostLibrary(library)
        return nil
    }

    @discardableResult
    public func duplicateBoost(packageID: UUID) -> BoostPackage? {
        var library = boostLibrary(for: activeProfileID)
        guard let copy = BoostLibraryOps.duplicate(packageID: packageID, in: &library) else { return nil }
        updateBoostLibrary(library)
        return copy
    }

    public func removeBoost(packageID: UUID) {
        var library = boostLibrary(for: activeProfileID)
        library.removePackage(id: packageID)
        updateBoostLibrary(library)
    }

    public func setBoostInstallationEnabled(packageID: UUID, enabled: Bool) {
        var library = boostLibrary(for: activeProfileID)
        guard BoostLibraryOps.setInstallationEnabled(packageID: packageID, enabled: enabled, library: &library) else {
            return
        }
        updateBoostLibrary(library)
    }

    public func setBoostScriptUserEnabled(packageID: UUID, enabled: Bool) {
        var library = boostLibrary(for: activeProfileID)
        guard BoostLibraryOps.setScriptUserEnabled(packageID: packageID, enabled: enabled, library: &library) else {
            return
        }
        updateBoostLibrary(library)
    }

    public func setBoostSpacePolicy(packageID: UUID, spaceID: Space.ID, policy: BoostSpacePolicy) {
        var library = boostLibrary(for: activeProfileID)
        guard BoostLibraryOps.setSpacePolicy(
            packageID: packageID,
            spaceID: spaceID,
            policy: policy,
            library: &library
        ) else { return }
        updateBoostLibrary(library)
    }

    public func setBoostMasterEnabled(_ enabled: Bool, profileID: Profile.ID? = nil) {
        let pid = profileID ?? activeProfileID
        var library = boostLibrary(for: pid)
        library.masterEnabled = enabled
        updateBoostLibrary(library)
    }

    @discardableResult
    public func updateBoostStyleCSS(packageID: UUID, css: String) -> Bool {
        var library = boostLibrary(for: activeProfileID)
        guard let package = library.package(id: packageID),
              let install = library.installation(for: packageID),
              let saved = BoostEditorSave.applySave(package: package, draftCSS: css) else {
            return false
        }
        library.upsertPackage(saved, installation: install)
        updateBoostLibrary(library)
        return true
    }

    @discardableResult
    public func createBoostForCurrentSite(name: String, css: String, pageURL: URL) -> BoostPackage? {
        guard let rule = BoostScopeMatcher.defaultRule(forPage: pageURL) else { return nil }
        let package = BoostPackage.newStyle(name: name, hostScope: [rule], css: css)
        guard addBoost(package) == nil else { return nil }
        return package
    }

    public func importBoostPackage(_ package: BoostPackage) -> BoostLibraryMutationError? {
        let enabled = BoostInterchange.defaultEnabledOnImport(package)
        return addBoost(package, enabled: enabled)
    }

    public func activeBoostEntries(for tab: Tab, isPrivate: Bool = false) -> [BoostRuntimeEntry] {
        let profileID = spaceContaining(tabID: tab.id).flatMap { spaceID in
            spaces.first(where: { $0.id == spaceID })?.profileID
        } ?? activeProfileID
        let spaceID = spaceContaining(tabID: tab.id)
        let context = BoostTabContext(
            profileID: profileID,
            spaceID: spaceID,
            url: tab.url,
            isPrivate: isPrivate
        )
        return BoostActivation.activeEntries(library: boostLibrary(for: profileID), context: context)
    }

    public func boostsMatchingPage(_ url: URL, profileID: Profile.ID? = nil) -> [(BoostPackage, BoostInstallation)] {
        BoostActivation.matchingForHost(library: boostLibrary(for: profileID), url: url)
    }

    // MARK: - Snapshot

    public func makeSnapshot() -> SidebarSnapshot {
        var tabsByID: [UUID: Tab] = [:]
        var topAppsByProfile: [Profile.ID: ItemContainerRecord] = [:]
        for profile in profiles {
            let favorites = favorites(in: profile.id)
            for tab in favorites { tabsByID[tab.id] = tab }
            topAppsByProfile[profile.id] = ItemContainerRecord(
                id: topAppsContainerID(for: profile.id),
                kind: .topApps,
                childIDs: favorites.map(\.id)
            )
        }
        var splitsByID: [UUID: SplitViewItem] = [:]
        var easelRefsByID: [UUID: SidebarEaselRef] = [:]
        var foldersByID: [UUID: SidebarFolderRecord] = [:]
        var spaceContainers: [Space.ID: SidebarSnapshot.SpaceContainerBundle] = [:]

        for space in spaces {
            let content = content(for: space.id)
            var pinnedIDs: [UUID] = []
            var todayIDs: [UUID] = []
            for entry in content.pinned {
                pinnedIDs.append(entry.id)
                ingest(entry, tabsByID: &tabsByID, splitsByID: &splitsByID, easelRefsByID: &easelRefsByID, foldersByID: &foldersByID)
            }
            for entry in content.today {
                todayIDs.append(entry.id)
                ingest(entry, tabsByID: &tabsByID, splitsByID: &splitsByID, easelRefsByID: &easelRefsByID, foldersByID: &foldersByID)
            }
            let pinnedRecord = ItemContainerRecord(
                id: space.pinnedContainerID,
                kind: .spaceItems(spaceID: space.id, section: .pinned),
                childIDs: pinnedIDs
            )
            let unpinnedRecord = ItemContainerRecord(
                id: space.unpinnedContainerID,
                kind: .spaceItems(spaceID: space.id, section: .unpinned),
                childIDs: todayIDs,
                unpinnedShared: space.unpinnedShared
            )
            spaceContainers[space.id] = SidebarSnapshot.SpaceContainerBundle(
                pinned: pinnedRecord,
                unpinned: unpinnedRecord
            )
        }

        let defaultProfileID = profiles[0].id
        let topApps = topAppsByProfile[defaultProfileID]
            ?? ItemContainerRecord(id: topAppsContainerID(for: defaultProfileID), kind: .topApps)

        let journalState = mutationJournal.snapshotTail()
        return SidebarSnapshot(
            schemaVersion: SidebarSnapshot.schemaVersion,
            lastFlushedSequence: journalState.lastFlushedSequence,
            journalPersistedTail: journalState.tail,
            profiles: profiles,
            activeProfileID: activeProfileID,
            lastActiveSpaceByProfile: lastActiveSpaceByProfile,
            spaces: spaces,
            activeSpaceID: activeSpaceID,
            selectedItemID: selectedItemID,
            selectionBySpace: selectionBySpace,
            topAppsContainer: topApps,
            spaceContainers: spaceContainers,
            tabsByID: tabsByID,
            splitsByID: splitsByID,
            closedTabStack: closedTabStack,
            commandBarUsageBumps: commandBarUsageBumps,
            littleArcWindows: littleArcWindows,
            archivedLittleArcWindows: archivedLittleArcWindows,
            boostLibrariesByProfileID: boostLibrariesByProfileID,
            easelRefsByID: easelRefsByID,
            capturesByID: capturesByID,
            topAppsContainersByProfileID: topAppsByProfile,
            foldersByID: foldersByID,
            expandedFolderIDs: expandedFolderIDs.sorted { $0.uuidString < $1.uuidString },
            archivedTabs: archivedTabs,
            autoArchiveThresholdByProfile: autoArchiveThresholdByProfile
        )
    }

    func applySnapshot(_ snapshot: SidebarSnapshot) {
        profiles = snapshot.profiles.isEmpty ? [Profile.personalDefault()] : snapshot.profiles
        activeProfileID = snapshot.activeProfileID
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
        lastActiveSpaceByProfile = snapshot.lastActiveSpaceByProfile
        let defaultProfileID = profiles[0].id
        if snapshot.spaces.isEmpty {
            spaces = [Space(name: "Personal", profileID: defaultProfileID)]
        } else {
            spaces = snapshot.spaces.map { space in
                var copy = space
                if !profiles.contains(where: { $0.id == copy.profileID }) {
                    copy.profileID = defaultProfileID
                }
                return copy
            }
        }
        // Schema 10 keys favorites by profile; older snapshots carry one global
        // strip, which belongs to the default (first) profile.
        var topApps = snapshot.topAppsContainersByProfileID.filter { key, _ in profiles.contains(where: { $0.id == key }) }
        if topApps.isEmpty {
            topApps = [defaultProfileID: snapshot.topAppsContainer]
        }
        favoritesByProfile = [:]
        topAppsContainerIDByProfile = [:]
        for profile in profiles {
            let record = topApps[profile.id]
            topAppsContainerIDByProfile[profile.id] = record?.id ?? UUID()
            favoritesByProfile[profile.id] = (record?.childIDs ?? []).compactMap { id in
                snapshot.tabsByID[id].map { tab in
                    var favorite = tab
                    favorite.kind = .favorite
                    return favorite
                }
            }
        }
        contentBySpace = [:]
        for space in spaces {
            guard let bundle = snapshot.spaceContainers[space.id] else {
                contentBySpace[space.id] = SpaceContent()
                continue
            }
            var visited = Set<UUID>()
            let pinned = bundle.pinned.childIDs.compactMap { resolveEntry(id: $0, snapshot: snapshot, visited: &visited) }
            let today = bundle.unpinned.childIDs.compactMap { resolveEntry(id: $0, snapshot: snapshot, visited: &visited) }
            contentBySpace[space.id] = SpaceContent(pinned: pinned, today: today)
            if let index = spaces.firstIndex(where: { $0.id == space.id }) {
                spaces[index].pinnedContainerID = bundle.pinned.id
                spaces[index].unpinnedContainerID = bundle.unpinned.id
                spaces[index].unpinnedShared = bundle.unpinned.unpinnedShared
            }
        }
        selectionBySpace = snapshot.selectionBySpace
        if spaces.contains(where: { $0.id == snapshot.activeSpaceID }) {
            activeSpaceID = snapshot.activeSpaceID
        } else {
            activeSpaceID = spaces[0].id
        }
        if let selected = snapshot.selectedItemID,
           displayEntries().contains(where: { $0.id == selected }) {
            selectedItemID = selected
        } else {
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        closedTabStack = snapshot.closedTabStack
        commandBarUsageBumps = snapshot.commandBarUsageBumps
        littleArcWindows = snapshot.littleArcWindows
        archivedLittleArcWindows = snapshot.archivedLittleArcWindows
        boostLibrariesByProfileID = snapshot.boostLibrariesByProfileID
        easelRefsByID = snapshot.easelRefsByID
        capturesByID = snapshot.capturesByID
        let liveFolderIDs = Set(spaces.flatMap { SidebarTree.folders(contentBySpace[$0.id]?.pinned ?? []).map(\.id) })
        expandedFolderIDs = Set(snapshot.expandedFolderIDs).intersection(liveFolderIDs)
        archivedTabs = TabArchivePolicy.pruned(snapshot.archivedTabs, now: now())
        autoArchiveThresholdByProfile = snapshot.autoArchiveThresholdByProfile
        for profile in profiles where boostLibrariesByProfileID[profile.id] == nil {
            boostLibrariesByProfileID[profile.id] = BoostLibraryOps.empty(for: profile.id)
        }
        if lastActiveSpaceByProfile[activeProfileID] == nil {
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
        }
        mutationJournal.restore(from: snapshot)
        assignRanksFromLegacyOrderIfNeeded()
        stampMissingLastActiveDates()
    }

    // MARK: - Internal helpers

    func assignRanksFromLegacyOrderIfNeeded() {
        for (profileID, list) in favoritesByProfile {
            var favorites = RankedSortable.sortedTabs(list)
            let favRanks = LexoRank.initialSequence(count: favorites.count)
            for index in favorites.indices where favorites[index].sortRank.isEmpty {
                favorites[index].sortRank = favRanks[index]
            }
            favoritesByProfile[profileID] = favorites
        }
        spaces = RankedSortable.sortedSpaces(spaces)
        let spaceRanks = LexoRank.initialSequence(count: spaces.count)
        for index in spaces.indices where spaces[index].sortRank.isEmpty {
            spaces[index].sortRank = spaceRanks[index]
        }
        for space in spaces {
            var content = contentBySpace[space.id] ?? SpaceContent()
            content.pinned = assignRanks(to: content.pinned)
            content.today = assignRanks(to: content.today)
            contentBySpace[space.id] = content
        }
    }

    /// Tabs saved before schema 10 have no last-active time: their
    /// auto-archive clock starts now (Arc keeps `autoArchiveStartTime`).
    private func stampMissingLastActiveDates() {
        let stamp = now()
        for (profileID, list) in favoritesByProfile {
            favoritesByProfile[profileID] = list.map { tab in
                var copy = tab
                if copy.lastActiveAt == nil { copy.lastActiveAt = stamp }
                return copy
            }
        }
        func stamped(_ entries: [SidebarEntry]) -> [SidebarEntry] {
            entries.map { entry in
                switch entry {
                case .tab(var tab):
                    if tab.lastActiveAt == nil { tab.lastActiveAt = stamp }
                    return .tab(tab)
                case .split(var split):
                    split.tabs = split.tabs.map { tab in
                        var copy = tab
                        if copy.lastActiveAt == nil { copy.lastActiveAt = stamp }
                        return copy
                    }
                    return .split(split)
                case .easel:
                    return entry
                case .folder(var folder):
                    folder.children = stamped(folder.children)
                    return .folder(folder)
                }
            }
        }
        for (spaceID, content) in contentBySpace {
            contentBySpace[spaceID] = SpaceContent(pinned: stamped(content.pinned), today: stamped(content.today))
        }
    }

    func restoredSelection(for spaceID: Space.ID) -> UUID? {
        if let remembered = selectionBySpace[spaceID],
           displayEntries(in: spaceID).contains(where: { $0.id == remembered }) {
            return remembered
        }
        return displayEntries(in: spaceID).first?.id
    }

    public func spaceContaining(tabID: Tab.ID) -> Space.ID? {
        switch locate(tabID) {
        case .pinned(let spaceID), .today(let spaceID): return spaceID
        case .splitPane(let spaceID, _): return spaceID
        case .favorite, nil: return nil
        }
    }

    /// The space holding any entry (tab, split, easel or folder) at any depth.
    public func spaceContaining(entryID: UUID) -> Space.ID? {
        switch parent(of: entryID) {
        case .section(let spaceID, _): return spaceID
        case .folder(let folderID): return spaceContaining(entryID: folderID)
        case .favorites, nil: return spaceContaining(tabID: entryID)
        }
    }

    public func snoozeAutoPiP(forHost host: String, now: Date = Date(), duration: TimeInterval = 3600) {
        autoPiPPolicy = AutoPiPPolicy.snooze(
            host: host,
            from: autoPiPPolicy,
            now: now,
            duration: duration
        )
        onDidMutate?()
    }

    public func setAutoPiPDisabled(forHost host: String) {
        autoPiPPolicy.perHost[host] = .disabled
        onDidMutate?()
    }

    func locate(_ id: Tab.ID) -> TabLocation? {
        if favoriteOwner(of: id) != nil { return .favorite }
        for space in spaces {
            let content = contentBySpace[space.id] ?? SpaceContent()
            if SidebarTree.contains(id, in: content.pinned) { return .pinned(space.id) }
            if SidebarTree.contains(id, in: content.today) { return .today(space.id) }
        }
        if let splitLoc = splitContaining(tabID: id) {
            return .splitPane(spaceID: splitLoc.spaceID, splitID: splitLoc.split.id)
        }
        return nil
    }

    /// Splits sit at section level (folders hold only tabs and folders).
    public func locateSplit(_ splitID: UUID) -> (spaceID: Space.ID, section: ItemContainerKind.SpaceSection)? {
        for space in spaces {
            let content = content(for: space.id)
            if content.pinned.contains(where: { $0.id == splitID }) {
                return (space.id, .pinned)
            }
            if content.today.contains(where: { $0.id == splitID }) {
                return (space.id, .unpinned)
            }
        }
        return nil
    }

    public func splitContaining(tabID: Tab.ID) -> (spaceID: Space.ID, split: SplitViewItem)? {
        for space in spaces {
            for entry in content(for: space.id).allLeaves {
                if case .split(let split) = entry,
                   split.tabs.contains(where: { $0.id == tabID }) {
                    return (space.id, split)
                }
            }
        }
        return nil
    }

    func sectionEntries(for section: ItemContainerKind.SpaceSection, spaceID: Space.ID) -> [SidebarEntry] {
        let content = content(for: spaceID)
        switch section {
        case .pinned: return content.pinned
        case .unpinned: return content.today
        }
    }

    func setSectionEntries(_ entries: [SidebarEntry], for section: ItemContainerKind.SpaceSection, spaceID: Space.ID) {
        var content = content(for: spaceID)
        switch section {
        case .pinned: content.pinned = entries
        case .unpinned: content.today = entries
        }
        contentBySpace[spaceID] = content
    }

    func replaceSplit(_ split: SplitViewItem) {
        guard let location = locateSplit(split.id) else { return }
        var entries = sectionEntries(for: location.section, spaceID: location.spaceID)
        guard let index = entries.firstIndex(where: { $0.id == split.id }) else { return }
        entries[index] = .split(split)
        setSectionEntries(entries, for: location.section, spaceID: location.spaceID)
    }

    /// Removes an entry from favorites or from any depth of a space tree.
    @discardableResult
    func removeFromContainer(_ id: UUID) -> SidebarEntry? {
        if let owner = favoriteOwner(of: id),
           let index = favoritesByProfile[owner]?.firstIndex(where: { $0.id == id }) {
            guard let removed = favoritesByProfile[owner]?.remove(at: index) else { return nil }
            return .tab(removed)
        }
        for space in spaces {
            var content = contentBySpace[space.id] ?? SpaceContent()
            if let removed = SidebarTree.remove(id, from: &content.pinned)
                ?? SidebarTree.remove(id, from: &content.today) {
                contentBySpace[space.id] = content
                return removed
            }
        }
        return nil
    }

    func reconcileSelectionAfterRemoval(removedID: UUID, priorIndex: Int?) {
        if selectedItemID == removedID {
            let remaining = displayEntries()
            if remaining.isEmpty {
                selectedItemID = nil
            } else if let priorIndex {
                selectedItemID = remaining[min(priorIndex, remaining.count - 1)].id
            } else {
                selectedItemID = remaining.first?.id
            }
        }
    }

    private func advanceSelection(by delta: Int) {
        let ordered = displayEntries()
        guard !ordered.isEmpty else { selectedItemID = nil; return }
        guard let selectedItemID,
              let index = ordered.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = delta >= 0 ? ordered.first?.id : ordered.last?.id
            notifyMutation()
            return
        }
        let count = ordered.count
        let next = ordered[(index + delta + count) % count]
        self.selectedItemID = next.id
        switch next {
        case .tab(let tab):
            markActive(tab.id)
            setUnread(false, for: tab.id)
        case .split(let split):
            markActive(split.focusTabID)
            setUnread(false, for: split.focusTabID)
        case .easel, .folder:
            break
        }
        notifyMutation()
    }

    /// Applies `change` to a tab wherever it lives (favorites, folders, split panes).
    @discardableResult
    func updateTabInStore(_ id: Tab.ID, _ change: (inout Tab) -> Void) -> Bool {
        if let owner = favoriteOwner(of: id),
           let index = favoritesByProfile[owner]?.firstIndex(where: { $0.id == id }) {
            change(&favoritesByProfile[owner]![index])
            return true
        }
        for space in spaces {
            var content = contentBySpace[space.id] ?? SpaceContent()
            if updateTabInEntries(&content.pinned, id: id, change)
                || updateTabInEntries(&content.today, id: id, change) {
                contentBySpace[space.id] = content
                return true
            }
        }
        return false
    }

    private func updateTabInEntries(_ entries: inout [SidebarEntry], id: Tab.ID, _ change: (inout Tab) -> Void) -> Bool {
        for index in entries.indices {
            switch entries[index] {
            case .tab(var tab) where tab.id == id:
                change(&tab)
                entries[index] = .tab(tab)
                return true
            case .split(var split):
                if let tabIndex = split.tabs.firstIndex(where: { $0.id == id }) {
                    change(&split.tabs[tabIndex])
                    entries[index] = .split(split)
                    return true
                }
            case .folder(var folder):
                if updateTabInEntries(&folder.children, id: id, change) {
                    entries[index] = .folder(folder)
                    return true
                }
            case .tab, .easel:
                continue
            }
        }
        return false
    }

    private func ingest(
        _ entry: SidebarEntry,
        tabsByID: inout [UUID: Tab],
        splitsByID: inout [UUID: SplitViewItem],
        easelRefsByID: inout [UUID: SidebarEaselRef],
        foldersByID: inout [UUID: SidebarFolderRecord]
    ) {
        switch entry {
        case .tab(let tab):
            tabsByID[tab.id] = tab
        case .split(let split):
            splitsByID[split.id] = split
            for tab in split.tabs { tabsByID[tab.id] = tab }
        case .easel(let ref):
            easelRefsByID[ref.id] = ref
        case .folder(let folder):
            foldersByID[folder.id] = SidebarFolderRecord(folder)
            for child in folder.children {
                ingest(child, tabsByID: &tabsByID, splitsByID: &splitsByID, easelRefsByID: &easelRefsByID, foldersByID: &foldersByID)
            }
        }
    }

    /// `visited` guards against a corrupt snapshot listing an id twice or a folder cycle.
    private func resolveEntry(id: UUID, snapshot: SidebarSnapshot, visited: inout Set<UUID>) -> SidebarEntry? {
        guard visited.insert(id).inserted else { return nil }
        if let record = snapshot.foldersByID[id] {
            let children = record.childIDs.compactMap { resolveEntry(id: $0, snapshot: snapshot, visited: &visited) }
            return .folder(SidebarFolder(id: record.id, title: record.title, children: children, sortRank: record.sortRank))
        }
        if let split = snapshot.splitsByID[id] { return .split(split) }
        if let easel = snapshot.easelRefsByID[id] { return .easel(easel) }
        if let tab = snapshot.tabsByID[id] { return .tab(tab) }
        return nil
    }

    func index(for placement: TabPlacement) -> Int {
        switch placement {
        case .favorite(let index), .pinned(_, let index), .today(_, let index):
            return index
        }
    }

    public func resolvedParent(_ destination: ItemDestination) -> ItemParent {
        switch destination {
        case .favorites(let profileID): return .favorites(profileID ?? activeProfileID)
        case .section(let spaceID, let section): return .section(spaceID: spaceID, section: section)
        case .folder(let folderID): return .folder(folderID)
        }
    }

    public func destination(for parent: ItemParent) -> ItemDestination {
        switch parent {
        case .favorites(let profileID): return .favorites(profileID)
        case .section(let spaceID, let section): return .section(spaceID: spaceID, section: section)
        case .folder(let folderID): return .folder(folderID)
        }
    }

    /// Placement rules for `moveItem` (see there).
    func canPlace(_ entry: SidebarEntry, in target: ItemParent) -> Bool {
        switch target {
        case .favorites(let profileID):
            guard profiles.contains(where: { $0.id == profileID }) else { return false }
            if case .tab = entry { return true }
            return false
        case .section(let spaceID, let section):
            guard spaces.contains(where: { $0.id == spaceID }) else { return false }
            return section == .pinned || !entry.isFolder
        case .folder(let folderID):
            guard folder(withID: folderID) != nil, folderID != entry.id else { return false }
            switch entry {
            case .tab:
                return true
            case .folder(let moving):
                // A folder cannot go inside itself or one of its descendants.
                return !SidebarTree.contains(folderID, in: moving.children)
            case .split, .easel:
                return false
            }
        }
    }

    /// Appends `entry` to a folder's children (its rank decides the position).
    func insertIntoFolder(_ entry: SidebarEntry, folderID: UUID) {
        for space in spaces {
            var content = contentBySpace[space.id] ?? SpaceContent()
            guard var children = SidebarTree.children(of: folderID, in: content.pinned) else { continue }
            children.append(entry)
            SidebarTree.setChildren(children, of: folderID, in: &content.pinned)
            contentBySpace[space.id] = content
            return
        }
    }

    /// Expands every folder on the path to `id` so a focused tab is visible.
    func revealInFolders(_ id: UUID) {
        for space in spaces {
            if let path = SidebarTree.ancestorFolderIDs(of: id, in: contentBySpace[space.id]?.pinned ?? []) {
                expandedFolderIDs.formUnion(path)
                return
            }
        }
    }

    func appendArchiveRecord(_ tab: Tab, spaceID: Space.ID?, reason: TabArchiveReason) {
        guard tab.url.absoluteString != "about:blank" else { return }
        archivedTabs.removeAll { $0.id == tab.id }
        archivedTabs.append(ArchivedTabRecord(tab: tab, spaceID: spaceID, archivedAt: now(), reason: reason))
        archivedTabs = TabArchivePolicy.pruned(archivedTabs, now: now())
    }

    // MARK: - Sample content

    public static func sample() -> SidebarStore {
        let store = SidebarStore()
        let personal = store.spaces[0].id
        store.spaces[0].name = "Personal"
        store.spaces[0].theme = SpaceTheme.presets[0]
        store.spaces[0].iconName = "house.fill"
        let work = store.addSpace(
            name: "Work",
            theme: SpaceTheme.presets[1],
            iconName: "briefcase.fill"
        )

        store.addTab(kind: .favorite, title: "GitHub", url: URL(string: "https://github.com")!)
        store.addTab(kind: .favorite, title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!)

        store.addTab(kind: .pinned, title: "Hacker News", url: URL(string: "https://news.ycombinator.com")!, in: personal)
        let swiftDocs = store.addTab(kind: .today, title: "SwiftUI Documentation", url: URL(string: "https://developer.apple.com/documentation/swiftui")!, in: personal)

        store.addTab(kind: .pinned, title: "Swift Forums", url: URL(string: "https://forums.swift.org")!, in: work.id)
        store.addTab(kind: .today, title: "Swift Package Index", url: URL(string: "https://swiftpackageindex.com")!, in: work.id)

        store.selectTab(swiftDocs.id)
        return store
    }
}
