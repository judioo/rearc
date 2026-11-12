import SidebarModel

/// Max › Tidy Tabs (FEATURE-SPECS/MAX.md §5), by rules on this Mac: with
/// more than six Today tabs, the broom by the Today divider (or the command,
/// or Tabs › Tidy Tabs) files them into folders by site and topic at the end
/// of Pinned. Pinned tabs and splits stay; nothing closes or is archived;
/// the toast's Undo puts every tab back where it was.
extension BrowserViewModel {
    func canTidyTabs(in spaceID: Space.ID? = nil) -> Bool {
        isMaxFeatureOn(.tidyTabs) && store.canTidyTabs(in: spaceID ?? store.activeSpaceID)
    }

    /// False when nothing grouped (no two tabs share a site or a topic).
    @discardableResult
    func tidyTabs(in spaceID: Space.ID? = nil) -> Bool {
        let spaceID = spaceID ?? store.activeSpaceID
        guard canTidyTabs(in: spaceID) else { return false }
        guard let undo = store.tidyTodayTabs(in: spaceID) else {
            showToast("Nothing to tidy: no two tabs share a site or a topic", systemImage: "folder")
            return false
        }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        let tabs = undo.moved.count, folders = undo.folderIDs.count
        showUndoToast("Tidied \(tabs) tabs into \(folders == 1 ? "1 folder" : "\(folders) folders")", systemImage: "folder") { [weak self] in
            guard let self else { return }
            self.store.undoTidyTabs(undo)
            self.reconcileEngineOwnership()
            self.loadSelectedIfNeeded()
        }
        return true
    }
}
