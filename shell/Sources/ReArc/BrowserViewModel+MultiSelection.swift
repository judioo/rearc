import AppKit
import SidebarModel

/// ⇧/⌘-click selection of sidebar rows (Arc, 2026-11-11 recording) and the
/// commands that act on it: the row menu, ⌘W, ⇧⌘C, ⌘D and the Tabs menu.
/// The selection itself lives in the store, per window (`SidebarMultiSelection`).
extension BrowserViewModel {

    // MARK: - Clicks

    /// A click on a sidebar row: ⇧ extends the window's selection to it, ⌘
    /// toggles it, and neither shows the row's page. Returns false for a
    /// plain click, which drops the selection and does what it always did.
    func handleSelectionClick(on id: UUID, in window: SidebarWindowID?,
                              modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        let keys = modifiers.intersection([.shift, .command, .option, .control])
        let spaceID = store.focusedSpaceID(in: window)
        guard keys == .shift || keys == .command, Self.isSelectableRow(store.entry(withID: id)),
              store.spaceContaining(entryID: id) == spaceID else {
            store.clearMultiSelection(in: window)
            return false
        }
        if keys == .shift {
            store.extendMultiSelection(to: id, inSpace: spaceID, visibleOrder: visibleRowIDs(spaceID: spaceID, in: window), in: window)
        } else {
            store.toggleMultiSelection(id, inSpace: spaceID, in: window)
        }
        return true
    }

    /// Tabs, splits and folders take part; easels open as before.
    static func isSelectableRow(_ entry: SidebarEntry?) -> Bool {
        switch entry {
        case .tab, .split, .folder: true
        case .easel, nil: false
        }
    }

    /// The selectable rows on screen in a window, top to bottom (open
    /// folders' contents, a collapsed folder's or Pinned's shown selection).
    func visibleRowIDs(spaceID: Space.ID, in window: SidebarWindowID?) -> [UUID] {
        SidebarListRow.rows(
            outline: store.outline(for: spaceID),
            expanded: store.expandedFolderIDs,
            pinnedCollapsed: isPinnedSectionCollapsed(spaceID: spaceID, in: window),
            isDragging: false,
            selection: { store.selection(among: $0, inSpace: spaceID) }
        ).compactMap { row in
            guard case .item(let item, _) = row, item.node.kind != .easel else { return nil }
            return item.id
        }
    }

    /// The key window's selected rows, in sidebar order, while there are several.
    var keySelectionIDs: [UUID]? {
        guard keyPrivateWindow == nil, keyLittleArcEngine == nil else { return nil }
        return store.multiSelectedIDs(in: store.keyWindowID)
    }

    func clearSelection(in window: SidebarWindowID?) {
        store.clearMultiSelection(in: window)
    }

    // MARK: - Copy Links

    /// Copy Links (⇧⌘C and ⌘C on a selection): each tab's link on its own
    /// line, cleaned of trackers, as a single tab's copy does.
    func copyLinks(of ids: [UUID], format: PageLinkCopyFormat = .plain) {
        var anyCleaned = false
        let links = store.linkTabIDs(for: ids).compactMap { id -> (url: URL, title: String)? in
            guard let tab = store.tab(withID: id) else { return nil }
            let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab))
            let (url, cleaned) = LinkCleaner.clean(engine?.currentURL ?? tab.url)
            anyCleaned = anyCleaned || cleaned
            return (url, tab.customTitle ?? engine?.pageTitle ?? tab.title)
        }
        guard !links.isEmpty else { return }
        let text = (format == .markdown ? PageLinkCopyFormat.markdown : .plain).text(links: links)
        linkPasteboard.clearContents()
        linkPasteboard.setString(text, forType: .string)
        lastCopiedLinkText = text
        showToast(PageLinkCopyFormat.multipleConfirmation(cleaned: anyCleaned),
                  systemImage: anyCleaned ? "checkmark.shield.fill" : "link")
    }

    // MARK: - Close and archive

    /// ⌘W on a selection: each tab as its own ✕ would (a Today tab to the
    /// archive, a pinned one back to its saved URL, unloaded), splits closed.
    /// ⇧⌘T brings back everything this closed at once.
    func closeItems(_ ids: [UUID]) {
        store.clearMultiSelection(in: store.keyWindowID)
        store.closingAsOneBatch {
            for id in ids {
                switch store.entry(withID: id) {
                case .tab: closeTab(id)
                case .split(let split): closeSplit(split.id)
                default: break
                }
            }
        }
        loadSelectedIfNeeded()
    }

    /// Archive Tabs (row menu): the pinned and Today tabs, as Archive Tab does to one.
    func archiveTabs(_ ids: [UUID]) {
        for id in store.plainTabIDs(ids) where store.splitContaining(tabID: id) == nil {
            if store.archiveTab(id) != nil { releaseEngine(for: id) }
        }
        loadSelectedIfNeeded()
    }

    /// The ⌘W item's title on a selection.
    func closeMenuTitle(for ids: [UUID]) -> String {
        let kinds = Set(store.plainTabIDs(ids).map(closeKind(of:)))
        return kinds == [.archive] ? "Archive Tabs" : "Close Tabs"
    }

    // MARK: - Pin, favorites, duplicate

    /// ⌘D on a selection: pins the Today tabs; when all are pinned, unpins them.
    func togglePinned(_ ids: [UUID]) {
        let tabs = store.plainTabIDs(ids)
        if tabs.contains(where: { store.kind(of: $0) == .today }) {
            pinTabs(tabs)
        } else {
            unpinTabs(tabs)
        }
    }

    func pinTabs(_ ids: [UUID]) {
        let pinned = store.pinTabs(ids)
        guard !pinned.isEmpty else { return }
        let space = store.spaceContaining(tabID: pinned[0]).flatMap { store.space(withID: $0) }?.name ?? ""
        showToast(pinned.count == 1 ? "Pinned Tab to “\(space)”" : "Pinned \(pinned.count) Tabs to “\(space)”", systemImage: "pin.fill")
        loadSelectedIfNeeded()
    }

    func unpinTabs(_ ids: [UUID]) {
        let unpinned = store.unpinTabs(ids)
        guard !unpinned.isEmpty else { return }
        let space = store.spaceContaining(tabID: unpinned[0]).flatMap { store.space(withID: $0) }?.name ?? ""
        showToast(unpinned.count == 1 ? "Un-Pinned Tab from “\(space)”" : "Un-Pinned \(unpinned.count) Tabs from “\(space)”",
                  systemImage: "pin.slash")
        loadSelectedIfNeeded()
    }

    func addTabsToFavorites(_ ids: [UUID]) {
        guard !store.addTabsToFavorites(ids).isEmpty else { return }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    func duplicateTabs(_ ids: [UUID]) {
        guard !store.duplicateTabs(ids).isEmpty else { return }
        loadSelectedIfNeeded()
    }

    // MARK: - Move

    /// Move to Space: each row keeps its section and its page, as one row's move does.
    func moveItems(_ ids: [UUID], toSpace spaceID: Space.ID) {
        guard !store.moveEntries(ids, toSpace: spaceID).isEmpty else { return }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    func moveItems(_ ids: [UUID], intoFolder folderID: UUID) {
        guard !store.moveEntries(ids, intoFolder: folderID).isEmpty else { return }
        store.setFolderExpanded(folderID, true)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// New Folder with Selection: the rows go into a new folder, named in place.
    func newFolder(withSelection ids: [UUID]) {
        guard let first = ids.first, let spaceID = store.spaceContaining(entryID: first),
              let folder = store.createFolder(withSelection: ids, in: spaceID) else { return }
        store.clearMultiSelection(in: store.keyWindowID)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        beginRename(.folder(folder.id))
    }

    // MARK: - Drag

    /// The rows a drag of `id` in the key window carries: the whole
    /// selection when `id` is in it, else nil (the row alone, as before).
    /// Drops on another window, the page edge or a row's middle (stacking)
    /// still take the dragged row alone.
    func draggedSelection(_ id: UUID) -> [UUID]? {
        guard let ids = keySelectionIDs, ids.contains(id) else { return nil }
        return ids
    }

    /// Reorder: the dragged selection lands before or after `targetID`.
    @discardableResult
    func moveDraggedSelection(_ ids: [UUID], relativeTo targetID: UUID, after: Bool) -> Bool {
        guard let moved = store.moveEntries(ids, relativeTo: targetID, after: after), !moved.isEmpty else { return false }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        return true
    }

    /// After a section's last row (pins into Pinned, unpins into Today).
    func moveDraggedSelection(_ ids: [UUID], appendingTo destination: SidebarStore.ItemDestination) {
        guard !store.moveEntries(ids, appendingTo: destination).isEmpty else { return }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    // MARK: - Split View

    func canOpenInSplitView(_ ids: [UUID]) -> Bool { store.canSplit(selection: ids) }

    /// Open in Split View: two to four selected tabs become one split.
    func openInSplitView(_ ids: [UUID]) {
        guard let split = store.split(selection: ids) else { return }
        store.selectSplit(split.id)
        loadSelectedIfNeeded()
    }
}
