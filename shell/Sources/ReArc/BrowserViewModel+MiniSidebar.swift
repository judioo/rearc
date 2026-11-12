import AppKit
import SwiftUI
import SidebarModel

/// ReArc's mini sidebar (⇧⌘S): per window, the sidebar is its full rows or
/// a column of icons (`SidebarModes`, `MiniSidebarLayout`). ⌘S still hides
/// and shows it, in either mode.
extension BrowserViewModel {

    func sidebarMode(in window: SidebarWindowID?) -> SidebarMode {
        sidebarModes.mode(in: window)
    }

    func isMiniSidebar(in window: SidebarWindowID?) -> Bool {
        sidebarModes.isMini(in: window)
    }

    /// The space list's width in `window` (the Library aside): the mini
    /// column, or the width the user dragged.
    func sidebarListWidth(in window: SidebarWindowID?) -> CGFloat {
        CGFloat(sidebarModes.width(in: window, fullWidth: Double(sidebarWidth)))
    }

    /// Where `window`'s chrome goes: the side from Settings, and the traffic
    /// lights out of a mini column.
    func sidebarPlacement(in window: SidebarWindowID?) -> SidebarPlacement {
        SidebarPlacement(side: sidebarSide, isMini: isMiniSidebar(in: window))
    }

    /// `window`'s sidebar moving between full and mini width, if it is mid-way.
    func sidebarMorph(in window: SidebarWindowID?) -> SidebarWidthMorph? {
        sidebarMorphs[window]
    }

    /// A browser window comes up: its saved mode, or the mode of the window
    /// it was opened from (the key window). Registered before its first frame.
    func openSidebarMode(for window: SidebarWindowID, restoring saved: SidebarMode? = nil) {
        sidebarModes.open(window, restoring: saved, openedFrom: store.keyWindowID == window ? nil : store.keyWindowID)
    }

    func forgetSidebarMode(for window: SidebarWindowID) {
        sidebarModes.forget(window)
        sidebarMorphs[window] = nil
    }

    /// The View menu's and command bar's title for ⇧⌘S in the key window.
    var miniSidebarMenuTitle: String {
        isMiniSidebar(in: store.keyWindowID) ? "Show Full Sidebar" : "Show Mini Sidebar"
    }

    /// ⇧⌘S: the window's sidebar between full and mini. A hidden sidebar
    /// comes back in the new mode (⌘S's slide). A shown one keeps its icons
    /// where they are and moves its edge on ⌘S's curve, with the page laid
    /// out once (`SidebarWidthMorph`); under Reduce Motion it switches at once.
    func toggleMiniSidebar(in window: SidebarWindowID? = nil) {
        guard let target = window ?? store.keyWindowID else { return }
        let before = Double(sidebarWidth(in: target))
        let current = sidebarMorphs[target]
        let result = sidebarModes.toggle(in: target, sidebarVisible: isSidebarVisible || isSidebarPeeking)
        PerfSignposts.interaction(.sidebarToggle, result.mode == .mini ? "mini" : "full")
        onSidebarModeChange?()
        if result.mode == .mini, MiniSidebarAddressBarTip.takeIfDue(in: externalLinkDefaults) {
            showToast(MiniSidebarAddressBarTip.message, systemImage: "menubar.arrow.up.rectangle",
                      action: .openSettings(.advanced), duration: ShellToast.choiceDuration / 2)
        }
        if inlineRename != nil { _ = endInlineRename(.commit) }
        if result.showsSidebar {
            sidebarMorphs[target] = nil
            toggleSidebar()
            return
        }
        let after = Double(sidebarWidth(in: target))
        guard isSidebarVisible, !isSidebarSliding, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let morph = SidebarWidthMorph(from: before, to: after, current: current) else {
            sidebarMorphs[target] = nil
            return
        }
        // The start is drawn first (the edge where it was, the new rows in
        // place), then the edge moves: one transaction would only animate
        // from what was on screen, which has no cut and no slide.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { sidebarMorphs[target] = morph }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sidebarMorphs[target] == morph else { return }
            withAnimation(Self.sidebarAnimation, completionCriteria: .logicallyComplete) {
                self.sidebarMorphs[target]?.shown = after
            } completion: { [weak self] in
                // A newer change owns it now.
                guard let self, self.sidebarMorphs[target]?.to == after, self.sidebarMorphs[target]?.from == morph.from else { return }
                self.sidebarMorphs[target] = nil
            }
        }
    }
}
