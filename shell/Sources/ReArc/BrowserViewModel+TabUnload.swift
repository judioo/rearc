import Foundation
import SidebarModel

/// Unloading tabs that stay in the sidebar (Arc "Unload Tab", pinned-tab
/// unload on ⌘W, and the automatic unload of tabs left unseen). Chromium
/// discards the page in place (`tab_discard`, ABI 1.25): the WebContents,
/// back/forward list, boosts and lease survive, and showing the tab
/// reloads it. WebKit, and Chromium without the feature, drop the engine,
/// and the tab loads its URL when it is shown. Unloaded rows show a dimmed
/// icon until the tab is shown again.
extension BrowserViewModel {
    /// Retries for a discard the engine refused because the tab was still on
    /// screen or loading (the view detaches after the selection moves).
    static let discardRetryDelays: [TimeInterval] = [0.25, 0.75, 2]

    /// The context-menu Unload Tab and the Unload command: the tab stays where it is.
    func unloadTab(_ id: Tab.ID) {
        guard let tab = store.tab(withID: id) else { return }
        let profile = profileID(for: tab)
        guard let engine = engineHost.engine(forTabID: id, profileID: profile) else { return }
        if isTabVisible(id) {
            // Arc moves the selection away first; the page goes once it is hidden.
            if store.selectedTabID == id || store.splitContaining(tabID: id) != nil {
                selectNextTabAway(from: id)
            }
        }
        unloadEngine(engine, tabID: id, dropIfRefused: true)
    }

    /// True for a tab the shell unloaded (or whose page Chromium discarded) that has not been shown since.
    func isTabUnloaded(_ id: Tab.ID) -> Bool {
        if unloadedTabIDs.contains(id) { return true }
        guard let tab = store.tab(withID: id),
              let discarding = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? TabDiscarding else { return false }
        return discarding.isDiscarded
    }

    /// Whether Unload Tab applies: the tab has a live, not yet unloaded page.
    func canUnloadTab(_ id: Tab.ID) -> Bool {
        guard let tab = store.tab(withID: id), engineHost.engine(forTabID: id, profileID: profileID(for: tab)) != nil else { return false }
        return !isTabUnloaded(id)
    }

    /// Discards when the engine can, else drops the engine. A discard the
    /// engine keeps refusing (playing media, an unload handler) leaves the
    /// page loaded for the automatic unload; an explicit unload
    /// (`dropIfRefused`) then drops the engine instead.
    func unloadEngine(_ engine: any WebEngine, tabID: Tab.ID, attempt: Int = 0, dropIfRefused: Bool = false) {
        guard let discarding = engine as? TabDiscarding else {
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
            return
        }
        switch discarding.discard() {
        case .discarded:
            unloadedTabIDs.remove(tabID)
        case .refusedForNow where attempt < Self.discardRetryDelays.count:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.discardRetryDelays[attempt]) { [weak self, weak engine] in
                guard let self, let engine, !self.isTabVisible(tabID),
                      let tab = self.store.tab(withID: tabID),
                      self.engineHost.engine(forTabID: tabID, profileID: self.profileID(for: tab)) === engine else { return }
                self.unloadEngine(engine, tabID: tabID, attempt: attempt + 1, dropIfRefused: dropIfRefused)
            }
        case .refusedForNow:
            guard dropIfRefused, !isTabVisible(tabID) else { break }
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
        case .unsupported:
            releaseEngine(for: tabID)
            unloadedTabIDs.insert(tabID)
        }
    }

    /// Tabs a window may be showing: every space's selected item (a split's
    /// panes too), and the peeked page's tab is not one of them.
    var visibleTabIDs: Set<Tab.ID> {
        var visible: Set<Tab.ID> = []
        for space in store.spaces {
            guard let id = store.selectedItemID(inSpace: space.id) else { continue }
            if let split = store.split(withID: id) {
                split.tabs.forEach { visible.insert($0.id) }
            } else {
                visible.insert(id)
            }
        }
        return visible
    }

    func isTabVisible(_ id: Tab.ID) -> Bool {
        visibleTabIDs.contains(id)
    }

    /// The tabs on screen were just shown: they are active now, and no longer unloaded.
    func noteVisibleTabsShown(at date: Date = Date()) {
        for id in visibleTabIDs {
            tabLastShown[id] = date
            unloadedTabIDs.remove(id)
        }
    }

    /// The automatic unload (checked with auto-archive, every five minutes).
    @discardableResult
    func runAutoUnload(now: Date = Date()) -> [Tab.ID] {
        noteVisibleTabsShown(at: now)
        let visible = visibleTabIDs
        var candidates: [TabUnloadCandidate] = []
        for (id, profile, engine) in engineHost.allTabEngines() {
            guard store.tab(withID: id) != nil, profile == store.tab(withID: id).map(profileID(for:)) else { continue }
            let lastShown = tabLastShown[id] ?? now
            tabLastShown[id] = lastShown
            let media = mediaState(for: id)
            candidates.append(TabUnloadCandidate(
                tabID: id,
                lastActive: lastShown,
                isVisible: visible.contains(id),
                isAudible: media.isAudible || media.isPlaying,
                isUnloaded: isTabUnloaded(id) || engine.isLoading,
                hasPendingPrompt: engine.pagePrompts.hasPendingPrompt
            ))
        }
        let due = TabUnloadPolicy.tabsToUnload(candidates, threshold: tabUnloadThreshold, now: now)
        for id in due {
            guard let tab = store.tab(withID: id), let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) else { continue }
            unloadEngine(engine, tabID: id)
        }
        tabLastShown = tabLastShown.filter { store.tab(withID: $0.key) != nil }
        unloadedTabIDs = unloadedTabIDs.filter { store.tab(withID: $0) != nil }
        return due
    }

    private func selectNextTabAway(from id: Tab.ID) {
        let order = store.displayTabs()
        guard order.count > 1 else { return }
        if store.splitContaining(tabID: id) != nil {
            // A split pane is unloaded by leaving the split for the next item outside it.
            if let next = order.first(where: { store.splitContaining(tabID: $0.id) == nil && $0.id != id }) {
                selectTab(next.id)
            }
            return
        }
        selectNextTab()
    }
}
