import Foundation

extension SplitLayoutOrientation {
    /// Arc `convertToHorizontalSplitView` / `convertToVerticalSplitView` (SPLIT-VIEW §3).
    public var flipped: SplitLayoutOrientation { self == .horizontal ? .vertical : .horizontal }
}

extension SidebarStore {
    /// Flips a split between side by side and stacked, keeping pane sizes.
    @discardableResult
    public func flipSplitOrientation(splitID: SplitViewItem.ID) -> SplitLayoutOrientation? {
        guard let split = split(withID: splitID) else { return nil }
        changeSplitOrientation(splitID: splitID, orientation: split.orientation.flipped)
        return split.orientation.flipped
    }
}

/// Expand Current Split (Arc `expandSplitViewPane` / `maximizeCurrentSplitViewPane`,
/// SPLIT-VIEW §3): one pane takes the whole content area and its siblings
/// stay open behind it. Window state, not saved. Focusing another pane, or
/// the pane leaving the split, restores the split.
public struct SplitPaneMaximizeState: Equatable {
    public struct Key: Hashable {
        public var window: SidebarWindowID?
        public var splitID: SplitViewItem.ID
    }

    public private(set) var maximized: [Key: Tab.ID] = [:]

    public init() {}

    /// The pane shown alone in this window, if any.
    public func maximizedTab(in split: SplitViewItem, window: SidebarWindowID?) -> Tab.ID? {
        guard let id = maximized[Key(window: window, splitID: split.id)],
              id == split.focusTabID, split.tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The panes a window shows: every pane, or the maximized one alone.
    public func visibleTabs(in split: SplitViewItem, window: SidebarWindowID?) -> [Tab] {
        guard let id = maximizedTab(in: split, window: window) else { return split.tabs }
        return split.tabs.filter { $0.id == id }
    }

    /// Expands the focused pane, or restores the split when it is expanded.
    /// Returns whether a pane is now expanded.
    @discardableResult
    public mutating func toggle(_ split: SplitViewItem, window: SidebarWindowID?) -> Bool {
        let key = Key(window: window, splitID: split.id)
        if maximizedTab(in: split, window: window) != nil {
            maximized[key] = nil
            return false
        }
        maximized[key] = split.focusTabID
        return true
    }

    public mutating func restore(_ splitID: SplitViewItem.ID, window: SidebarWindowID?) {
        maximized[Key(window: window, splitID: splitID)] = nil
    }

    public mutating func forgetWindow(_ window: SidebarWindowID) {
        maximized = maximized.filter { $0.key.window != window }
    }
}
