import Foundation

/// Wave 19 sidebar behavior (SIDEBAR-SPEC §3.1.2, §4.1–4.3, §4.11): pinned
/// tabs keep their saved URL and unload on Cmd+W, Cmd+1…9 select by
/// position, items move to another space keeping their section, and Today
/// can be cleared in one step.
extension SidebarStore {

    // MARK: - Pinned tabs

    /// Cmd+W on a pinned tab (top level or in a folder): Arc unloads it, keeps
    /// it in the sidebar and returns it to its saved URL. The model moves the
    /// selection away and resets the URL; the shell drops the tab's engine.
    /// Split panes are not unloaded this way.
    @discardableResult
    public func unloadPinnedTab(_ id: Tab.ID) -> Bool {
        guard case .pinned = locate(id), case .tab = entry(withID: id) else { return false }
        if selectedItemID == id {
            // A saved pin is not an open-tab successor. Only Today can take
            // focus; otherwise leave the space empty (including folder peeks).
            selectedItemID = content(for: activeSpaceID).todayLeaves.first?.id
        }
        resetTabToSavedURL(id)
        notifyMutation()
        return true
    }

    /// Reset Tab to Original URL: a pinned tab goes back to the URL and title
    /// it was pinned with. Returns false when there is nothing to reset.
    @discardableResult
    public func resetTabToSavedURL(_ id: Tab.ID) -> Bool {
        guard let tab = tab(withID: id), tab.isAwayFromSavedURL, let saved = tab.savedURL else { return false }
        let title = tab.savedTitle ?? tab.title
        updateTabInStore(id) { tab in
            tab.url = saved
            tab.title = title
            tab.faviconToken = Tab.makeFaviconToken(for: saved)
        }
        notifyMutation(.upsertItem(id: id))
        return true
    }

    /// Reset all tabs in this Space: every pinned tab of the space (folders
    /// included) that navigated away. Returns the reset tab ids.
    @discardableResult
    public func resetPinnedTabs(in spaceID: Space.ID? = nil) -> [Tab.ID] {
        let id = spaceID ?? activeSpaceID
        let pinned = SidebarTree.tabs(content(for: id).pinned).filter(\.isAwayFromSavedURL)
        return pinned.map(\.id).filter { resetTabToSavedURL($0) }
    }

    /// Makes the pinned tab's current page its saved URL.
    @discardableResult
    public func updateSavedURLToCurrent(_ id: Tab.ID) -> Bool {
        guard let tab = tab(withID: id), tab.isAwayFromSavedURL else { return false }
        updateTabInStore(id) { tab in
            tab.savedURL = tab.url
            tab.savedTitle = tab.title
        }
        notifyMutation(.upsertItem(id: id))
        return true
    }

    // MARK: - Cmd+1…9

    /// Arc/Chrome "Switch to Nth Tab": 1…8 select that row in display order
    /// (favorites, pinned, Today; a split or easel is one row), 9 the last.
    /// Returns the selected entry id, nil when there is no such row.
    @discardableResult
    public func selectItem(atPosition number: Int, includingFavorites: Bool = true) -> UUID? {
        let profileID = activeSpace.profileID
        let favoriteIDs = Set(favorites(in: profileID).map(\.id))
        let rows = displayEntries().filter { includingFavorites || !favoriteIDs.contains($0.id) }
        guard (1 ... 9).contains(number), !rows.isEmpty else { return nil }
        let index = number == 9 ? rows.count - 1 : number - 1
        guard rows.indices.contains(index) else { return nil }
        let entry = rows[index]
        switch entry {
        case .tab(let tab): selectTab(tab.id)
        case .split(let split): selectSplit(split.id)
        case .easel(let ref): selectEasel(ref.id)
        case .folder: return nil
        }
        return entry.id
    }

    // MARK: - Move to another space

    /// Drops an entry (tab, folder, split or easel) on another space: it keeps
    /// its section, landing at the end of Pinned or the top of Today (Arc
    /// `SidebarGlobalMoveOperation`). Favorites stay with their profile.
    /// A selected item follows to the destination space.
    @discardableResult
    public func moveEntry(_ id: UUID, toSpace destinationSpaceID: Space.ID) -> Bool {
        guard space(withID: destinationSpaceID) != nil,
              let source = spaceContaining(entryID: id), source != destinationSpaceID,
              let parent = parent(of: id) else { return false }
        let section: ItemContainerKind.SpaceSection
        switch parent {
        case .favorites:
            return false
        case .folder:
            section = .pinned
        case .section(_, let current):
            section = current
        }
        let wasSelected = selectedItemID == id
        let index = section == .pinned ? sectionEntries(for: .pinned, spaceID: destinationSpaceID).count : 0
        guard moveItem(id, to: .section(spaceID: destinationSpaceID, section: section), index: index) else { return false }
        if wasSelected {
            selectSpace(destinationSpaceID)
            switch entry(withID: id) {
            case .split(let split): selectSplit(split.id)
            case .easel: selectEasel(id)
            case .tab: selectTab(id)
            default: break
            }
        }
        notifyMutation()
        return true
    }

    // MARK: - Clear Today

    /// Clear Unpinned Tabs (Arc Tidy): archives every Today tab of the space
    /// except splits and easels. The selected tab goes too, as in Arc.
    /// Returns the archived ids, newest record last, for Undo.
    @discardableResult
    public func clearTodayTabs(in spaceID: Space.ID? = nil) -> [Tab.ID] {
        let id = spaceID ?? activeSpaceID
        let tabs = content(for: id).todayLeaves.compactMap { entry -> Tab.ID? in
            if case .tab(let tab) = entry { return tab.id }
            return nil
        }
        return tabs.filter { archiveTab($0, reason: .manual) != nil }
    }

    /// Undo Clear: puts archived tabs back at the top of Today in their order.
    @discardableResult
    public func restoreClearedTabs(_ ids: [Tab.ID]) -> [Tab] {
        let restored = ids.reversed().compactMap { restoreArchivedTab($0) }
        return restored.reversed()
    }
}
