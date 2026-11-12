import SidebarModel

/// Max › Tidy Tab Titles (FEATURE-SPECS/MAX.md §2), by rules on this Mac:
/// a tab the person pins or makes a favorite gets a shorter title through
/// the rename path, marked automatic. A title they typed is never replaced,
/// Reset Title brings the page's back, and it syncs as any custom title.
extension BrowserViewModel {
    /// Tidies the tab's title now, or once its page title arrives. Returns
    /// what puts the old title back, when it changed one.
    @discardableResult
    func tidyTitleIfNeeded(_ id: Tab.ID) -> (() -> Void)? {
        guard isMaxFeatureOn(.tidyTabTitles), let tab = store.tab(withID: id), TidyTabTitles.shouldTidy(tab) else { return nil }
        guard !TidyTabTitles.isPlaceholder(tab.title, url: tab.url) else {
            pendingTitleTidies.insert(id)
            return nil
        }
        pendingTitleTidies.remove(id)
        guard let tidy = TidyTabTitles.tidyTitle(tab.title, host: tab.url.host() ?? ""), tidy != tab.displayTitle else { return nil }
        let previous = (title: tab.customTitle, automatic: tab.customTitleIsAutomatic)
        store.renameTab(id, to: tidy, automatic: true)
        return { [weak self] in
            // Only while the title is still the tidy one: a rename since is the person's.
            guard let self, let now = self.store.tab(withID: id), now.customTitleIsAutomatic, now.customTitle == tidy else { return }
            self.store.renameTab(id, to: previous.title, automatic: previous.automatic)
        }
    }

    /// Pinning or favoriting several at once tidies each; one Undo puts every title back.
    @discardableResult
    func tidyTitlesIfNeeded(_ ids: [Tab.ID]) -> (() -> Void)? {
        let undos = ids.compactMap { tidyTitleIfNeeded($0) }
        guard !undos.isEmpty else { return nil }
        return { undos.forEach { $0() } }
    }

    /// A pin or favorite's toast, with Undo for the titles `undo` puts back.
    func showKeptToast(_ message: String, systemImage: String, count: Int = 1, titleUndo undo: (() -> Void)?) {
        guard let undo else { return showToast(message, systemImage: systemImage) }
        showUndoToast("\(message) · \(count == 1 ? "Title" : "Titles") tidied", systemImage: systemImage, undo: undo)
    }

    /// The page's title arrived for a tab waiting to be tidied.
    func noteTitleForTidy(_ id: Tab.ID) {
        guard pendingTitleTidies.contains(id) else { return }
        guard let tab = store.tab(withID: id), tab.kind != .today else {
            pendingTitleTidies.remove(id)
            return
        }
        tidyTitleIfNeeded(id)
    }

    /// Reset Title: the page's own title again (a typed or a tidy one goes).
    func resetTitle(_ id: Tab.ID) {
        pendingTitleTidies.remove(id)
        store.renameTab(id, to: nil)
    }
}
