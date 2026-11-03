import Foundation

/// Identifies one browser window for per-window sidebar state.
public struct SidebarWindowID: Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Per-window focused space (SIDEBAR-SPEC §2.6, DATA-SCHEMA StorableWindows).
/// Every window shows its own space; the spaces and their content are shared.
/// `activeSpaceID` and `selectedItemID` belong to the key window, so menus,
/// shortcuts and the command bar act on it. A window that becomes key brings
/// its space back; the other windows keep theirs. Each space remembers its
/// own selection, so two windows on one space show the same selected item.
extension SidebarStore {

    /// A new window starts on the key window's space.
    public func registerWindow(_ window: SidebarWindowID, spaceID: Space.ID? = nil) {
        let space = spaceID.flatMap { space(withID: $0)?.id } ?? activeSpaceID
        focusedSpaceByWindow[window] = space
        if keyWindowID == nil { keyWindowID = window }
    }

    public func unregisterWindow(_ window: SidebarWindowID) {
        focusedSpaceByWindow[window] = nil
        if keyWindowID == window { keyWindowID = nil }
    }

    /// The window became key: its space becomes the active space (and its
    /// profile the active profile), with that space's remembered selection.
    public func windowBecameKey(_ window: SidebarWindowID) {
        let target = focusedSpaceByWindow[window].flatMap { space(withID: $0)?.id } ?? activeSpaceID
        keyWindowID = window
        if target != activeSpaceID { selectSpace(target) }
        focusedSpaceByWindow[window] = activeSpaceID
    }

    /// The space a window shows. Unknown windows, the key window and windows
    /// whose space was deleted show the active space.
    public func focusedSpaceID(in window: SidebarWindowID?) -> Space.ID {
        guard let window, window != keyWindowID,
              let id = focusedSpaceByWindow[window], space(withID: id) != nil else { return activeSpaceID }
        return id
    }

    public func focusedSpace(in window: SidebarWindowID?) -> Space {
        space(withID: focusedSpaceID(in: window)) ?? activeSpace
    }

    /// The selected item of a space: the live selection for the active space,
    /// the remembered one otherwise.
    public func selectedItemID(inSpace spaceID: Space.ID) -> UUID? {
        spaceID == activeSpaceID ? selectedItemID : restoredSelection(for: spaceID)
    }

    /// The tab a window's content area shows (a split's focused pane).
    public func selectedTab(inSpace spaceID: Space.ID) -> Tab? {
        guard let id = selectedItemID(inSpace: spaceID) else { return nil }
        if easelRef(withSidebarID: id) != nil { return nil }
        if let split = split(withID: id) { return tab(withID: split.focusTabID) }
        return tab(withID: id)
    }

    func followActiveSpaceInKeyWindow() {
        guard let keyWindowID else { return }
        focusedSpaceByWindow[keyWindowID] = activeSpaceID
    }
}
