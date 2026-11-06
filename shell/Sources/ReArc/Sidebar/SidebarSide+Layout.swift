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

    /// Settings › General › Sidebar position. The layout swaps once, while
    /// the sidebar and page are faded out (0.1 s out, 0.14 s in), so nothing
    /// slides across the window and Chromium resizes the page once. Under
    /// Reduce Motion it swaps at once.
    func setSidebarSide(_ side: SidebarSide) {
        side.save(to: externalLinkDefaults)
        guard side != (pendingSidebarSide ?? sidebarSide) else { return }
        isSidebarPeeking = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pendingSidebarSide = nil
            applySidebarSide(side)
            sidebarFlipOpacity = 1
            return
        }
        // A fade-out already running picks up the newer side.
        let fading = pendingSidebarSide != nil
        pendingSidebarSide = side
        guard !fading else { return }
        withAnimation(.easeIn(duration: 0.1)) {
            sidebarFlipOpacity = 0
        } completion: { [weak self] in
            guard let self, let side = self.pendingSidebarSide else { return }
            self.pendingSidebarSide = nil
            self.applySidebarSide(side)
            withAnimation(.easeOut(duration: 0.14)) { self.sidebarFlipOpacity = 1 }
        }
    }

    private func applySidebarSide(_ side: SidebarSide) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { sidebarSide = side }
    }
}
