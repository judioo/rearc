import Foundation

/// A window's multi-row selection in the sidebar (Arc: ⇧-click selects the
/// rows from the anchor to the clicked one, ⌘-click adds or removes one row;
/// the page does not change). The active item keeps its pill and is always
/// part of the selection while one exists; the other rows take a grey wash.
///
/// Rows are sidebar items in one space: tabs, splits, easels and folders
/// (a folder row selects the folder). Favorites tiles are not rows here:
/// nothing recorded of Arc shows a tile in a selection.
public struct SidebarMultiSelection: Equatable, Sendable {
    public let spaceID: Space.ID
    /// The space's selected item when the selection began. A different
    /// active item (a plain click, ⌃Tab, ⌘1) ends the selection.
    public let activeID: UUID?
    /// The selected rows besides the active one.
    public private(set) var others: Set<UUID>
    /// Where the next ⇧-click's range starts: the last ⌘-clicked row, else
    /// the active row.
    public private(set) var anchor: UUID?

    public init(spaceID: Space.ID, activeID: UUID?, others: Set<UUID> = [], anchor: UUID? = nil) {
        self.spaceID = spaceID
        self.activeID = activeID
        self.others = others.subtracting(activeID.map { [$0] } ?? [])
        self.anchor = anchor
    }

    /// No row besides the active one: there is no selection.
    public var isEmpty: Bool { others.isEmpty }

    /// Every selected id, the active one included.
    public var members: Set<UUID> {
        guard !isEmpty else { return [] }
        return activeID.map { others.union([$0]) } ?? others
    }

    public func contains(_ id: UUID) -> Bool {
        !isEmpty && (others.contains(id) || id == activeID)
    }

    /// ⇧-click: the visible rows from the anchor (else the active row) to
    /// `id`, in `visibleOrder`. Without either on screen the range is `id`.
    public mutating func extend(to id: UUID, visibleOrder: [UUID]) {
        guard let target = visibleOrder.firstIndex(of: id) else { return }
        let from: Int
        if let anchor, let index = visibleOrder.firstIndex(of: anchor) {
            from = index
        } else if let activeID, let index = visibleOrder.firstIndex(of: activeID) {
            anchor = activeID
            from = index
        } else {
            anchor = id
            from = target
        }
        let range = visibleOrder[min(from, target) ... max(from, target)]
        others = Set(range).subtracting(activeID.map { [$0] } ?? [])
    }

    /// ⌘-click: adds or removes one row; it becomes the anchor. The active
    /// row stays selected.
    public mutating func toggle(_ id: UUID) {
        guard id != activeID else { return }
        if others.remove(id) == nil { others.insert(id) }
        anchor = id
    }

    /// Drops the rows `keep` refuses (closed, archived, moved away).
    /// Returns the ids that left.
    @discardableResult
    public mutating func prune(keeping keep: (UUID) -> Bool) -> Set<UUID> {
        let gone = others.filter { !keep($0) }
        others.subtract(gone)
        if let anchor, gone.contains(anchor) { self.anchor = nil }
        return gone
    }

    /// The members in `order` (the space's outline order); members missing
    /// from it come last.
    public func ordered(in order: [UUID]) -> [UUID] {
        let members = members
        let known = order.filter { members.contains($0) }
        return known + members.subtracting(known).sorted { $0.uuidString < $1.uuidString }
    }

    /// The rows a row's context menu acts on: the whole selection when the
    /// row is in it, else that row alone (and the selection is dropped).
    public static func menuTargets(for id: UUID, selection: SidebarMultiSelection?, order: [UUID]) -> [UUID] {
        guard let selection, selection.contains(id) else { return [id] }
        return selection.ordered(in: order)
    }
}

public extension PageLinkCopyFormat {
    /// Several links, one per line (Arc's "Copied URLs" pastes one URL per
    /// line); Markdown puts one `[title](url)` per line.
    func text(links: [(url: URL, title: String)]) -> String {
        links.map { self == .markdown ? Self.markdownLink(url: $0.url, title: $0.title) : $0.url.absoluteString }
            .joined(separator: "\n")
    }

    /// The toast for several links: "Copied URLs" in the 2026-11-11 Arc
    /// recording; the binary's plural for cleaned links when any lost trackers.
    static func multipleConfirmation(cleaned: Bool) -> String {
        cleaned ? "Copied clean links without trackers" : "Copied URLs"
    }
}
