import Foundation

/// The rows of Library › Downloads' table (perf-8): the list, or the
/// search's matches, and what changed between two of them as table edits.
///
/// A SwiftUI `LazyVStack` re-ran its update and layout for the rows on every
/// change and scroll step. The table instead reloads only the rows a change
/// touched, so the edits are worked out here: rows only come and go at the
/// list's ends (a new download at the front, archived pages at the back, a
/// removed row), so a common prefix and suffix by id find them in one pass.
public struct DownloadTableRows: Sendable {
    public private(set) var records: [DownloadRecord] = []

    /// Table edits that turn the old rows into the new ones.
    public struct Update: Equatable, Sendable {
        /// Indexes into the old rows.
        public var removed = IndexSet()
        /// Indexes into the new rows.
        public var inserted = IndexSet()
        /// Kept rows whose record changed, as indexes into the new rows.
        public var reloaded = IndexSet()
        /// Too much changed for edits (a new search, Clear): reload the table.
        public var reloadsAll = false

        public init(removed: IndexSet = [], inserted: IndexSet = [], reloaded: IndexSet = [], reloadsAll: Bool = false) {
            self.removed = removed
            self.inserted = inserted
            self.reloaded = reloaded
            self.reloadsAll = reloadsAll
        }

        public var isEmpty: Bool { !reloadsAll && removed.isEmpty && inserted.isEmpty && reloaded.isEmpty }
        /// Rows inserted at the top while kept rows follow them: the table
        /// shifts its scroll position by these to keep what is on screen.
        public var insertedAbove: Int {
            guard !reloadsAll, removed.isEmpty, inserted.first == 0 else { return 0 }
            return inserted.count
        }
    }

    /// Past this many rows removed and inserted, other than an append at the
    /// end, the table reloads instead (one search keystroke replaces most rows).
    public static let editLimit = 200

    public init(records: [DownloadRecord] = []) {
        self.records = records
    }

    public var count: Int { records.count }

    /// Takes `new` and returns the edits; `reloadAll` (the search changed)
    /// skips the diff.
    public mutating func update(to new: [DownloadRecord], reloadAll: Bool = false) -> Update {
        let old = records
        records = new
        if reloadAll || old.isEmpty != new.isEmpty {
            return Update(reloadsAll: true)
        }
        let oldCount = old.count, newCount = new.count
        var reloaded = IndexSet()
        var prefix = 0
        while prefix < oldCount, prefix < newCount, old[prefix].id == new[prefix].id {
            if old[prefix] != new[prefix] { reloaded.insert(prefix) }
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCount - prefix, suffix < newCount - prefix, old[oldCount - 1 - suffix].id == new[newCount - 1 - suffix].id {
            if old[oldCount - 1 - suffix] != new[newCount - 1 - suffix] { reloaded.insert(newCount - 1 - suffix) }
            suffix += 1
        }
        let removed = IndexSet(integersIn: prefix ..< oldCount - suffix)
        let inserted = IndexSet(integersIn: prefix ..< newCount - suffix)
        let appends = removed.isEmpty && suffix == 0
        if !appends, removed.count + inserted.count > Self.editLimit {
            return Update(reloadsAll: true)
        }
        return Update(removed: removed, inserted: inserted, reloaded: reloaded)
    }

    /// The rows a context menu acts on: the selection when the clicked row
    /// is in it (as in Finder), else the clicked row alone.
    public static func targets(clicked: Int, selected: IndexSet, count: Int) -> IndexSet {
        guard clicked >= 0, clicked < count else { return selected.filteredIndexSet { $0 < count } }
        return selected.contains(clicked) ? selected.filteredIndexSet { $0 < count } : IndexSet(integer: clicked)
    }
}
