import Foundation
import Observation

/// The sidebar's single source of truth. Pure Swift, no UI-framework imports,
/// so the whole model is unit-testable and could later be shared with an
/// engine layer or sync layer.
@Observable
public final class SidebarStore {

    /// The per-space tab sections (entries may be plain tabs or split items).
    public struct SpaceContent: Equatable, Codable {
        public var pinned: [SidebarEntry]
        public var today: [SidebarEntry]

        public init(pinned: [SidebarEntry] = [], today: [SidebarEntry] = []) {
            self.pinned = pinned
            self.today = today
        }

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
        case pinned(Space.ID)
        case today(Space.ID)
        case splitPane(spaceID: Space.ID, splitID: SplitViewItem.ID)
    }

    public private(set) var profiles: [Profile]
    public private(set) var activeProfileID: Profile.ID
    public private(set) var lastActiveSpaceByProfile: [Profile.ID: Space.ID]
    public private(set) var spaces: [Space]
    public private(set) var activeSpaceID: Space.ID
    public private(set) var favorites: [Tab]
    public private(set) var topAppsContainerID: UUID
    public private(set) var contentBySpace: [Space.ID: SpaceContent]
    public internal(set) var selectedItemID: UUID?
    public private(set) var closedTabStack = ClosedTabStack()
    public internal(set) var commandBarUsageBumps: [String: Int] = [:]
    public internal(set) var littleArcWindows: [LittleArcWindow] = []
    public internal(set) var archivedLittleArcWindows: [ArchivedLittleArcWindow] = []
    public private(set) var boostLibrariesByProfileID: [Profile.ID: ProfileBoostLibrary] = [:]
    public internal(set) var easelRefsByID: [UUID: SidebarEaselRef] = [:]
    public internal(set) var capturesByID: [UUID: CaptureRecord] = [:]
    public var autoPiPPolicy = AutoPiPPolicyState()
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
        self.favorites = []
        self.topAppsContainerID = topAppsContainerID
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
        let space = Space(name: "Space 1", theme: themeColor, profileID: profile.id)
        spaces.append(space)
        contentBySpace[space.id] = SpaceContent()
        lastActiveSpaceByProfile[profile.id] = space.id
        notifyMutation()
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

    @discardableResult
    public func deleteProfile(_ id: Profile.ID) -> ProfileMutationError? {
        guard profiles.contains(where: { $0.id == id }) else { return .profileNotFound }
        let owned = spaces(in: id)
        guard owned.isEmpty else { return .profileOwnsSpaces(count: owned.count) }
        guard profiles.count > 1 else { return .cannotDeleteLastProfile }
        profiles.removeAll { $0.id == id }
        lastActiveSpaceByProfile[id] = nil
        if activeProfileID == id {
            activeProfileID = profiles[0].id
            activateProfileSpaceMemory(for: activeProfileID)
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

    public func removeSpace(_ id: Space.ID) {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return }
        spaces.removeAll { $0.id == id }
        contentBySpace[id] = nil
        selectionBySpace[id] = nil
        lastActiveSpaceByProfile = lastActiveSpaceByProfile.filter { $0.value != id }
        if activeSpaceID == id {
            activeSpaceID = spaces[0].id
            activeProfileID = spaces[0].profileID
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
            selectedItemID = restoredSelection(for: activeSpaceID)
        }
        notifyMutation(.deleteSpace(id: id))
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
        content.pinned = RankedSortable.sortedEntries(content.pinned)
        content.today = RankedSortable.sortedEntries(content.today)
        return content
    }

    /// Sidebar rows in display order: favorites, pinned, today (splits count as one row).
    public func displayEntries(in spaceID: Space.ID? = nil) -> [SidebarEntry] {
        let id = spaceID ?? activeSpaceID
        let content = content(for: id)
        let favEntries = RankedSortable.sortedTabs(favorites).map { SidebarEntry.tab($0) }
        return favEntries + content.pinned + content.today
    }

    public func displayTabs(in spaceID: Space.ID? = nil) -> [Tab] {
        displayEntries(in: spaceID).flatMap { entry -> [Tab] in
            switch entry {
            case .tab(let tab): return [tab]
            case .split(let split): return split.tabs
            case .easel: return []
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
            for entry in content(for: space.id).pinned + content(for: space.id).today {
                if case .split(let split) = entry, split.id == id { return split }
            }
        }
        return nil
    }

    public func tab(withID id: Tab.ID) -> Tab? {
        if let favorite = favorites.first(where: { $0.id == id }) { return favorite }
        for space in spaces {
            let content = content(for: space.id)
            for entry in content.pinned + content.today {
                switch entry {
                case .tab(let tab):
                    if tab.id == id { return tab }
                case .split(let split):
                    if let tab = split.tabs.first(where: { $0.id == id }) { return tab }
                case .easel:
                    continue
                }
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
            var tab = Tab(kind: kind, title: title, url: url)
            tab.sortRank = rankForNewFavorite(at: favorites.count)
            favorites.append(tab)
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
            var tab = Tab(kind: kind, title: title, url: url, sortRank: rank)
            content.pinned.append(.tab(tab))
            contentBySpace[id] = content
            notifyMutation(.insertItem(id: tab.id, spaceID: id, container: .pinned, sortRank: rank))
            return tab
        case .today:
            let id = spaceID ?? activeSpaceID
            var content = contentBySpace[id] ?? SpaceContent()
            let rank = rankForNewItem(in: content.today, atIndex: 0)
            var tab = Tab(kind: kind, title: title, url: url, sortRank: rank)
            content.today.insert(.tab(tab), at: 0)
            contentBySpace[id] = content
            notifyMutation(.insertItem(id: tab.id, spaceID: id, container: .unpinned, sortRank: rank))
            return tab
        }
    }

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
        guard locate(id) != nil else { return }
        let ordered = displayEntries()
        let index = ordered.firstIndex(where: { $0.id == id })
        removeFromContainer(id)
        reconcileSelectionAfterRemoval(removedID: id, priorIndex: index)
        notifyMutation(.deleteItem(id: id))
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

    @discardableResult
    public func moveTab(_ id: Tab.ID, to destinationIndex: Int) -> Bool {
        guard let location = locate(id) else { return false }
        switch location {
        case .favorite:
            guard let from = favorites.firstIndex(where: { $0.id == id }) else { return false }
            var tab = favorites.remove(at: from)
            let clamped = max(0, min(destinationIndex, favorites.count))
            let rank = rankForNewFavorite(at: clamped)
            tab.sortRank = rank
            favorites.insert(tab, at: clamped)
            notifyMutation(.moveItem(id: id, spaceID: nil, container: .favorite, sortRank: rank))
        case .pinned(let spaceID):
            var entries = sectionEntries(for: .pinned, spaceID: spaceID)
            guard let from = entries.firstIndex(where: { $0.id == id }) else { return false }
            let entry = entries.remove(at: from)
            let clamped = max(0, min(destinationIndex, entries.count))
            let rank = rankForNewItem(in: entries, atIndex: clamped)
            entries.insert(entry, at: clamped)
            updateEntryRank(id, in: &entries, newRank: rank)
            setSectionEntries(entries, for: .pinned, spaceID: spaceID)
            notifyMutation(.moveItem(id: id, spaceID: spaceID, container: .pinned, sortRank: rank))
        case .today(let spaceID):
            var entries = sectionEntries(for: .unpinned, spaceID: spaceID)
            guard let from = entries.firstIndex(where: { $0.id == id }) else { return false }
            let entry = entries.remove(at: from)
            let clamped = max(0, min(destinationIndex, entries.count))
            let rank = rankForNewItem(in: entries, atIndex: clamped)
            entries.insert(entry, at: clamped)
            updateEntryRank(id, in: &entries, newRank: rank)
            setSectionEntries(entries, for: .unpinned, spaceID: spaceID)
            notifyMutation(.moveItem(id: id, spaceID: spaceID, container: .unpinned, sortRank: rank))
        case .splitPane:
            return false
        }
        return true
    }

    @discardableResult
    public func moveEntry(_ id: UUID, to destinationIndex: Int, in spaceID: Space.ID, section: ItemContainerKind.SpaceSection) -> Bool {
        var entries = sectionEntries(for: section, spaceID: spaceID)
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = entries.remove(at: from)
        let clamped = max(0, min(destinationIndex, entries.count))
        let rank = rankForNewItem(in: entries, atIndex: clamped)
        entries.insert(entry, at: clamped)
        updateEntryRank(id, in: &entries, newRank: rank)
        setSectionEntries(entries, for: section, spaceID: spaceID)
        let container: SidebarItemContainer = section == .pinned ? .pinned : .unpinned
        notifyMutation(.moveItem(id: id, spaceID: spaceID, container: container, sortRank: rank))
        return true
    }

    @discardableResult
    public func pinTab(_ id: Tab.ID) -> Bool {
        guard case .today(let spaceID) = locate(id) else { return false }
        var content = content(for: spaceID)
        guard let index = content.today.firstIndex(where: { $0.id == id }),
              case .tab(var tab) = content.today[index] else { return false }
        content.today.remove(at: index)
        tab.kind = .pinned
        let rank = rankForNewItem(in: content.pinned, atIndex: content.pinned.count)
        tab.sortRank = rank
        content.pinned.append(.tab(tab))
        contentBySpace[spaceID] = content
        notifyMutation(.moveItem(id: id, spaceID: spaceID, container: .pinned, sortRank: rank))
        return true
    }

    @discardableResult
    public func unpinTab(_ id: Tab.ID) -> Bool {
        guard case .pinned(let spaceID) = locate(id) else { return false }
        var content = content(for: spaceID)
        guard let index = content.pinned.firstIndex(where: { $0.id == id }),
              case .tab(var tab) = content.pinned[index] else { return false }
        content.pinned.remove(at: index)
        tab.kind = .today
        let rank = rankForNewItem(in: content.today, atIndex: 0)
        tab.sortRank = rank
        content.today.insert(.tab(tab), at: 0)
        contentBySpace[spaceID] = content
        notifyMutation(.moveItem(id: id, spaceID: spaceID, container: .unpinned, sortRank: rank))
        return true
    }

    public func updateTab(_ id: Tab.ID, title: String? = nil, url: URL? = nil) {
        guard updateTabInStore(id, title: title, url: url) else { return }
        notifyMutation(.upsertItem(id: id))
    }

    public func setUnread(_ isUnread: Bool, for id: Tab.ID) {
        guard updateTabInStore(id, unread: isUnread) else { return }
        notifyMutation()
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
            selectTab(id)
        case .pinned(let spaceID), .today(let spaceID):
            if activeSpaceID != spaceID { selectSpace(spaceID) }
            selectTab(id)
        case .splitPane:
            break
        }
        return true
    }

    public func selectNextTab() { advanceSelection(by: 1) }
    public func selectPreviousTab() { advanceSelection(by: -1) }

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
        let restored = Tab(
            kind: record.tab.kind == .pinned ? .pinned : .today,
            title: record.tab.title,
            url: record.tab.url,
            faviconToken: record.tab.faviconToken,
            isUnread: record.tab.isUnread
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

    @discardableResult
    public func moveTab(_ id: Tab.ID, toSpace destinationSpaceID: Space.ID) -> Bool {
        guard spaces.contains(where: { $0.id == destinationSpaceID }),
              let tab = tab(withID: id),
              let location = locate(id) else { return false }
        let wasSelected = selectedTabID == id
        switch location {
        case .favorite, .splitPane:
            return false
        case .pinned(let sid):
            guard sid != destinationSpaceID else { return false }
            var source = content(for: sid)
            source.pinned.removeAll { $0.id == id }
            contentBySpace[sid] = source
            var dest = content(for: destinationSpaceID)
            var moved = tab
            moved.kind = .today
            dest.today.insert(.tab(moved), at: 0)
            contentBySpace[destinationSpaceID] = dest
        case .today(let sid):
            guard sid != destinationSpaceID else { return false }
            var source = content(for: sid)
            source.today.removeAll { $0.id == id }
            contentBySpace[sid] = source
            var dest = content(for: destinationSpaceID)
            var moved = tab
            moved.kind = .today
            dest.today.insert(.tab(moved), at: 0)
            contentBySpace[destinationSpaceID] = dest
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
        for tab in favorites { tabsByID[tab.id] = tab }
        var splitsByID: [UUID: SplitViewItem] = [:]
        var easelRefsByID: [UUID: SidebarEaselRef] = [:]
        var spaceContainers: [Space.ID: SidebarSnapshot.SpaceContainerBundle] = [:]

        for space in spaces {
            let content = content(for: space.id)
            var pinnedIDs: [UUID] = []
            var todayIDs: [UUID] = []
            for entry in content.pinned {
                pinnedIDs.append(entry.id)
                ingest(entry, tabsByID: &tabsByID, splitsByID: &splitsByID, easelRefsByID: &easelRefsByID)
            }
            for entry in content.today {
                todayIDs.append(entry.id)
                ingest(entry, tabsByID: &tabsByID, splitsByID: &splitsByID, easelRefsByID: &easelRefsByID)
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

        let topApps = ItemContainerRecord(
            id: topAppsContainerID,
            kind: .topApps,
            childIDs: favorites.map(\.id)
        )

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
            capturesByID: capturesByID
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
        topAppsContainerID = snapshot.topAppsContainer.id
        favorites = snapshot.topAppsContainer.childIDs.compactMap { snapshot.tabsByID[$0] }
        contentBySpace = [:]
        for space in spaces {
            guard let bundle = snapshot.spaceContainers[space.id] else {
                contentBySpace[space.id] = SpaceContent()
                continue
            }
            let pinned = bundle.pinned.childIDs.compactMap { resolveEntry(id: $0, snapshot: snapshot) }
            let today = bundle.unpinned.childIDs.compactMap { resolveEntry(id: $0, snapshot: snapshot) }
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
        for profile in profiles where boostLibrariesByProfileID[profile.id] == nil {
            boostLibrariesByProfileID[profile.id] = BoostLibraryOps.empty(for: profile.id)
        }
        if lastActiveSpaceByProfile[activeProfileID] == nil {
            lastActiveSpaceByProfile[activeProfileID] = activeSpaceID
        }
        mutationJournal.restore(from: snapshot)
        assignRanksFromLegacyOrderIfNeeded()
    }

    // MARK: - Internal helpers

    func assignRanksFromLegacyOrderIfNeeded() {
        favorites = RankedSortable.sortedTabs(favorites)
        let favRanks = LexoRank.initialSequence(count: favorites.count)
        for index in favorites.indices where favorites[index].sortRank.isEmpty {
            favorites[index].sortRank = favRanks[index]
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

    private func restoredSelection(for spaceID: Space.ID) -> UUID? {
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
        if favorites.contains(where: { $0.id == id }) { return .favorite }
        for space in spaces {
            let content = content(for: space.id)
            if content.pinned.contains(where: { $0.id == id }) { return .pinned(space.id) }
            if content.today.contains(where: { $0.id == id }) { return .today(space.id) }
        }
        if let splitLoc = splitContaining(tabID: id) {
            return .splitPane(spaceID: splitLoc.spaceID, splitID: splitLoc.split.id)
        }
        return nil
    }

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
            for entry in content(for: space.id).pinned + content(for: space.id).today {
                if case .split(let split) = entry,
                   split.tabs.contains(where: { $0.id == tabID }) {
                    return (space.id, split)
                }
            }
        }
        return nil
    }

    private func sectionArray(for location: TabLocation) -> [Tab] {
        switch location {
        case .favorite: return favorites
        case .pinned(let spaceID):
            return content(for: spaceID).pinned.compactMap { entry in
                if case .tab(let tab) = entry { return tab }
                return nil
            }
        case .today(let spaceID):
            return content(for: spaceID).today.compactMap { entry in
                if case .tab(let tab) = entry { return tab }
                return nil
            }
        case .splitPane: return []
        }
    }

    private func setSectionArray(_ array: [Tab], for location: TabLocation) {
        switch location {
        case .favorite:
            favorites = array
        case .pinned(let spaceID):
            var content = content(for: spaceID)
            content.pinned = mergeTabOrder(entries: content.pinned, tabs: array)
            contentBySpace[spaceID] = content
        case .today(let spaceID):
            var content = content(for: spaceID)
            content.today = mergeTabOrder(entries: content.today, tabs: array)
            contentBySpace[spaceID] = content
        case .splitPane:
            break
        }
    }

    private func mergeTabOrder(entries: [SidebarEntry], tabs: [Tab]) -> [SidebarEntry] {
        var tabMap = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var output: [SidebarEntry] = []
        for entry in entries {
            switch entry {
            case .split, .easel:
                output.append(entry)
            case .tab(let tab):
                if tabMap[tab.id] != nil {
                    output.append(.tab(tabMap[tab.id]!))
                    tabMap.removeValue(forKey: tab.id)
                }
            }
        }
        for tab in tabs where tabMap[tab.id] != nil {
            output.append(.tab(tab))
        }
        return output
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

    private func removeFromContainer(_ id: Tab.ID) {
        guard let location = locate(id) else { return }
        switch location {
        case .favorite:
            favorites.removeAll { $0.id == id }
        case .pinned(let spaceID):
            var content = content(for: spaceID)
            content.pinned.removeAll { $0.id == id }
            contentBySpace[spaceID] = content
        case .today(let spaceID):
            var content = content(for: spaceID)
            content.today.removeAll { $0.id == id }
            contentBySpace[spaceID] = content
        case .splitPane:
            break
        }
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
            setUnread(false, for: tab.id)
        case .split(let split):
            setUnread(false, for: split.focusTabID)
        case .easel:
            break
        }
        notifyMutation()
    }

    @discardableResult
    private func updateTabInStore(_ id: Tab.ID, title: String? = nil, url: URL? = nil, unread: Bool? = nil) -> Bool {
        if var favoriteIndex = favorites.firstIndex(where: { $0.id == id }) {
            if let title { favorites[favoriteIndex].title = title }
            if let url {
                favorites[favoriteIndex].url = url
                favorites[favoriteIndex].faviconToken = Tab.makeFaviconToken(for: url)
            }
            if let unread { favorites[favoriteIndex].isUnread = unread }
            return true
        }
        for space in spaces {
            var content = content(for: space.id)
            if updateTabInEntries(&content.pinned, id: id, title: title, url: url, unread: unread)
                || updateTabInEntries(&content.today, id: id, title: title, url: url, unread: unread) {
                contentBySpace[space.id] = content
                return true
            }
        }
        return false
    }

    private func updateTabInEntries(
        _ entries: inout [SidebarEntry],
        id: Tab.ID,
        title: String?,
        url: URL?,
        unread: Bool?
    ) -> Bool {
        for index in entries.indices {
            switch entries[index] {
            case .tab(var tab) where tab.id == id:
                if let title { tab.title = title }
                if let url {
                    tab.url = url
                    tab.faviconToken = Tab.makeFaviconToken(for: url)
                }
                if let unread { tab.isUnread = unread }
                entries[index] = .tab(tab)
                return true
            case .split(var split):
                if let tabIndex = split.tabs.firstIndex(where: { $0.id == id }) {
                    if let title { split.tabs[tabIndex].title = title }
                    if let url {
                        split.tabs[tabIndex].url = url
                        split.tabs[tabIndex].faviconToken = Tab.makeFaviconToken(for: url)
                    }
                    if let unread { split.tabs[tabIndex].isUnread = unread }
                    entries[index] = .split(split)
                    return true
                }
            case .easel:
                continue
            default:
                continue
            }
        }
        return false
    }

    private func ingest(
        _ entry: SidebarEntry,
        tabsByID: inout [UUID: Tab],
        splitsByID: inout [UUID: SplitViewItem],
        easelRefsByID: inout [UUID: SidebarEaselRef]
    ) {
        switch entry {
        case .tab(let tab):
            tabsByID[tab.id] = tab
        case .split(let split):
            splitsByID[split.id] = split
            for tab in split.tabs { tabsByID[tab.id] = tab }
        case .easel(let ref):
            easelRefsByID[ref.id] = ref
        }
    }

    private func resolveEntry(id: UUID, snapshot: SidebarSnapshot) -> SidebarEntry? {
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

