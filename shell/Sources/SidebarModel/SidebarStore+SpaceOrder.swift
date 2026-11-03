import Foundation

/// Reordering spaces within their profile (Arc Manage Spaces / `SortSpaces`,
/// SIDEBAR-SPEC §4.6). Ctrl+1…9 and the switcher follow this order.
extension SidebarStore {

    /// Moves a space to `destination` among its profile's spaces (index after
    /// removal). The new LexoRank sits between its new global neighbours.
    @discardableResult
    public func moveSpace(_ id: Space.ID, toIndex destination: Int) -> Bool {
        guard let moving = space(withID: id) else { return false }
        let peers = spaces(in: moving.profileID).filter { $0.id != id }
        let clamped = max(0, min(destination, peers.count))
        let current = spaces(in: moving.profileID).firstIndex(where: { $0.id == id })
        guard current != clamped else { return false }
        var ordered = spaces.filter { $0.id != id }
        let insertAt: Int
        if clamped < peers.count, let anchor = ordered.firstIndex(where: { $0.id == peers[clamped].id }) {
            insertAt = anchor
        } else if let last = peers.last, let anchor = ordered.firstIndex(where: { $0.id == last.id }) {
            insertAt = anchor + 1
        } else {
            insertAt = ordered.count
        }
        let before = insertAt > 0 ? ordered[insertAt - 1].sortRank : nil
        let after = insertAt < ordered.count ? ordered[insertAt].sortRank : nil
        var moved = moving
        moved.sortRank = Self.rank(between: before, and: after)
        ordered.insert(moved, at: insertAt)
        spaces = ordered
        notifyMutation(.moveSpace(id: id, sortRank: moved.sortRank))
        return true
    }

    static func rank(between before: String?, and after: String?) -> String {
        let before = before.flatMap { $0.isEmpty ? nil : $0 }
        let after = after.flatMap { $0.isEmpty ? nil : $0 }
        if before == nil { return LexoRank.before(after) }
        if after == nil { return LexoRank.after(before) }
        if before! >= after! { return LexoRank.after(before) }
        return LexoRank.between(before, after)
    }
}
