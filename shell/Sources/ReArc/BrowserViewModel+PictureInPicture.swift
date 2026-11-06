import AppKit
import SidebarModel

/// Picture in Picture, printing and PDF export commands, and Arc's automatic
/// PiP when you switch away from a tab whose video plays.
extension BrowserViewModel {
    static let automaticPictureInPictureKey = "ReArcAutomaticPictureInPicture"

    // MARK: - Picture in Picture

    func isPictureInPicture(_ tabID: Tab.ID) -> Bool {
        mediaState(for: tabID).isPictureInPicture
    }

    /// The page the PiP, print and export commands act on (key private window, else the focused tab).
    var pageCommandEngine: (any WebEngine)? {
        keyPrivateWindow?.engine ?? focusedEngine
    }

    /// The command and menu item: the selected tab's video in or out of PiP.
    func togglePictureInPicture() {
        if let id = store.selectedTabID, keyPrivateWindow == nil {
            setPictureInPicture(!isPictureInPicture(id), tabID: id)
        } else if let engine = pageCommandEngine {
            engine.setPictureInPicture(!engine.mediaState.isPictureInPicture)
        }
    }

    func setPictureInPicture(_ active: Bool, tabID: Tab.ID) {
        guard let pid = store.tab(withID: tabID).map(profileID(for:)),
              let engine = engineHost.engine(forTabID: tabID, profileID: pid) else { return }
        // A manual choice: switching back no longer ends this PiP.
        autoPiPEnteredTabIDs.remove(tabID)
        engine.setPictureInPicture(active)
    }

    /// Arc's automatic PiP on a tab switch (`AutoPiPPolicy.tabSwitchPlan`):
    /// the tab you left with a playing video, or in a call, goes into PiP,
    /// and a tab put there this way comes back when you show it again.
    func applyAutoPiPOnTabSwitch(now: Date = Date()) {
        let visible = visibleTabIDs
        let previous = pipVisibleTabIDs
        pipVisibleTabIDs = visible
        guard visible != previous else { return }
        var hosts: [Tab.ID: String] = [:]
        for id in previous.union(visible) {
            guard let tab = store.tab(withID: id) else { continue }
            let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab))
            hosts[id] = (engine?.currentURL ?? tab.url).host()
        }
        let plan = AutoPiPPolicy.tabSwitchPlan(
            previouslyVisible: previous,
            nowVisible: visible,
            media: mediaStateByTab,
            hosts: hosts,
            autoEntered: autoPiPEnteredTabIDs,
            inCall: Set(captureStateByTab.filter(\.value.isCapturingCallMedia).keys),
            // Video in Sidebar implies entering on a switch away: that is how the video gets there.
            isEnabled: automaticPictureInPicture || (embedsVideoInSidebar && engineHost.supportsLiveVideo),
            settings: store.autoPiPPolicy,
            now: now
        )
        for id in plan.exit {
            autoPiPEnteredTabIDs.remove(id)
            engine(forTabID: id)?.setPictureInPicture(false)
        }
        if let id = plan.enter, let engine = engine(forTabID: id) {
            autoPiPEnteredTabIDs.insert(id)
            engine.setPictureInPicture(true)
        }
    }

    private func engine(forTabID id: Tab.ID) -> (any WebEngine)? {
        guard let tab = store.tab(withID: id) else { return nil }
        return engineHost.engine(forTabID: id, profileID: profileID(for: tab))
    }

    /// PiP's back-to-tab button (Chromium phase 2): show that tab in its space.
    func revealTab(showing engine: AnyObject) {
        guard let id = engineHost.allTabEngines().first(where: { ($0.2 as AnyObject) === engine })?.0 else { return }
        if let spaceID = store.spaceContaining(tabID: id), spaceID != store.activeSpaceID {
            store.selectSpace(spaceID)
        }
        if let location = store.splitContaining(tabID: id) {
            store.selectSplit(location.split.id, focusTabID: id)
        } else {
            store.selectTab(id)
        }
        // Coming back by hand is not a switch away: no automatic PiP for the tab left now.
        autoPiPEnteredTabIDs.remove(id)
        loadSelectedIfNeeded()
    }

    // MARK: - Printing (Chromium ABI 1.28, WebKit printOperation)

    func printPage() {
        guard let page = pageCommandEngine as? PagePrinting else { return }
        PagePrinter.shared.print(page)
    }

    func exportPageAsPDF() {
        guard let page = pageCommandEngine as? PagePrinting else { return }
        PagePrinter.shared.exportPDF(page)
    }
}
