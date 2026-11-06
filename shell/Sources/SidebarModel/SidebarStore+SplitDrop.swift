import Foundation

/// The content edge a sidebar tab is dropped on to make a split (Arc
/// `SplitTabTarget`, `icon-split-add-top/right/bottom/left`, SPLIT-VIEW §2.3).
public enum SplitDropEdge: String, CaseIterable, Sendable {
    case leading, trailing, top, bottom

    /// Left and right drops lay panes side by side; top and bottom stack them.
    public var orientation: SplitLayoutOrientation {
        switch self {
        case .leading, .trailing: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// The dropped tab becomes the first pane (left or top).
    public var placesFirst: Bool { self == .leading || self == .top }

    public var title: String {
        switch self {
        case .leading: return "Split Left"
        case .trailing: return "Split Right"
        case .top: return "Split Top"
        case .bottom: return "Split Bottom"
        }
    }

    /// The edge nearest a point of a `width` × `height` area (y grows down),
    /// measured as a fraction of each side so tall and wide pages behave the
    /// same. Every point has one: the preview shows where the pane lands.
    public static func nearest(x: Double, y: Double, width: Double, height: Double) -> SplitDropEdge? {
        guard width > 0, height > 0 else { return nil }
        let fx = min(max(x / width, 0), 1)
        let fy = min(max(y / height, 0), 1)
        let distances: [(SplitDropEdge, Double)] = [
            (.leading, fx), (.trailing, 1 - fx), (.top, fy), (.bottom, 1 - fy),
        ]
        return distances.min { $0.1 < $1.1 }?.0
    }
}

extension SidebarStore {

    /// Whether dropping sidebar tab `tabID` on the content showing `anchorID`
    /// can make (or grow) a split: plain tabs of the anchor's space only, no
    /// favorites, not already in a split, and room for a fifth pane is refused.
    public func canSplit(_ tabID: Tab.ID, onto anchorID: Tab.ID) -> Bool {
        guard isSplitCandidate(tabID, joining: anchorID) else { return false }
        if let existing = splitContaining(tabID: anchorID)?.split {
            return !existing.isFull
        }
        return kind(of: anchorID) == .pinned || kind(of: anchorID) == .today
    }

    /// A plain tab of the anchor's space, not a favorite or another split's pane.
    func isSplitCandidate(_ tabID: Tab.ID, joining anchorID: Tab.ID) -> Bool {
        tabID != anchorID
            && entry(withID: tabID).map { if case .tab = $0 { true } else { false } } == true
            && kind(of: tabID) != .favorite && kind(of: tabID) != nil
            && splitContaining(tabID: tabID) == nil
            && spaceContaining(tabID: tabID).map { $0 == spaceContaining(tabID: anchorID) } == true
    }

    /// Drag-to-split: `tabID` becomes a pane on `edge` of what the anchor
    /// shows. A single tab becomes a two-pane split; an existing split takes
    /// the pane at its start or end and turns to the edge's axis. The dropped
    /// pane gets focus.
    @discardableResult
    public func splitTab(_ tabID: Tab.ID, onto anchorID: Tab.ID, edge: SplitDropEdge) -> SplitViewItem? {
        guard canSplit(tabID, onto: anchorID),
              let made = splitTab(tabID, with: anchorID, orientation: edge.orientation),
              var split = split(withID: made.id),
              let index = split.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let pane = split.tabs.remove(at: index)
        split.tabs.insert(pane, at: edge.placesFirst ? 0 : split.tabs.count)
        split.orientation = edge.orientation
        split.focusTabID = tabID
        replaceSplit(split)
        selectSplit(split.id, focusTabID: tabID)
        notifyMutation(.upsertItem(id: split.id))
        return split
    }
}
