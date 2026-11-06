import AppKit
import SidebarModel

/// Engines that can give the page keyboard focus back (after the command bar).
protocol PageFocusing: AnyObject {
    @discardableResult
    func focusPage() -> Bool
}

/// Wave 30: Arc shortcuts that had no ReArc action (docs/SHORTCUTS.md).
extension BrowserViewModel {
    /// ⌃⌘← / ⌃⌘→: back and forth through the tabs visited, in the order they
    /// were visited when the cycle began.
    func cycleTabHistory(forward: Bool) {
        guard let selected = store.selectedTabID else { return }
        if tabVisitCycle?.current != selected {
            tabVisitCycle = TabVisitCycle(order: store.recentTabSwitcherItems(limit: 50).map(\.id))
        }
        guard let next = tabVisitCycle?.step(forward: forward) else { return }
        if store.focusTab(next) { loadSelectedIfNeeded() }
    }

    /// ⌃⇧-: Arc's Close this Split Pane closes the focused page of a split.
    func closeFocusedSplitPane() {
        guard let id = store.selectedTabID, store.splitContaining(tabID: id) != nil else { return }
        closeSelectedTab()
    }

    /// ⌥⌘C / ⌥⌘J: the selected tab's DevTools, opened or shown (never closed).
    func showDevTools() {
        guard let id = store.selectedTabID else { return }
        _ = openDevTools(for: id)
    }

    /// ⌘J: scrolls the page's selection into view.
    func jumpToSelection() {
        guard let id = store.selectedTabID, let tab = store.tab(withID: id),
              let reader = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? PageSelectionReading else { return }
        Task { _ = await reader.scrollSelectionIntoView() }
    }

    /// Keyboard focus back on the selected page (Arc: after the command bar
    /// closes, the page has focus again). Deferred until the bar's field has
    /// left; a tab the bar's ⌘T replaced re-attaches first, so it retries briefly.
    func restorePageFocus(attempts: Int = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 10 ? 0 : 0.1)) { [weak self] in
            // A rename the command bar started keeps its row's field focused.
            guard let self, !self.isCommandBarPresented, self.inlineRename == nil else { return }
            if self.focusShownPage() || attempts <= 1 { return }
            self.restorePageFocus(attempts: attempts - 1)
        }
    }

    private func focusShownPage() -> Bool {
        if let id = keyLittleArcID, store.littleArcWindow(withID: id) != nil {
            return (littleArcEngine(for: id) as? PageFocusing)?.focusPage() ?? false
        }
        guard let id = store.selectedTabID, let tab = store.tab(withID: id),
              let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? PageFocusing else { return false }
        return engine.focusPage()
    }
}

/// The DOM selection's script, shared by both engines.
enum PageSelectionScripts {
    static let scrollIntoView = """
    (() => { const s = window.getSelection(); if (!s || s.rangeCount === 0) return false;
      const n = s.getRangeAt(0).startContainer; const e = n.nodeType === 1 ? n : n.parentElement;
      if (!e) return false; e.scrollIntoView({block: 'center'}); return true; })()
    """
}
