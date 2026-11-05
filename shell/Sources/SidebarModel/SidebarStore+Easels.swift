import Foundation

extension SidebarStore {

    public func easelRef(withSidebarID id: UUID) -> SidebarEaselRef? {
        guard let item = indexed(id), case .easel(let ref) = item.entry, case .tree(_, _, nil) = item.place else { return nil }
        return ref
    }

    public func easelRef(forDocumentID documentID: UUID) -> SidebarEaselRef? {
        for space in spaces {
            for entry in content(for: space.id).pinned + content(for: space.id).today {
                if case .easel(let ref) = entry, ref.easelDocumentID == documentID { return ref }
            }
        }
        return nil
    }

    public var selectedEaselRef: SidebarEaselRef? {
        guard let selectedItemID else { return nil }
        return easelRef(withSidebarID: selectedItemID)
    }

    public func allEaselRefs() -> [SidebarEaselRef] {
        var refs: [SidebarEaselRef] = []
        for space in spaces {
            for entry in content(for: space.id).pinned + content(for: space.id).today {
                if case .easel(let ref) = entry { refs.append(ref) }
            }
        }
        return refs
    }

    /// Inserts a sidebar easel row in the active space's today section.
    @discardableResult
    public func addEaselSidebarItem(
        documentID: UUID,
        section: ItemContainerKind.SpaceSection = .unpinned,
        spaceID: Space.ID? = nil
    ) -> SidebarEaselRef {
        let ref = SidebarEaselRef(easelDocumentID: documentID)
        let space = spaceID ?? activeSpaceID
        var entries = sectionEntries(for: section, spaceID: space)
        let entry = SidebarEntry.easel(ref)
        switch section {
        case .pinned:
            entries.append(entry)
        case .unpinned:
            entries.insert(entry, at: 0)
        }
        setSectionEntries(entries, for: section, spaceID: space)
        notifyMutation()
        return ref
    }

    public func selectEasel(_ sidebarItemID: UUID) {
        guard easelRef(withSidebarID: sidebarItemID) != nil else { return }
        selectedItemID = sidebarItemID
        notifyMutation()
    }

    public func removeEaselSidebarItem(_ sidebarItemID: UUID) {
        guard let location = locateEasel(sidebarItemID) else { return }
        var entries = sectionEntries(for: location.section, spaceID: location.spaceID)
        let priorIndex = entries.firstIndex(where: { $0.id == sidebarItemID })
        entries.removeAll { $0.id == sidebarItemID }
        setSectionEntries(entries, for: location.section, spaceID: location.spaceID)
        if selectedItemID == sidebarItemID {
            reconcileSelectionAfterRemoval(removedID: sidebarItemID, priorIndex: priorIndex)
        }
        notifyMutation()
    }

    /// Deletes the document reference from the sidebar everywhere and drops cached title.
    public func purgeSidebarReferences(toDocument documentID: UUID) {
        for space in spaces {
            for section in ItemContainerKind.SpaceSection.allCases {
                var entries = sectionEntries(for: section, spaceID: space.id)
                let removedIDs = entries.filter {
                    if case .easel(let ref) = $0, ref.easelDocumentID == documentID { return true }
                    return false
                }.map(\.id)
                guard !removedIDs.isEmpty else { continue }
                entries.removeAll { entry in
                    if case .easel(let ref) = entry, ref.easelDocumentID == documentID { return true }
                    return false
                }
                setSectionEntries(entries, for: section, spaceID: space.id)
                if let selected = selectedItemID, removedIDs.contains(selected) {
                    reconcileSelectionAfterRemoval(removedID: selected, priorIndex: nil)
                }
            }
        }
        notifyMutation()
    }

    public func locateEasel(_ sidebarItemID: UUID) -> (spaceID: Space.ID, section: ItemContainerKind.SpaceSection)? {
        guard let item = indexed(sidebarItemID), case .tree(let spaceID, let section, nil) = item.place else { return nil }
        return (spaceID, section)
    }

    // MARK: - Captures (indexed in sidebar snapshot)

    public var captures: [CaptureRecord] {
        capturesByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func capture(withID id: UUID) -> CaptureRecord? {
        capturesByID[id]
    }

    @discardableResult
    public func addCapture(_ record: CaptureRecord) -> CaptureRecord {
        capturesByID[record.id] = record
        notifyMutation()
        return record
    }

    @discardableResult
    public func removeCapture(id: UUID) -> CaptureRecord? {
        guard let removed = capturesByID.removeValue(forKey: id) else { return nil }
        notifyMutation()
        return removed
    }
}
