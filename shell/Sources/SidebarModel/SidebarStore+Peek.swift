import Foundation

extension SidebarStore {
    /// The tab a Peek's Open in Split View joins: the tab the Peek was opened
    /// from, when `splitTab(_:with:)` can take it as the anchor. Favorites
    /// never split, a folder's tab cannot anchor a new split, and a split
    /// holds four panes at most.
    public func peekSplitAnchor(sourceTabID: Tab.ID?) -> Tab.ID? {
        guard let id = sourceTabID, kind(of: id) != .favorite, spaceContaining(tabID: id) != nil else { return nil }
        if let split = splitContaining(tabID: id)?.split {
            return split.isFull ? nil : id
        }
        guard case .section = parent(of: id) else { return nil }
        return id
    }
}
