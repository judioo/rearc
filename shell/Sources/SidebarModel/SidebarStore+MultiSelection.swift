import Foundation

/// Each window's ⇧/⌘-click selection of sidebar rows (`SidebarMultiSelection`)
/// and what the commands on it do to the tree. Rows read `isMultiSelected`,
/// which notifies only the rows that join or leave.
extension SidebarStore {

    // MARK: - Reading

    /// Whether `id` is in the window's selection (the active row included).
    public func isMultiSelected(_ id: UUID, in window: SidebarWindowID?) -> Bool {
        observation.access(.multiSelection(window, id))
        return multiSelectionByWindow[window]?.contains(id) ?? false
    }

    /// The window's selection, observing only whether there is one.
    public func multiSelection(in window: SidebarWindowID?) -> SidebarMultiSelection? {
        observation.access(.multiSelectionPresence(window))
        return multiSelectionByWindow[window]
    }

    /// The selected rows in outline order, or nil without a selection.
    public func multiSelectedIDs(in window: SidebarWindowID?) -> [UUID]? {
        guard let selection = multiSelectionByWindow[window], !selection.isEmpty else { return nil }
        return selection.ordered(in: outlineOrder(in: selection.spaceID)).filter { spaceContaining(entryID: $0) == selection.spaceID }
    }

    /// What a row's context menu acts on (`SidebarMultiSelection.menuTargets`).
    public func menuTargets(for id: UUID, in window: SidebarWindowID?) -> [UUID] {
        guard let ids = multiSelectedIDs(in: window), ids.contains(id) else { return [id] }
        return ids
    }

    /// Every row id of a space, folders and their contents included, in the
    /// order the sidebar shows them with every folder open.
    public func outlineOrder(in spaceID: Space.ID) -> [UUID] {
        func walk(_ nodes: [SidebarOutlineNode]) -> [UUID] {
            nodes.flatMap { [$0.id] + ($0.kind == .folder ? walk($0.children) : []) }
        }
        let outline = outline(for: spaceID)
        return walk(outline.pinned) + walk(outline.today)
    }

    // MARK: - Clicks

    /// ⇧-click on `id` in a window showing `spaceID`; `visibleOrder` is the
    /// rows on screen, top to bottom.
    public func extendMultiSelection(to id: UUID, inSpace spaceID: Space.ID, visibleOrder: [UUID], in window: SidebarWindowID?) {
        var selection = currentOrNewSelection(inSpace: spaceID, in: window)
        selection.extend(to: id, visibleOrder: visibleOrder)
        setMultiSelection(selection, in: window)
    }

    /// ⌘-click on `id`: adds or removes that row without showing it.
    public func toggleMultiSelection(_ id: UUID, inSpace spaceID: Space.ID, in window: SidebarWindowID?) {
        var selection = currentOrNewSelection(inSpace: spaceID, in: window)
        selection.toggle(id)
        setMultiSelection(selection, in: window)
    }

    /// A plain click, Esc, or the selection's command done.
    public func clearMultiSelection(in window: SidebarWindowID?) {
        guard multiSelectionByWindow[window] != nil else { return }
        setMultiSelection(nil, in: window)
    }

    private func currentOrNewSelection(inSpace spaceID: Space.ID, in window: SidebarWindowID?) -> SidebarMultiSelection {
        let active = selectedItemID(inSpace: spaceID)
        if let current = multiSelectionByWindow[window], current.spaceID == spaceID, current.activeID == active {
            return current
        }
        return SidebarMultiSelection(spaceID: spaceID, activeID: active)
    }

    private func setMultiSelection(_ selection: SidebarMultiSelection?, in window: SidebarWindowID?) {
        let next = selection.flatMap { $0.isEmpty ? nil : $0 }
        let previous = multiSelectionByWindow[window]
        guard next != previous else { return }
        multiSelectionByWindow[window] = next
        let before = previous?.members ?? [], after = next?.members ?? []
        for id in before.symmetricDifference(after) { observation.invalidate(.multiSelection(window, id)) }
        if (previous == nil) != (next == nil) { observation.invalidate(.multiSelectionPresence(window)) }
    }

    /// After a mutation or a selection change: a window whose space or
    /// active item changed loses its selection; rows that were closed,
    /// archived or moved to another space leave it.
    func validateMultiSelections() {
        guard !multiSelectionByWindow.isEmpty else { return }
        for (window, selection) in multiSelectionByWindow {
            guard focusedSpaceID(in: window) == selection.spaceID,
                  selectedItemID(inSpace: selection.spaceID) == selection.activeID else {
                setMultiSelection(nil, in: window)
                continue
            }
            var pruned = selection
            pruned.prune { spaceContaining(entryID: $0) == selection.spaceID }
            setMultiSelection(pruned, in: window)
        }
    }

    // MARK: - Commands on a selection

    /// The ids without those inside a selected folder: moving the folder
    /// moves them.
    public func topmostEntries(_ ids: [UUID]) -> [UUID] {
        let set = Set(ids)
        return ids.filter { id in
            var folder = parentFolderID(of: id)
            while let current = folder {
                if set.contains(current) { return false }
                folder = parentFolderID(of: current)
            }
            return true
        }
    }

    /// The tabs whose links a copy of `ids` writes, in order: a tab, a
    /// split's panes, a folder's tabs; each once.
    public func linkTabIDs(for ids: [UUID]) -> [Tab.ID] {
        var seen = Set<Tab.ID>()
        return ids.flatMap { id -> [Tab.ID] in
            switch entry(withID: id) {
            case .tab(let tab): return [tab.id]
            case .split(let split): return split.tabs.map(\.id)
            case .folder(let folder): return SidebarTree.tabs(folder.children).map(\.id)
            case .easel, nil: return []
            }
        }
        .filter { seen.insert($0).inserted }
    }

    /// Plain tabs among `ids` (not folders, splits or easels).
    public func plainTabIDs(_ ids: [UUID]) -> [Tab.ID] {
        ids.filter { if case .tab = entry(withID: $0) { true } else { false } }
    }

    /// Runs `body`, recording every tab it closes as one ⇧⌘T batch.
    public func closingAsOneBatch(_ body: () -> Void) {
        guard closedTabBatchID == nil else { return body() }
        closedTabBatchID = UUID()
        defer { closedTabBatchID = nil }
        body()
    }

    /// ⇧⌘T: the newest closed tab, or every tab of the batch it was closed
    /// with, back where each was. Returns them, last reopened first.
    @discardableResult
    public func reopenMostRecentClosedBatch() -> [Tab] {
        guard let batch = closedTabStack.records.last?.batchID else {
            return reopenMostRecentClosedTab().map { [$0] } ?? []
        }
        var reopened: [Tab] = []
        while closedTabStack.records.last?.batchID == batch, let tab = reopenMostRecentClosedTab() {
            reopened.append(tab)
        }
        return reopened
    }

    /// Pin Tabs: the Today tabs among `ids` go to the end of Pinned in order.
    /// Returns the ids pinned.
    @discardableResult
    public func pinTabs(_ ids: [UUID]) -> [Tab.ID] {
        plainTabIDs(ids).filter { kind(of: $0) == .today && pinTab($0) }
    }

    /// Unpin Tabs: the pinned tabs among `ids` go to the top of Today,
    /// keeping their order.
    @discardableResult
    public func unpinTabs(_ ids: [UUID]) -> [Tab.ID] {
        let pinned = plainTabIDs(ids).filter { kind(of: $0) == .pinned && splitContaining(tabID: $0) == nil }
        return pinned.reversed().filter { unpinTab($0) }.reversed()
    }

    /// Add to Favorites for each tab, in order, at the end of the strip.
    @discardableResult
    public func addTabsToFavorites(_ ids: [UUID]) -> [Tab.ID] {
        plainTabIDs(ids).filter { kind(of: $0) != .favorite && splitContaining(tabID: $0) == nil && addToFavorites($0) }
    }

    /// Duplicate for each tab: each copy right below its tab.
    @discardableResult
    public func duplicateTabs(_ ids: [UUID]) -> [Tab] {
        plainTabIDs(ids).compactMap { duplicateTab($0) }
    }

    /// Move to Space for each row (folders carry their contents): rows keep
    /// their section and order, at the end of Pinned or the top of Today.
    @discardableResult
    public func moveEntries(_ ids: [UUID], toSpace spaceID: Space.ID) -> [UUID] {
        let entries = topmostEntries(ids)
        let today = entries.filter { parent(of: $0).map { if case .section(_, .unpinned) = $0 { true } else { false } } ?? false }
        let pinned = entries.filter { !today.contains($0) }
        // Today rows land at the top one by one: the last goes first.
        return pinned.filter { moveEntry($0, toSpace: spaceID) } + today.reversed().filter { moveEntry($0, toSpace: spaceID) }.reversed()
    }

    /// Move to Folder for each row not already there, appended in order.
    @discardableResult
    public func moveEntries(_ ids: [UUID], intoFolder folderID: UUID) -> [UUID] {
        topmostEntries(ids).filter { id in
            guard id != folderID, parent(of: id) != .folder(folderID), !isAncestor(id, of: folderID) else { return false }
            return moveItem(id, to: .folder(folderID), index: entries(in: .folder(folderID)).count)
        }
    }

    /// New Folder with Selection: a folder at the end of Pinned holding the rows in order.
    @discardableResult
    public func createFolder(withSelection ids: [UUID], in spaceID: Space.ID) -> SidebarFolder? {
        let entries = topmostEntries(ids).filter { spaceContaining(entryID: $0) == spaceID }
        guard !entries.isEmpty else { return nil }
        return createFolder(in: spaceID, containing: entries)
    }

    /// Whether `split` can take `ids` as its panes: two to four plain tabs of
    /// one space, none in a split or the strip.
    public func canSplit(selection ids: [UUID]) -> Bool {
        let tabs = plainTabIDs(ids)
        guard tabs.count == ids.count, (2 ... 4).contains(tabs.count), let first = tabs.first,
              let space = spaceContaining(tabID: first) else { return false }
        return tabs.allSatisfy { splitContaining(tabID: $0) == nil && kind(of: $0) != .favorite && spaceContaining(tabID: $0) == space }
    }

    /// Open in Split View: the first tab's place becomes a split of all of
    /// them, in order (a tab from the other section joins it there).
    @discardableResult
    public func split(selection ids: [UUID], orientation: SplitLayoutOrientation = .horizontal) -> SplitViewItem? {
        guard canSplit(selection: ids) else { return nil }
        let tabs = plainTabIDs(ids)
        var anchor = tabs[0]
        // A tab inside a folder cannot anchor a split: the first tab at the
        // top of a section does.
        if case .folder = parent(of: anchor) {
            guard let top = tabs.first(where: { if case .section = parent(of: $0) { true } else { false } }) else { return nil }
            anchor = top
        }
        for tab in tabs where tab != anchor {
            guard splitTab(tab, with: anchor, orientation: orientation) != nil else { break }
        }
        return splitContaining(tabID: anchor)?.split
    }

    private func isAncestor(_ id: UUID, of folderID: UUID) -> Bool {
        var current = parentFolderID(of: folderID)
        while let folder = current {
            if folder == id { return true }
            current = parentFolderID(of: folder)
        }
        return false
    }
}
