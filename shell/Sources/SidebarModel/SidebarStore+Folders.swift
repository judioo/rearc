import Foundation

/// Folders (Arc item type `list`, SIDEBAR-SPEC §2.4): titled containers in a
/// space's pinned section that nest to any depth. Tabs moved into a folder
/// become pinned. Expansion is UI state: persisted, not journaled.
extension SidebarStore {

    public func folder(withID id: UUID) -> SidebarFolder? {
        guard let item = indexed(id), case .folder(let folder) = item.entry,
              case .tree(let spaceID, .pinned, _) = item.place else { return nil }
        observation.access(.spaceContent(spaceID))
        return folder
    }

    /// Folders of a space in sidebar order with their nesting depth (0 = section level).
    public func folderOutline(in spaceID: Space.ID? = nil) -> [(folder: SidebarFolder, depth: Int)] {
        func walk(_ entries: [SidebarEntry], depth: Int) -> [(folder: SidebarFolder, depth: Int)] {
            entries.flatMap { entry -> [(folder: SidebarFolder, depth: Int)] in
                guard case .folder(let folder) = entry else { return [] }
                return [(folder, depth)] + walk(folder.children, depth: depth + 1)
            }
        }
        return walk(content(for: spaceID ?? activeSpaceID).pinned, depth: 0)
    }

    /// The folder directly holding `id`, if any.
    public func parentFolderID(of id: UUID) -> UUID? {
        if case .folder(let folderID) = parent(of: id) { return folderID }
        return nil
    }

    /// Creates an expanded folder at the end of a space's pinned section, or
    /// inside `parentFolderID`, then moves `itemIDs` into it in order.
    @discardableResult
    public func createFolder(
        title: String = "New Folder",
        in spaceID: Space.ID? = nil,
        parentFolderID: UUID? = nil,
        containing itemIDs: [UUID] = []
    ) -> SidebarFolder? {
        let spaceID = parentFolderID.flatMap { spaceContaining(entryID: $0) } ?? spaceID ?? activeSpaceID
        guard space(withID: spaceID) != nil else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = SidebarFolder(title: name.isEmpty ? "New Folder" : name)
        if let parentFolderID {
            guard var siblings = SidebarTree.children(of: parentFolderID, in: sectionEntries(for: .pinned, spaceID: spaceID)) else {
                return nil
            }
            folder.sortRank = rankForNewItem(in: siblings, atIndex: siblings.count)
            siblings.append(.folder(folder))
            var pinned = sectionEntries(for: .pinned, spaceID: spaceID)
            SidebarTree.setChildren(siblings, of: parentFolderID, in: &pinned)
            setSectionEntries(pinned, for: .pinned, spaceID: spaceID)
            notifyMutation(.placeItemInFolder(id: folder.id, folderID: parentFolderID, sortRank: folder.sortRank))
        } else {
            var pinned = sectionEntries(for: .pinned, spaceID: spaceID)
            folder.sortRank = rankForNewItem(in: pinned, atIndex: pinned.count)
            pinned.append(.folder(folder))
            setSectionEntries(pinned, for: .pinned, spaceID: spaceID)
            notifyMutation(.insertItem(id: folder.id, spaceID: spaceID, container: .pinned, sortRank: folder.sortRank))
        }
        expandedFolderIDs.insert(folder.id)
        for (offset, id) in itemIDs.enumerated() {
            moveItem(id, to: .folder(folder.id), index: offset)
        }
        return self.folder(withID: folder.id)
    }

    /// Drop a tab on a tab: both go into a new folder where the target was
    /// (Arc `SidebarNewFolderOperation`). A Today target puts the folder at the
    /// end of Pinned, since Today holds no folders.
    @discardableResult
    public func createFolder(grouping targetID: UUID, with draggedID: UUID, title: String = "New Folder") -> SidebarFolder? {
        guard targetID != draggedID,
              case .tab = entry(withID: targetID),
              case .tab = entry(withID: draggedID),
              let targetParent = parent(of: targetID) else { return nil }
        let spaceID: Space.ID
        var parentFolder: UUID?
        var insertIndex: Int?
        switch targetParent {
        case .favorites:
            return nil
        case .section(let sid, let section):
            spaceID = sid
            if section == .pinned {
                insertIndex = entries(in: targetParent).firstIndex(where: { $0.id == targetID })
            }
        case .folder(let folderID):
            guard let sid = spaceContaining(entryID: folderID) else { return nil }
            spaceID = sid
            parentFolder = folderID
            insertIndex = entries(in: targetParent).firstIndex(where: { $0.id == targetID })
        }
        guard let folder = createFolder(title: title, in: spaceID, parentFolderID: parentFolder, containing: [targetID, draggedID]) else {
            return nil
        }
        if let insertIndex, let folderParent = parent(of: folder.id) {
            moveItem(folder.id, to: destination(for: folderParent), index: insertIndex)
        }
        return self.folder(withID: folder.id)
    }

    @discardableResult
    public func renameFolder(_ id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let spaceID = spaceContaining(entryID: id) else { return false }
        var pinned = sectionEntries(for: .pinned, spaceID: spaceID)
        let found = SidebarTree.update(id, in: &pinned) { entry in
            guard case .folder(var folder) = entry else { return }
            folder.title = trimmed
            entry = .folder(folder)
        }
        guard found else { return false }
        setSectionEntries(pinned, for: .pinned, spaceID: spaceID)
        notifyMutation(.upsertItem(id: id))
        return true
    }

    /// Removes a folder. `keepingChildren` moves its contents up to where the
    /// folder was; otherwise its tabs are archived (restorable) and nested
    /// folders go with it. Returns the ids of tabs that left the sidebar.
    @discardableResult
    public func deleteFolder(_ id: UUID, keepingChildren: Bool) -> [Tab.ID] {
        guard let folder = folder(withID: id), let folderParent = parent(of: id),
              let spaceID = spaceContaining(entryID: id) else { return [] }
        if keepingChildren {
            let siblings = entries(in: folderParent)
            var index = siblings.firstIndex(where: { $0.id == id }) ?? siblings.count
            for child in folder.children {
                // The folder still occupies its slot, so children land just before it.
                moveItem(child.id, to: destination(for: folderParent), index: index)
                index += 1
            }
            removeFromContainer(id)
            expandedFolderIDs.remove(id)
            notifyMutation(.deleteItem(id: id))
            return []
        }
        let removedTabs = SidebarTree.tabs(folder.children)
        for tab in removedTabs {
            appendArchiveRecord(tab, spaceID: spaceID, reason: .manual)
        }
        let selectionWasInside = selectedItemID.map { SidebarTree.contains($0, in: folder.children) } ?? false
        let priorIndex = selectedItemID.flatMap { selected in displayEntries().firstIndex(where: { $0.id == selected }) }
        removeFromContainer(id)
        for nested in SidebarTree.folders(folder.children) { expandedFolderIDs.remove(nested.id) }
        expandedFolderIDs.remove(id)
        if selectionWasInside, let selected = selectedItemID {
            reconcileSelectionAfterRemoval(removedID: selected, priorIndex: priorIndex)
        }
        notifyMutation(.deleteItem(id: id))
        return removedTabs.map(\.id)
    }

    public func isFolderExpanded(_ id: UUID) -> Bool {
        expandedFolderIDs.contains(id)
    }

    public func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        guard folder(withID: id) != nil, expandedFolderIDs.contains(id) != expanded else { return }
        if expanded {
            expandedFolderIDs.insert(id)
        } else {
            expandedFolderIDs.remove(id)
        }
        notifyMutation()
    }

    public func toggleFolderExpanded(_ id: UUID) {
        setFolderExpanded(id, !isFolderExpanded(id))
    }

    /// Menu Expand All Folders / Collapse All Folders (active space).
    public func setAllFoldersExpanded(_ expanded: Bool, in spaceID: Space.ID? = nil) {
        let ids = folderOutline(in: spaceID).map(\.folder.id)
        guard !ids.isEmpty else { return }
        if expanded {
            expandedFolderIDs.formUnion(ids)
        } else {
            expandedFolderIDs.subtract(ids)
        }
        notifyMutation()
    }
}
