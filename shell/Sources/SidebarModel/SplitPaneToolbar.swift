import Foundation

/// Arc's split view toolbars (SPLIT-VIEW §3.1): with "URL in toolbar" on,
/// every pane is its own card with its own row (back, forward, its address,
/// a close ✕). Only the focused pane's row adds reload, the site controls,
/// the extensions and the split view menu; focusing another pane moves them.
public struct SplitPaneToolbarLayout: Equatable {
    /// One pane's row.
    public struct Row: Equatable {
        public var tabID: Tab.ID
        /// The focused pane: reload, site controls, extensions, split menu.
        public var isActive: Bool
        /// The row starts at the card's top-left corner (the traffic lights
        /// with the sidebar on the right; the sidebar toggle on the left).
        public var isAtLeadingCorner: Bool
        /// The row ends at the card's top-right corner (the sidebar toggle
        /// with the sidebar on the right).
        public var isAtTrailingCorner: Bool
    }

    public private(set) var rows: [Row]

    /// The panes on screen in order (all of them, or the expanded one).
    public init(visiblePanes: [Tab.ID], focus: Tab.ID, orientation: SplitLayoutOrientation) {
        let active = visiblePanes.contains(focus) ? focus : visiblePanes.first
        let last = visiblePanes.count - 1
        rows = visiblePanes.enumerated().map { index, id in
            let topRow = orientation == .vertical ? index == 0 : true
            return Row(
                tabID: id,
                isActive: id == active,
                isAtLeadingCorner: topRow && (orientation == .vertical || index == 0),
                isAtTrailingCorner: topRow && (orientation == .vertical ? index == 0 : index == last)
            )
        }
    }

    public init(split: SplitViewItem, visiblePanes: [Tab]) {
        self.init(visiblePanes: visiblePanes.map(\.id), focus: split.focusTabID, orientation: split.orientation)
    }

    /// The pane whose row carries the site controls, extensions and split menu.
    public var controlsPane: Tab.ID? { rows.first(where: \.isActive)?.tabID }

    public func row(for tabID: Tab.ID) -> Row? { rows.first { $0.tabID == tabID } }

    /// Rows show with "URL in toolbar" on, as the single strip does; HTML
    /// fullscreen shows only the page. With the toolbar off (Arc: the URL in
    /// the sidebar) the panes have no rows and the sidebar's address follows
    /// the focused pane.
    public static func showsRows(urlInToolbar: Bool, pageFullscreen: Bool) -> Bool {
        urlInToolbar && !pageFullscreen
    }

    /// A click in a pane focuses it; nil when it already has focus or is not
    /// in the split (nothing to change, so nothing re-renders).
    public static func focusChange(clicked tabID: Tab.ID, in split: SplitViewItem) -> Tab.ID? {
        guard tabID != split.focusTabID, split.tabs.contains(where: { $0.id == tabID }) else { return nil }
        return tabID
    }

    /// A pane row's address: the host without `www.` (Arc draws it darker)
    /// and the rest of the URL without its scheme. Nil for a blank page.
    public static func addressParts(_ url: URL?) -> (host: String, rest: String)? {
        guard let url, url.absoluteString != "about:blank" else { return nil }
        guard let host = url.host(), !host.isEmpty else { return (url.absoluteString, "") }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = url.path(percentEncoded: false)
        if rest == "/" { rest = "" }
        if let query = url.query(percentEncoded: false), !query.isEmpty { rest += "?" + query }
        return (bareHost, rest)
    }
}
