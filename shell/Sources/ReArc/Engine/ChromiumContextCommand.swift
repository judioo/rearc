import SidebarModel

/// `ReArcContextMenuCommand` actions.
enum ChromiumContextCommand: UInt32 {
    case openLinkHere = 0, copyLink, copy, paste, cut, selectAll, saveImage, copyImage, inspect, back, forward, reload, dismiss
    /// Engine ABI 1.58 (`context_menu_link_open`): the link or image opens
    /// with the frame as initiator, through the link-open requests (1.39).
    case openLinkInBackgroundTab = 13, openLinkInWindow = 15, openLinkInSplit = 16, openImageInBackgroundTab = 17

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
        case .openLinkInNewTab: self = .openLinkInBackgroundTab
        case .openLinkInLittleArc: self = .openLinkInWindow
        case .openLinkInNewSplit: self = .openLinkInSplit
        case .openImageInNewTab: self = .openImageInBackgroundTab
        case .copyImageAddress, .searchFor, .viewSource:
            return nil
        }
    }
}
