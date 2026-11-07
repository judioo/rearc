import AppKit
import SwiftUI
import SidebarModel

/// `SidebarSide` in SwiftUI and AppKit terms. The shell is laid out left
/// to right, so left is leading.
extension SidebarSide {
    var edge: Edge { self == .left ? .leading : .trailing }
    var edgeSet: Edge.Set { self == .left ? .leading : .trailing }
    var horizontalAlignment: HorizontalAlignment { self == .left ? .leading : .trailing }
    var rectEdge: NSRectEdge { self == .left ? .minX : .maxX }
    /// The toggle's glyph: the sidebar drawn on its side.
    var toggleSymbol: String { self == .left ? "sidebar.left" : "sidebar.right" }
}

extension BrowserViewModel {
    var sidebarPlacement: SidebarPlacement { SidebarPlacement(side: sidebarSide) }

    /// Where this window's extension side panel goes against the sidebar and card.
    var sidePanelLayout: SidePanelLayout { SidePanelLayout(sidebarSide: sidebarSide, position: sidePanelPosition) }

    /// Settings › General › Sidebar position. The layout swaps once, while
    /// the sidebar and page are faded out (0.1 s out, 0.14 s in), so nothing
    /// slides across the window and Chromium resizes the page once. Under
    /// Reduce Motion it swaps at once.
    func setSidebarSide(_ side: SidebarSide) {
        side.save(to: externalLinkDefaults)
        guard side != (pendingSidebarSide ?? sidebarSide) else { return }
        isSidebarPeeking = false
        flipLayout { $0.pendingSidebarSide = side }
    }

    /// Settings › General › Side panel position: an open panel moves behind
    /// the sidebar flip's fade (instantly under Reduce Motion).
    func setSidePanelPosition(_ position: SidePanelPosition) {
        position.save(to: externalLinkDefaults)
        guard position != (pendingSidePanelPosition ?? sidePanelPosition) else { return }
        flipLayout { $0.pendingSidePanelPosition = position }
    }

    /// Records a pending change and swaps the layout behind the fade. A
    /// fade-out already running picks up the newer choice, and both settings
    /// share one fade.
    private func flipLayout(_ record: (BrowserViewModel) -> Void) {
        let fading = pendingSidebarSide != nil || pendingSidePanelPosition != nil
        record(self)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyPendingLayout()
            sidebarFlipOpacity = 1
            return
        }
        guard !fading else { return }
        withAnimation(.easeIn(duration: 0.1)) {
            sidebarFlipOpacity = 0
        } completion: { [weak self] in
            guard let self, self.pendingSidebarSide != nil || self.pendingSidePanelPosition != nil else { return }
            self.applyPendingLayout()
            withAnimation(.easeOut(duration: 0.14)) { self.sidebarFlipOpacity = 1 }
        }
    }

    private func applyPendingLayout() {
        let side = pendingSidebarSide, position = pendingSidePanelPosition
        pendingSidebarSide = nil
        pendingSidePanelPosition = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let side { sidebarSide = side }
            if let position { sidePanelPosition = position }
        }
    }
}
