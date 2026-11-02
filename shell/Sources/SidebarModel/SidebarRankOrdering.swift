import Foundation

public enum RankedSortable {
    public static func sortRank<T>(_ item: T) -> String where T: SidebarRanked {
        item.sortRank.isEmpty ? LexoRank.initial : item.sortRank
    }

    public static func sortedEntries(_ entries: [SidebarEntry]) -> [SidebarEntry] {
        entries.sorted { lhs, rhs in
            rank(of: lhs) < rank(of: rhs)
        }
    }

    public static func sortedTabs(_ tabs: [Tab]) -> [Tab] {
        tabs.sorted { sortRank($0) < sortRank($1) }
    }

    public static func sortedSpaces(_ spaces: [Space]) -> [Space] {
        spaces.sorted { sortRank($0) < sortRank($1) }
    }

    private static func rank(of entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return sortRank(tab)
        case .split(let split): return sortRank(split)
        case .easel(let ref): return sortRank(ref)
        }
    }
}

public protocol SidebarRanked {
    var sortRank: String { get set }
}

extension Tab: SidebarRanked {}
extension Space: SidebarRanked {}
extension SplitViewItem: SidebarRanked {}
extension SidebarEaselRef: SidebarRanked {}

extension SidebarStore {
    func assignRanks(to entries: [SidebarEntry]) -> [SidebarEntry] {
        var sorted = RankedSortable.sortedEntries(entries)
        let needs = sorted.contains { rank(of: $0).isEmpty }
        guard needs else { return sorted }
        let ranks = LexoRank.initialSequence(count: sorted.count)
        for index in sorted.indices {
            switch sorted[index] {
            case .tab(var tab):
                if tab.sortRank.isEmpty { tab.sortRank = ranks[index] }
                sorted[index] = .tab(tab)
            case .split(var split):
                if split.sortRank.isEmpty { split.sortRank = ranks[index] }
                sorted[index] = .split(split)
            case .easel(var ref):
                if ref.sortRank.isEmpty { ref.sortRank = ranks[index] }
                sorted[index] = .easel(ref)
            }
        }
        return sorted
    }

    func rank(of entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.sortRank
        case .split(let split): return split.sortRank
        case .easel(let ref): return ref.sortRank
        }
    }

    func updateEntryRank(_ id: UUID, in entries: inout [SidebarEntry], newRank: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch entries[index] {
        case .tab(var tab):
            tab.sortRank = newRank
            entries[index] = .tab(tab)
        case .split(var split):
            split.sortRank = newRank
            entries[index] = .split(split)
        case .easel(var ref):
            ref.sortRank = newRank
            entries[index] = .easel(ref)
        }
    }

    func computeMoveRank(in entries: [SidebarEntry], movingID: UUID, toIndex: Int) -> String {
        var without = entries.filter { $0.id != movingID }
        let clamped = max(0, min(toIndex, without.count))
        let beforeRank = clamped > 0 ? rank(of: without[clamped - 1]) : nil
        let afterRank = clamped < without.count ? rank(of: without[clamped]) : nil
        if beforeRank == nil { return LexoRank.before(afterRank) }
        if afterRank == nil { return LexoRank.after(beforeRank) }
        if beforeRank! >= afterRank! {
            return LexoRank.after(beforeRank)
        }
        return LexoRank.between(beforeRank, afterRank)
    }

    func itemContainer(for location: TabLocation) -> SidebarItemContainer? {
        switch location {
        case .favorite: return .favorite
        case .pinned: return .pinned
        case .today: return .unpinned
        case .splitPane: return nil
        }
    }

    func spaceID(for location: TabLocation) -> Space.ID? {
        switch location {
        case .favorite: return nil
        case .pinned(let id), .today(let id): return id
        case .splitPane(let spaceID, _): return spaceID
        }
    }
}
