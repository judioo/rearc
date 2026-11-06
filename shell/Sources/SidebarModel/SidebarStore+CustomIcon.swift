import Foundation

extension SidebarStore {
    public func customIcon(for id: UUID) -> SidebarItemIcon? {
        tab(withID: id)?.customIcon ?? entry(withID: id)?.customIcon
    }

    /// Nil restores the site's favicon or the item's built-in glyph.
    @discardableResult
    public func setCustomIcon(_ icon: SidebarItemIcon?, for id: UUID) -> Bool {
        if tab(withID: id) != nil {
            let recordID = splitContaining(tabID: id)?.split.id ?? id
            guard updateTabInStore(id, { $0.customIcon = icon }) else { return false }
            notifyMutation(.upsertItem(id: recordID))
            return true
        }
        guard let spaceID = spaceContaining(entryID: id) else { return false }
        for section: ItemContainerKind.SpaceSection in [.pinned, .unpinned] {
            var entries = sectionEntries(for: section, spaceID: spaceID)
            if SidebarTree.update(id, in: &entries, { $0.customIcon = icon }) {
                setSectionEntries(entries, for: section, spaceID: spaceID)
                notifyMutation(.upsertItem(id: id))
                return true
            }
        }
        return false
    }
}
