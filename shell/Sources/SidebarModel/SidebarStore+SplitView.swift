import Foundation

extension SidebarStore {

    @discardableResult
    public func createSplit(
        tabIDs: [Tab.ID],
        orientation: SplitLayoutOrientation,
        in spaceID: Space.ID? = nil
    ) -> SplitViewItem? {
        guard (2 ... 4).contains(tabIDs.count) else { return nil }
        guard Set(tabIDs).count == tabIDs.count else { return nil }
        let sid = spaceID ?? activeSpaceID
        var section: ItemContainerKind.SpaceSection?
        var tabs: [Tab] = []
        var placements: [Tab.ID: TabPlacement] = [:]

        for tabID in tabIDs {
            guard let location = locate(tabID),
                  tabLocationSpace(location) == sid,
                  splitContaining(tabID: tabID) == nil else { return nil }
            let resolvedSection: ItemContainerKind.SpaceSection
            switch location {
            case .pinned:
                resolvedSection = .pinned
            case .today:
                resolvedSection = .unpinned
            case .favorite, .splitPane:
                return nil
            }
            if let section, section != resolvedSection { return nil }
            section = resolvedSection
            guard let tab = tab(withID: tabID),
                  case .tab = findEntry(tabID: tabID, spaceID: sid, section: resolvedSection) else { return nil }
            if let index = sectionEntries(for: resolvedSection, spaceID: sid).firstIndex(where: { $0.id == tabID }) {
                placements[tabID] = placement(for: location, index: index)
            }
            tabs.append(tab)
        }
        guard let section, tabs.count == tabIDs.count else { return nil }

        let insertIndex = placements.values.map { index(for: $0) }.min() ?? sectionEntries(for: section, spaceID: sid).count
        for tabID in tabIDs {
            removeStandaloneTab(tabID, spaceID: sid, section: section)
        }

        let split = SplitViewItem(
            orientation: orientation,
            tabs: tabs,
            memberPlacements: placements
        )
        var entries = sectionEntries(for: section, spaceID: sid)
        entries.insert(.split(split), at: min(insertIndex, entries.count))
        setSectionEntries(entries, for: section, spaceID: sid)
        selectedItemID = split.id
        notifyMutation()
        return split
    }

    @discardableResult
    public func addTabToSplit(splitID: SplitViewItem.ID, tabID: Tab.ID) -> Bool {
        guard var split = split(withID: splitID), split.tabs.count < 4 else { return false }
        guard let location = locateSplit(splitID),
              let tabLocation = locate(tabID),
              tabLocationSpace(tabLocation) == location.spaceID,
              splitContaining(tabID: tabID) == nil,
              case .tab(let tab) = findEntry(tabID: tabID, spaceID: location.spaceID, section: location.section)
        else { return false }

        if let index = sectionEntries(for: location.section, spaceID: location.spaceID).firstIndex(where: { $0.id == tabID }) {
            split.memberPlacements[tabID] = placement(for: tabLocation, index: index)
        }
        removeStandaloneTab(tabID, spaceID: location.spaceID, section: location.section)
        split.tabs.append(tab)
        split.widthFactors = SplitViewItem.normalizedFactors(split.widthFactors, tabIDs: split.tabs.map(\.id))
        replaceSplit(split)
        notifyMutation()
        return true
    }

    @discardableResult
    public func removeTabFromSplit(splitID: SplitViewItem.ID, tabID: Tab.ID) -> Bool {
        guard var split = split(withID: splitID),
              split.tabs.contains(where: { $0.id == tabID }),
              let location = locateSplit(splitID) else { return false }

        if split.tabs.count <= 2 {
            return unsplit(splitID)
        }

        guard let tabIndex = split.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let tab = split.tabs.remove(at: tabIndex)
        split.widthFactors.removeValue(forKey: tabID)
        let placement = split.memberPlacements.removeValue(forKey: tabID)
        if split.focusTabID == tabID {
            split.focusTabID = split.tabs[min(tabIndex, split.tabs.count - 1)].id
        }
        split.widthFactors = SplitViewItem.normalizedFactors(split.widthFactors, tabIDs: split.tabs.map(\.id))
        replaceSplit(split)
        restoreTabToSection(tab, placement: placement, spaceID: location.spaceID, section: location.section)
        notifyMutation()
        return true
    }

    public func setSplitFocus(splitID: SplitViewItem.ID, tabID: Tab.ID) {
        guard var split = split(withID: splitID),
              split.tabs.contains(where: { $0.id == tabID }) else { return }
        split.focusTabID = tabID
        replaceSplit(split)
        if selectedItemID == splitID {
            setUnread(false, for: tabID)
        }
        notifyMutation()
    }

    public func resizeSplitPanes(splitID: SplitViewItem.ID, widthFactors: [Tab.ID: Double]) {
        guard var split = split(withID: splitID) else { return }
        split.widthFactors = SplitViewItem.normalizedFactors(widthFactors, tabIDs: split.tabs.map(\.id))
        replaceSplit(split)
        notifyMutation()
    }

    public func changeSplitOrientation(splitID: SplitViewItem.ID, orientation: SplitLayoutOrientation) {
        guard var split = split(withID: splitID) else { return }
        split.orientation = orientation
        replaceSplit(split)
        notifyMutation()
    }

    @discardableResult
    public func unsplit(_ splitID: SplitViewItem.ID) -> Bool {
        guard let split = split(withID: splitID),
              let location = locateSplit(splitID) else { return false }
        var entries = sectionEntries(for: location.section, spaceID: location.spaceID)
        guard let splitIndex = entries.firstIndex(where: { $0.id == splitID }) else { return false }
        entries.remove(at: splitIndex)

        let sortedTabs = split.tabs.sorted { lhs, rhs in
            let li = split.memberPlacements[lhs.id].map { index(for: $0) } ?? splitIndex
            let ri = split.memberPlacements[rhs.id].map { index(for: $0) } ?? splitIndex
            return li < ri
        }
        for (offset, tab) in sortedTabs.enumerated() {
            let target = split.memberPlacements[tab.id].map { index(for: $0) } ?? (splitIndex + offset)
            entries.insert(.tab(tab), at: min(target, entries.count))
        }
        setSectionEntries(entries, for: location.section, spaceID: location.spaceID)
        if selectedItemID == splitID {
            selectedItemID = sortedTabs.first?.id
        }
        notifyMutation()
        return true
    }

    // MARK: - Private split helpers

    private func tabLocationSpace(_ location: TabLocation) -> Space.ID? {
        switch location {
        case .pinned(let id), .today(let id): return id
        default: return nil
        }
    }

    private func findEntry(tabID: Tab.ID, spaceID: Space.ID, section: ItemContainerKind.SpaceSection) -> SidebarEntry? {
        sectionEntries(for: section, spaceID: spaceID).first { $0.id == tabID }
    }

    private func removeStandaloneTab(_ tabID: Tab.ID, spaceID: Space.ID, section: ItemContainerKind.SpaceSection) {
        var entries = sectionEntries(for: section, spaceID: spaceID)
        entries.removeAll { $0.id == tabID }
        setSectionEntries(entries, for: section, spaceID: spaceID)
    }

    private func placement(for location: TabLocation, index: Int) -> TabPlacement {
        switch location {
        case .favorite: return .favorite(index: index)
        case .pinned(let spaceID): return .pinned(spaceID: spaceID, index: index)
        case .today(let spaceID): return .today(spaceID: spaceID, index: index)
        case .splitPane: return .today(spaceID: activeSpaceID, index: index)
        }
    }

    private func restoreTabToSection(
        _ tab: Tab,
        placement: TabPlacement?,
        spaceID: Space.ID,
        section: ItemContainerKind.SpaceSection
    ) {
        var entries = sectionEntries(for: section, spaceID: spaceID)
        let target = placement.map { index(for: $0) } ?? entries.count
        entries.insert(.tab(tab), at: min(target, entries.count))
        setSectionEntries(entries, for: section, spaceID: spaceID)
    }
}

extension SidebarStore {
    /// Split with a chosen tab (Arc "Split with…"): `tabID` joins `anchorID`.
    /// It joins the anchor's split when there is room (up to 4 panes), else a
    /// new two-pane split takes the anchor's place. A tab from the other
    /// section of the space moves next to the anchor first. Favorites and
    /// tabs of other spaces are refused.
    @discardableResult
    public func splitTab(_ tabID: Tab.ID, with anchorID: Tab.ID, orientation: SplitLayoutOrientation = .horizontal) -> SplitViewItem? {
        guard tabID != anchorID, splitContaining(tabID: tabID) == nil,
              case .tab = entry(withID: tabID),
              let tabSpace = spaceContaining(tabID: tabID),
              let anchorSpace = spaceContaining(tabID: anchorID), tabSpace == anchorSpace else { return nil }
        if let existing = splitContaining(tabID: anchorID)?.split {
            guard existing.tabs.count < 4, let location = locateSplit(existing.id) else { return nil }
            if parent(of: tabID) != .section(spaceID: anchorSpace, section: location.section) {
                guard moveItem(tabID, relativeTo: existing.id, after: true) else { return nil }
            }
            guard addTabToSplit(splitID: existing.id, tabID: tabID) else { return nil }
            selectSplit(existing.id, focusTabID: tabID)
            return split(withID: existing.id)
        }
        guard case .section = parent(of: anchorID) else { return nil }
        if parent(of: tabID) != parent(of: anchorID) {
            guard moveItem(tabID, relativeTo: anchorID, after: true) else { return nil }
        }
        return createSplit(tabIDs: [anchorID, tabID], orientation: orientation, in: anchorSpace)
    }
}
