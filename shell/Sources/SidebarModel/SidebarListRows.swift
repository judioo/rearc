import Foundation

/// One visible row of a space's outline and its folder depth. A collapsed
/// folder still shows its selected descendant (Arc's "peeked" expansion
/// state).
public struct SidebarOutlineRow: Identifiable, Equatable {
    public let node: SidebarOutlineNode
    public let depth: Int
    public var id: UUID { node.id }

    public init(node: SidebarOutlineNode, depth: Int) {
        self.node = node
        self.depth = depth
    }

    public static func rows(_ nodes: [SidebarOutlineNode], depth: Int = 0, expanded: Set<UUID>, selected: UUID?) -> [SidebarOutlineRow] {
        nodes.flatMap { node -> [SidebarOutlineRow] in
            guard node.kind == .folder else { return [SidebarOutlineRow(node: node, depth: depth)] }
            let header = SidebarOutlineRow(node: node, depth: depth)
            if expanded.contains(node.id) {
                return [header] + rows(node.children, depth: depth + 1, expanded: expanded, selected: selected)
            }
            if let selected, let leaf = SidebarOutlineNode.leaves(node.children).first(where: { $0.id == selected }) {
                return [header, SidebarOutlineRow(node: leaf, depth: depth + 1)]
            }
            return [header]
        }
    }

    /// Rows shown only while selected: the leaves of collapsed folders.
    public static func peekCandidates(_ nodes: [SidebarOutlineNode], expanded: Set<UUID>) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            guard node.kind == .folder else { return [] }
            if expanded.contains(node.id) { return peekCandidates(node.children, expanded: expanded) }
            return SidebarOutlineNode.leaves(node.children).map(\.id)
        }
    }
}

/// One row of a space's sidebar list as the table lays it out (perf-5):
/// the space header, the pinned rows, the Today divider, New Tab, the Today
/// rows, and while a sidebar drag is under way a drop row after each section.
public enum SidebarListRow: Equatable, Identifiable {
    case header
    case item(SidebarOutlineRow, section: ItemContainerKind.SpaceSection)
    case todayDivider
    case newTab
    /// The drop area after a section's last row; `isEmpty` shows Arc's
    /// "Drop here to pin/unpin" placeholder.
    case sectionEnd(ItemContainerKind.SpaceSection, isEmpty: Bool)

    public enum ID: Hashable {
        case header, todayDivider, newTab
        case item(UUID)
        case sectionEnd(ItemContainerKind.SpaceSection)
    }

    public var id: ID {
        switch self {
        case .header: .header
        case .item(let row, _): .item(row.id)
        case .todayDivider: .todayDivider
        case .newTab: .newTab
        case .sectionEnd(let section, _): .sectionEnd(section)
        }
    }

    /// The space's rows in display order. `selection` answers which of a set
    /// of ids is the space's shown selection, if any (it is asked only about
    /// rows that show while selected, so a reader observes those alone).
    public static func rows(
        outline: SidebarSpaceOutline,
        expanded: Set<UUID>,
        pinnedCollapsed: Bool,
        isDragging: Bool,
        selection: ([UUID]) -> UUID?
    ) -> [SidebarListRow] {
        func section(_ nodes: [SidebarOutlineNode], _ section: ItemContainerKind.SpaceSection) -> [SidebarListRow] {
            let candidates = SidebarOutlineRow.peekCandidates(nodes, expanded: expanded)
            let peeked = candidates.isEmpty ? nil : selection(candidates)
            var rows = SidebarOutlineRow.rows(nodes, expanded: expanded, selected: peeked).map { SidebarListRow.item($0, section: section) }
            if isDragging { rows.append(.sectionEnd(section, isEmpty: nodes.isEmpty)) }
            return rows
        }
        // A collapsed Pinned section keeps only its selected item
        // (`PinnedSectionCollapseState.visibleEntries`).
        var pinned = outline.pinned
        if pinnedCollapsed {
            let leaves = SidebarOutlineNode.leaves(pinned)
            let selected = selection(leaves.map(\.id))
            pinned = leaves.filter { $0.id == selected }
        }
        return [.header] + section(pinned, .pinned) + [.todayDivider, .newTab] + section(outline.today, .unpinned)
    }
}

/// Row heights for the sidebar list. Tab and folder rows sit on Arc's pitch;
/// easels, splits and the empty-section placeholder size to their content,
/// so the table measures them and keeps an estimate until it has.
public struct SidebarListHeights: Equatable {
    public var rowPitch: Double = 41
    /// The header's 28 pt row and its gap to the first row's pitch.
    public var header: Double = 28 + 7.5
    public var todayDivider: Double = 17
    /// The drop line after a section that has rows.
    public var sectionEnd: Double = 10
    public var easelEstimate: Double = 29
    public var splitEstimate: Double = 80
    public var placeholderEstimate: Double = 29

    public init() {}

    /// The height a row always has, or nil when it sizes to its content.
    public func fixed(_ row: SidebarListRow) -> Double? {
        switch row {
        case .header: header
        case .todayDivider: todayDivider
        case .newTab: rowPitch
        case .sectionEnd(_, let isEmpty): isEmpty ? nil : sectionEnd
        case .item(let item, _):
            switch item.node.kind {
            case .tab, .folder: rowPitch
            case .easel, .split: nil
            }
        }
    }

    /// The row's height: fixed, else measured, else the estimate. Never 0:
    /// a table row must have some height.
    public func height(_ row: SidebarListRow, measured: Double?) -> Double {
        if let fixed = fixed(row) { return fixed }
        if let measured, measured >= 1 { return measured }
        switch row {
        case .item(let item, _) where item.node.kind == .split: return splitEstimate
        case .item: return easelEstimate
        default: return placeholderEstimate
        }
    }
}

/// What changed between two row lists, in the terms a table takes: rows
/// removed (old indexes), inserted (new indexes) and kept but changed, so
/// their cells are configured again (new indexes).
public struct SidebarListDiff: Equatable {
    public var removed = IndexSet()
    public var inserted = IndexSet()
    public var reloaded = IndexSet()

    public init(removed: IndexSet = [], inserted: IndexSet = [], reloaded: IndexSet = []) {
        self.removed = removed
        self.inserted = inserted
        self.reloaded = reloaded
    }

    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }
    /// Rows added or taken away (a move counts twice).
    public var structuralCount: Int { removed.count + inserted.count }

    /// Ids are unique within a list. A row that moved is removed and
    /// inserted; one that kept its place relative to the others but changed
    /// (depth, the placeholder) is reloaded.
    public static func between(_ old: [SidebarListRow], _ new: [SidebarListRow]) -> SidebarListDiff {
        let difference = new.map(\.id).difference(from: old.map(\.id))
        var diff = SidebarListDiff()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): diff.removed.insert(offset)
            case .insert(let offset, _, _): diff.inserted.insert(offset)
            }
        }
        var oldIndex = 0
        for (newIndex, row) in new.enumerated() where !diff.inserted.contains(newIndex) {
            while diff.removed.contains(oldIndex) { oldIndex += 1 }
            if old[oldIndex] != row { diff.reloaded.insert(newIndex) }
            oldIndex += 1
        }
        return diff
    }
}
