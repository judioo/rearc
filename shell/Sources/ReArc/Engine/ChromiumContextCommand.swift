import SidebarModel

/// `ReArcContextMenuCommand` actions.
enum ChromiumContextCommand: UInt32 {
    case openLinkHere = 0, copyLink, copy, paste, cut, selectAll, saveImage, copyImage, inspect, back, forward, reload, dismiss
    /// Engine ABI 1.58 (`context_menu_link_open`): the link or image opens
    /// with the frame as initiator, through the link-open requests (1.39).
    case openLinkInBackgroundTab = 13, openLinkInForegroundTab = 14, openLinkInWindow = 15, openLinkInSplit = 16
    case openImageInBackgroundTab = 17
    /// Engine ABI 1.64 (`context_menu_save_link`): a prompted download of the link.
    case saveLink = 21

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
        // The tab opens in front; the shell then shows it in a new browser window.
        case .openLinkInNewWindow: self = .openLinkInForegroundTab
        case .openLinkInLittleArc: self = .openLinkInWindow
        case .openLinkInNewSplit: self = .openLinkInSplit
        case .openImageInNewTab: self = .openImageInBackgroundTab
        case .saveLinkAs: self = .saveLink
        // A private window is another profile: Chrome opens its links without the page as initiator too.
        case .openLinkInPrivateWindow, .copyImageAddress, .searchImage, .searchFor, .viewSource:
            return nil
        }
    }
}
