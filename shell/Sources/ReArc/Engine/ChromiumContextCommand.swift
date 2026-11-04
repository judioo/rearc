import SidebarModel

/// `ReArcContextMenuCommand` actions.
enum ChromiumContextCommand: UInt32 {
    case openLinkHere = 0, copyLink, copy, paste, cut, selectAll, saveImage, copyImage, inspect, back, forward, reload, dismiss

    /// The engine command for a menu item; nil for the shell's own items.
    init?(_ item: PageContextMenuItem) {
        switch item {
        case .copyLink: self = .copyLink
        case .copy: self = .copy
        case .paste: self = .paste
        case .cut: self = .cut
        case .selectAll: self = .selectAll
        case .saveImage: self = .saveImage
        case .copyImage: self = .copyImage
        case .inspect: self = .inspect
        case .back: self = .back
        case .forward: self = .forward
        case .reload: self = .reload
        case .openLinkInNewTab, .openLinkInLittleArc, .openLinkInNewSplit, .openImageInNewTab,
             .copyImageAddress, .searchFor, .viewSource:
            return nil
        }
    }
}
