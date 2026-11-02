import Foundation

extension SidebarStore {

    func notifyMutation(_ mutation: SidebarJournalMutation? = nil) {
        if let mutation {
            mutationJournal.record(mutation)
        }
        onDidMutate?()
    }

    func journalInsertItem(
        id: UUID,
        spaceID: Space.ID?,
        container: SidebarItemContainer?,
        sortRank: String
    ) {
        notifyMutation(.insertItem(id: id, spaceID: spaceID, container: container, sortRank: sortRank))
    }

    func journalMoveItem(id: UUID, spaceID: Space.ID?, container: SidebarItemContainer?, sortRank: String) {
        notifyMutation(.moveItem(id: id, spaceID: spaceID, container: container, sortRank: sortRank))
    }

    func rankForNewItem(in entries: [SidebarEntry], atIndex index: Int) -> String {
        var peers = entries
        let clamped = max(0, min(index, peers.count))
        let beforeRank = clamped > 0 ? rank(of: peers[clamped - 1]) : nil
        let afterRank = clamped < peers.count ? rank(of: peers[clamped]) : nil
        if beforeRank == nil { return LexoRank.before(afterRank) }
        if afterRank == nil { return LexoRank.after(beforeRank) }
        if beforeRank! >= afterRank! { return LexoRank.after(beforeRank) }
        return LexoRank.between(beforeRank, afterRank)
    }

    func rankForNewFavorite(at index: Int) -> String {
        var peers = RankedSortable.sortedTabs(favorites)
        let clamped = max(0, min(index, peers.count))
        let beforeRank = clamped > 0 ? peers[clamped - 1].sortRank : nil
        let afterRank = clamped < peers.count ? peers[clamped].sortRank : nil
        if beforeRank == nil || beforeRank!.isEmpty { return LexoRank.before(afterRank) }
        if afterRank == nil || afterRank!.isEmpty { return LexoRank.after(beforeRank) }
        if beforeRank! >= afterRank! { return LexoRank.after(beforeRank) }
        return LexoRank.between(beforeRank, afterRank)
    }

    func rankForNewSpace() -> String {
        let peers = RankedSortable.sortedSpaces(spaces)
        return LexoRank.after(peers.last?.sortRank)
    }
}
