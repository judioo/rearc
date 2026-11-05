import Foundation

/// Lookups by id in O(1) and fine-grained observation (perf-1, H1/H2).
///
/// `contentBySpace` and `favoritesByProfile` are not observed as a whole.
/// Readers register on `observation` keys instead: a lookup by id on that
/// entry, `content(for:)` on its space, `outline(for:)` on the space's row
/// order, `isSelected` on one row's selection. Every write to either
/// container drops the derived caches and, while anyone is observing,
/// compares the changed space or profile with its previous summary to
/// notify only the keys that changed.
extension SidebarStore {

    // MARK: - Derived lookups

    /// The space's tree, sorted by rank at every level, without observing it.
    func sortedContent(for spaceID: Space.ID) -> SpaceContent {
        if let cached = lookup.sorted[spaceID] { return cached }
        var content = contentBySpace[spaceID] ?? SpaceContent()
        content.pinned = SidebarTree.sortedRecursively(content.pinned)
        content.today = SidebarTree.sortedRecursively(content.today)
        lookup.sorted[spaceID] = content
        return content
    }

    func sortedFavorites(in profileID: Profile.ID) -> [Tab] {
        if let cached = lookup.sortedFavorites[profileID] { return cached }
        let sorted = RankedSortable.sortedTabs(favoritesByProfile[profileID] ?? [])
        lookup.sortedFavorites[profileID] = sorted
        return sorted
    }

    /// Every entry by id: favorites first, then each space in `spaces` order
    /// (pinned, then Today, split panes with their split). The first id wins,
    /// as the linear scans this replaces did.
    func lookupIndex() -> [UUID: SidebarLookupCache.Item] {
        if let index = lookup.index { return index }
        var index: [UUID: SidebarLookupCache.Item] = [:]
        for (profileID, favorites) in favoritesByProfile {
            for tab in favorites where index[tab.id] == nil {
                index[tab.id] = .init(entry: .tab(tab), place: .favorite(profileID))
            }
        }
        func add(_ entries: [SidebarEntry], spaceID: Space.ID, section: ItemContainerKind.SpaceSection, folderID: UUID?) {
            for entry in entries {
                if index[entry.id] == nil {
                    index[entry.id] = .init(entry: entry, place: .tree(spaceID: spaceID, section: section, folderID: folderID))
                }
                switch entry {
                case .folder(let folder):
                    add(folder.children, spaceID: spaceID, section: section, folderID: folder.id)
                case .split(let split):
                    for pane in split.tabs where index[pane.id] == nil {
                        index[pane.id] = .init(entry: .tab(pane), place: .splitPane(spaceID: spaceID, section: section, splitID: split.id))
                    }
                case .tab, .easel:
                    break
                }
            }
        }
        for space in spaces {
            let content = sortedContent(for: space.id)
            add(content.pinned, spaceID: space.id, section: .pinned, folderID: nil)
            add(content.today, spaceID: space.id, section: .unpinned, folderID: nil)
        }
        lookup.index = index
        return index
    }

    /// The indexed entry, observing it (or, when absent, the set of ids).
    func indexed(_ id: UUID) -> SidebarLookupCache.Item? {
        let item = lookupIndex()[id]
        observation.access(item == nil ? .membership : .entry(id))
        return item
    }

    // MARK: - Selection per row

    /// Whether `id` is the selection shown for `spaceID` (the live selection
    /// in the active space, the remembered one elsewhere). The reader is
    /// notified only when `id` gains or loses it.
    public func isSelected(_ id: UUID, inSpace spaceID: Space.ID) -> Bool {
        observation.access(.selection(spaceID, id))
        return trackedSelection(inSpace: spaceID) == id
    }

    /// The selection shown for `spaceID` if it is one of `candidates` (a
    /// collapsed folder's or section's rows), observing those rows only.
    public func selection(among candidates: [UUID], inSpace spaceID: Space.ID) -> UUID? {
        for id in candidates { observation.access(.selection(spaceID, id)) }
        guard let selected = trackedSelection(inSpace: spaceID), candidates.contains(selected) else { return nil }
        return selected
    }

    private func trackedSelection(inSpace spaceID: Space.ID) -> UUID? {
        if let known = lookup.trackedSelection[spaceID] { return known }
        let current = selectedItemID(inSpace: spaceID)
        lookup.trackedSelection[spaceID] = .some(current)
        return current
    }

    /// Recomputes each observed space's selection and notifies the rows that gained or lost it.
    func refreshSelectionObservers() {
        lookup.selectionNeedsRefresh = false
        for (spaceID, seen) in lookup.trackedSelection {
            let current = selectedItemID(inSpace: spaceID)
            guard current != seen else { continue }
            lookup.trackedSelection[spaceID] = .some(current)
            if let seen { observation.invalidate(.selection(spaceID, seen)) }
            if let current { observation.invalidate(.selection(spaceID, current)) }
        }
    }

    /// A tree change can move a space's fallback selection; settle it at the
    /// end of the mutation (`notifyMutation`) or on the next turn.
    private func selectionMayHaveMoved() {
        guard !lookup.trackedSelection.isEmpty, !lookup.selectionNeedsRefresh else { return }
        lookup.selectionNeedsRefresh = true
        guard !lookup.selectionRefreshScheduled else { return }
        lookup.selectionRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lookup.selectionRefreshScheduled = false
            if self.lookup.selectionNeedsRefresh { self.refreshSelectionObservers() }
        }
    }

    func settlePendingSelection() {
        if lookup.selectionNeedsRefresh { refreshSelectionObservers() }
    }

    // MARK: - Invalidation

    func spacesDidChange(from old: [Space]) {
        // A space's profile decides which favorites lead its display rows.
        lookup.display.removeAll()
        let ids = spaces.map(\.id)
        if old.map(\.id) != ids {
            lookup.index = nil
            lookup.trackedSelection = lookup.trackedSelection.filter { ids.contains($0.key) }
            observation.invalidate(.membership)
        }
        selectionMayHaveMoved()
    }

    func favoritesDidChange(from old: [Profile.ID: [Tab]]) {
        lookup.index = nil
        lookup.display.removeAll()
        for profileID in Set(old.keys).union(favoritesByProfile.keys) {
            let before = old[profileID], after = favoritesByProfile[profileID]
            guard before != after else { continue }
            lookup.sortedFavorites[profileID] = nil
            guard !observation.isEmpty else {
                lookup.favoriteSummaries[profileID] = nil
                continue
            }
            observation.invalidate(.favorites(profileID))
            let previous = lookup.favoriteSummaries[profileID]
                ?? Dictionary((before ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let next = Dictionary((after ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            lookup.favoriteSummaries[profileID] = next
            invalidateChanges(from: previous, to: next)
        }
        selectionMayHaveMoved()
    }

    func contentDidChange(from old: [Space.ID: SpaceContent]) {
        lookup.index = nil
        lookup.display.removeAll()
        for spaceID in Set(old.keys).union(contentBySpace.keys) {
            let before = old[spaceID], after = contentBySpace[spaceID]
            guard before != after else { continue }
            lookup.sorted[spaceID] = nil
            lookup.outlines[spaceID] = nil
            guard !observation.isEmpty else {
                lookup.summaries[spaceID] = nil
                continue
            }
            observation.invalidate(.spaceContent(spaceID))
            let previous = lookup.summaries[spaceID] ?? SpaceSummary(spaceID: spaceID, content: before)
            let next = SpaceSummary(spaceID: spaceID, content: after)
            lookup.summaries[spaceID] = next
            if previous.signature != next.signature { observation.invalidate(.spaceOutline(spaceID)) }
            invalidateChanges(from: previous.items, to: next.items)
        }
        selectionMayHaveMoved()
    }

    private func invalidateChanges<Value: Equatable>(from previous: [UUID: Value], to next: [UUID: Value]) {
        var membershipChanged = false
        for (id, value) in next where previous[id] != value {
            observation.invalidate(.entry(id))
            if previous[id] == nil { membershipChanged = true }
        }
        for id in previous.keys where next[id] == nil {
            observation.invalidate(.entry(id))
            membershipChanged = true
        }
        if membershipChanged { observation.invalidate(.membership) }
    }
}
