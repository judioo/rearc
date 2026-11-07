import Foundation

extension SidebarStore {
    public func canSplitLittleArcToCurrentTab(id: LittleArcWindow.ID) -> Bool {
        guard littleArcWindow(withID: id) != nil, let anchor = selectedTab else { return false }
        return splitContaining(tabID: anchor.id)?.split.isFull != true
    }

    /// Little Arc's split button targets the last browser window's current
    /// tab, regardless of the Little Arc's profile. Favorites and tabs in
    /// folders get a Today copy so their saved place stays intact.
    @discardableResult
    public func splitLittleArcToCurrentTab(id: LittleArcWindow.ID) -> SplitViewItem? {
        guard canSplitLittleArcToCurrentTab(id: id), let window = littleArcWindow(withID: id),
              var anchor = selectedTab else { return nil }
        if kind(of: anchor.id) == .favorite || parentFolderID(of: anchor.id) != nil {
            anchor = addTab(kind: .today, title: anchor.displayTitle, url: anchor.url)
        }
        let pane = addTab(kind: .today, title: window.title, url: window.url)
        // Both tabs are now top-level entries of this space and the anchor
        // has room. splitTab moves the new pane into a pinned anchor's section.
        guard let split = splitTab(pane.id, with: anchor.id) else { return nil }
        selectSplit(split.id, focusTabID: pane.id)
        littleArcWindows.removeAll { $0.id == id }
        notifyMutation()
        return self.split(withID: split.id)
    }
}
