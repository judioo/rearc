import AppKit
import SidebarModel

/// Arc's tab stacking in the sidebar (ARC-RECORDING-2026-11-06 §8): drop a
/// tab on a tab or split row to stack them, name the collection, and the
/// toast for a fifth pane.
extension BrowserViewModel {

    /// Arc's toast, text only, when a split already has four panes.
    func showSplitFullToast() {
        showToast(SplitViewItem.fullMessage, systemImage: "")
    }

    /// A tab dropped on the middle of a tab or split row.
    func combineIntoSplit(_ draggedID: Tab.ID, onto targetID: UUID) {
        switch store.combineIntoSplit(draggedID, onto: targetID) {
        case .combined: loadSelectedIfNeeded()
        case .full: showSplitFullToast()
        case .refused: break
        }
    }

    /// The split menu's Add Tab to Split View: a blank pane, focused.
    func addBlankPane(to splitID: SplitViewItem.ID) {
        guard let split = store.split(withID: splitID) else { return }
        guard !split.isFull else { return showSplitFullToast() }
        store.selectSplit(splitID, focusTabID: split.focusTabID)
        addSplitView(orientation: split.orientation)
    }

    func beginSplitRename(_ splitID: SplitViewItem.ID) {
        renamingSplitID = splitID
    }

    func renameSplit(_ splitID: SplitViewItem.ID, to title: String) {
        if renamingSplitID == splitID { renamingSplitID = nil }
        store.renameSplit(splitID, to: title)
    }

    func copySplitLinks(_ splitID: SplitViewItem.ID, markdown: Bool) {
        guard let split = store.split(withID: splitID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(split.links(markdown: markdown), forType: .string)
    }
}
