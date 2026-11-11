import Foundation
import SidebarModel

/// Views show engines; only the model makes them. SwiftUI can run a view's
/// body once more for content being taken away: a split's view, evaluated
/// after its pane was closed and its engine dropped, made a blank engine for
/// the closed pane and attached it over the window, where it took the next
/// tab's place or its first click (the self-test's automatic Peek step).
extension BrowserViewModel {
    /// The engine a view shows for `tab`, looked up only (and observed, so the
    /// view updates when the model makes it).
    func shownEngine(for tab: Tab) -> (any WebEngine)? {
        engineHost.engine(forTabID: tab.id, profileID: profileID(for: tab))
    }

    /// A tab a window shows that has no engine yet (another window's space, a
    /// pane the selection did not load): make and load it, after the view
    /// update. Only a live tab that some window shows gets one.
    func loadShownTab(_ id: Tab.ID) {
        guard !startupDeferred, let tab = store.tab(withID: id), isTabVisible(id),
              shownEngine(for: tab) == nil else { return }
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        configureLinkPeek(on: engine, tab: tab)
        if engine.currentURL != tab.url {
            engine.load(tab.url)
        }
        syncBoosts(for: tab)
    }
}
