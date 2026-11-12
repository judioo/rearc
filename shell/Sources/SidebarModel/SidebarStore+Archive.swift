import Foundation

/// Archive store and Today-tab auto-archive (SIDEBAR-SPEC §2.9, §4.1 Clean
/// Tabs; DATA-SCHEMA §3). Records are local; they are not journaled for sync.
extension SidebarStore {

    /// A container follows its parent's setting.
    public func autoArchiveThreshold(for profileID: Profile.ID? = nil) -> AutoArchiveThreshold {
        autoArchiveThresholdByProfile[owningProfileID(of: profileID ?? activeProfileID)] ?? .default
    }

    public func setAutoArchiveThreshold(_ threshold: AutoArchiveThreshold, for profileID: Profile.ID? = nil) {
        let id = owningProfileID(of: profileID ?? activeProfileID)
        guard profiles.contains(where: { $0.id == id }), autoArchiveThreshold(for: id) != threshold else { return }
        autoArchiveThresholdByProfile[id] = threshold
        notifyMutation()
    }

    /// Archive Tab: removes a pinned or Today tab (folders included) and keeps
    /// it in the archive. Favorites and split panes are not archived.
    @discardableResult
    public func archiveTab(_ id: Tab.ID, reason: TabArchiveReason = .manual) -> ArchivedTabRecord? {
        guard case .tab(let tab) = entry(withID: id), let spaceID = spaceContaining(tabID: id) else { return nil }
        switch locate(id) {
        case .pinned, .today: break
        default: return nil
        }
        let priorIndex = displayEntries().firstIndex(where: { $0.id == id })
        removeFromContainer(id)
        appendArchiveRecord(tab, spaceID: spaceID, reason: reason)
        reconcileSelectionAfterRemoval(removedID: id, priorIndex: priorIndex)
        notifyMutation(.deleteItem(id: id))
        // Blank tabs leave the sidebar without an archive entry.
        return archivedTabs.last(where: { $0.id == id })
            ?? ArchivedTabRecord(tab: tab, spaceID: spaceID, archivedAt: now(), reason: reason)
    }

    /// Archives Today tabs (not splits or easels) not selected within their
    /// profile's threshold. The selected tab is never archived, nor a `spared`
    /// one (playing media or a call: archiving would stop it). Returns the ids.
    @discardableResult
    public func autoArchiveIdleTodayTabs(sparing spared: Set<Tab.ID> = []) -> [Tab.ID] {
        let reference = now()
        let selected = selectedTabID
        var archived: [Tab.ID] = []
        for space in spaces {
            let threshold = autoArchiveThreshold(for: space.profileID)
            for entry in content(for: space.id).todayLeaves {
                guard case .tab(let tab) = entry, tab.id != selected, !spared.contains(tab.id) else { continue }
                let lastActive = tab.lastActiveAt ?? reference
                guard reference.timeIntervalSince(lastActive) >= threshold.interval else { continue }
                if archiveTab(tab.id, reason: .auto) != nil {
                    archived.append(tab.id)
                }
            }
        }
        return archived
    }

    /// Restores an archived tab to the top of Today in its original space
    /// (or the active space if that is gone) and selects it.
    @discardableResult
    public func restoreArchivedTab(_ id: Tab.ID) -> Tab? {
        guard let index = archivedTabs.firstIndex(where: { $0.id == id }) else { return nil }
        let record = archivedTabs.remove(at: index)
        let spaceID = record.spaceID.flatMap { space(withID: $0)?.id } ?? activeSpaceID
        var tab = record.tab
        tab.setKind(.today)
        tab.lastActiveAt = now()
        if self.tab(withID: tab.id) != nil {
            // Already back in the sidebar (reopened): keep one copy.
            focusTab(tab.id)
            return self.tab(withID: tab.id)
        }
        var today = sectionEntries(for: .unpinned, spaceID: spaceID)
        tab.sortRank = rankForNewItem(in: today, atIndex: 0)
        today.insert(.tab(tab), at: 0)
        setSectionEntries(today, for: .unpinned, spaceID: spaceID)
        notifyMutation(.insertItem(id: tab.id, spaceID: spaceID, container: .unpinned, sortRank: tab.sortRank))
        if activeSpaceID != spaceID { selectSpace(spaceID) }
        selectTab(tab.id)
        return self.tab(withID: tab.id)
    }

    public func removeArchivedTab(_ id: Tab.ID) {
        guard archivedTabs.contains(where: { $0.id == id }) else { return }
        archivedTabs.removeAll { $0.id == id }
        notifyMutation()
    }

    /// Clear Archive.
    public func clearArchive() {
        guard !archivedTabs.isEmpty else { return }
        archivedTabs.removeAll()
        notifyMutation()
    }
}
