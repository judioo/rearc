import Foundation
import SidebarModel

/// Split view's per-pane toolbar rows (SPLIT-VIEW §3.1): which pane shows
/// the controls, focusing a pane by clicking it, and ⌘L aimed at a pane.
extension BrowserViewModel {
    /// The command bar is the address editor. Target it by pane and window,
    /// rather than by the split's active row, so unrelated bars stay hidden.
    func addressBarHasKeyboardFocus(for tabID: Tab.ID?, in window: SidebarWindowID?) -> Bool {
        isCommandBarPresented && isKeyBrowserWindow(window) && commandBarTargetID == tabID
    }

    /// The rows a window's split shows, in pane order.
    func splitPaneToolbarLayout(_ split: SplitViewItem, in window: SidebarWindowID?) -> SplitPaneToolbarLayout {
        SplitPaneToolbarLayout(split: split, visiblePanes: visibleSplitPanes(split, in: window))
    }

    /// Expand Current Split is on for this split in this window.
    func isSplitExpanded(_ splitID: SplitViewItem.ID, in window: SidebarWindowID?) -> Bool {
        store.split(withID: splitID).flatMap { expandedSplitPane($0, in: window) } != nil
    }

    /// A click anywhere in a pane (its row or its page) focuses it, so the
    /// controls and ⌘L move there. A click in the focused pane changes nothing.
    func focusSplitPane(_ tabID: Tab.ID, in splitID: SplitViewItem.ID) {
        guard let split = store.split(withID: splitID),
              let pane = SplitPaneToolbarLayout.focusChange(clicked: tabID, in: split) else { return }
        selectSplit(splitID, focusTabID: pane)
    }

    /// A pane's address clicked: ⌘L aimed at that pane. It takes focus first;
    /// an open command bar for another pane is retargeted, not closed.
    func editAddress(ofPane tabID: Tab.ID, in splitID: SplitViewItem.ID) {
        if isCommandBarPresented, commandBarTargetID == tabID {
            dismissCommandBar()
            return
        }
        if isCommandBarPresented { dismissCommandBar() }
        if store.split(withID: splitID)?.focusTabID != tabID || store.selectedItemID != splitID {
            selectSplit(splitID, focusTabID: tabID)
        }
        focusLocation()
    }

    /// The pane row's ✕: Close Pane; ⌥ separates the pane from the split instead.
    func closeSplitPaneFromToolbar(_ tabID: Tab.ID, separating: Bool) {
        if separating {
            unsplitTabIfInSplit(tabID)
        } else {
            closeTab(tabID)
        }
    }
}
