import Foundation
import Testing
@testable import SidebarModel

/// perf-5: the sidebar table's flattened rows, the diff it animates, and the
/// row heights it reports.
struct Perf5ListRowsTests {
    private func tab() -> SidebarOutlineNode { SidebarOutlineNode(id: UUID(), kind: .tab) }

    private func ids(_ rows: [SidebarListRow]) -> [SidebarListRow.ID] { rows.map(\.id) }

    @Test func layoutOrderAndDragRows() {
        let p1 = tab(), p2 = tab(), t1 = tab()
        let outline = SidebarSpaceOutline(pinned: [p1, p2], today: [t1])
        let rows = SidebarListRow.rows(outline: outline, expanded: [], pinnedCollapsed: false, isDragging: false) { _ in nil }
        #expect(ids(rows) == [.header, .item(p1.id), .item(p2.id), .todayDivider, .newTab, .item(t1.id)])
        #expect(rows[1] == .item(SidebarOutlineRow(node: p1, depth: 0), section: .pinned))
        #expect(rows[5] == .item(SidebarOutlineRow(node: t1, depth: 0), section: .unpinned))

        let dragging = SidebarListRow.rows(outline: outline, expanded: [], pinnedCollapsed: false, isDragging: true) { _ in nil }
        #expect(ids(dragging) == [.header, .item(p1.id), .item(p2.id), .sectionEnd(.pinned), .todayDivider, .newTab,
                                  .item(t1.id), .sectionEnd(.unpinned)])
        #expect(dragging[3] == .sectionEnd(.pinned, isEmpty: false))

        let empty = SidebarListRow.rows(outline: SidebarSpaceOutline(pinned: [], today: []), expanded: [],
                                        pinnedCollapsed: false, isDragging: true) { _ in nil }
        #expect(empty == [.header, .sectionEnd(.pinned, isEmpty: true), .todayDivider, .newTab, .sectionEnd(.unpinned, isEmpty: true)])
    }

    @Test func foldersExpandAndPeek() {
        let a = tab(), b = tab(), c = tab()
        let inner = SidebarOutlineNode(id: UUID(), kind: .folder, children: [c])
        let folder = SidebarOutlineNode(id: UUID(), kind: .folder, children: [a, inner, b])
        let outline = SidebarSpaceOutline(pinned: [folder], today: [])
        func rows(expanded: Set<UUID>, selected: UUID?) -> [SidebarListRow] {
            SidebarListRow.rows(outline: outline, expanded: expanded, pinnedCollapsed: false, isDragging: false) {
                $0.contains { $0 == selected } ? selected : nil
            }
        }
        #expect(ids(rows(expanded: [], selected: nil)) == [.header, .item(folder.id), .todayDivider, .newTab])
        // A collapsed folder still shows its selected leaf, one level in.
        let peeked = rows(expanded: [], selected: c.id)
        #expect(ids(peeked) == [.header, .item(folder.id), .item(c.id), .todayDivider, .newTab])
        #expect(peeked[2] == .item(SidebarOutlineRow(node: c, depth: 1), section: .pinned))
        let open = rows(expanded: [folder.id, inner.id], selected: nil)
        #expect(ids(open) == [.header, .item(folder.id), .item(a.id), .item(inner.id), .item(c.id), .item(b.id), .todayDivider, .newTab])
        #expect(open[4] == .item(SidebarOutlineRow(node: c, depth: 2), section: .pinned))
    }

    @Test func collapsedPinnedKeepsOnlyTheSelection() {
        let a = tab(), b = tab()
        let folder = SidebarOutlineNode(id: UUID(), kind: .folder, children: [b])
        let outline = SidebarSpaceOutline(pinned: [a, folder], today: [])
        var asked: [[UUID]] = []
        let rows = SidebarListRow.rows(outline: outline, expanded: [], pinnedCollapsed: true, isDragging: true) {
            asked.append($0)
            return $0.contains(b.id) ? b.id : nil
        }
        #expect(asked.first == [a.id, b.id], "the collapse asks about every pinned leaf")
        #expect(ids(rows) == [.header, .item(b.id), .sectionEnd(.pinned), .todayDivider, .newTab, .sectionEnd(.unpinned)])
        #expect(rows[1] == .item(SidebarOutlineRow(node: b, depth: 0), section: .pinned))
        #expect(rows[2] == .sectionEnd(.pinned, isEmpty: false))
        let none = SidebarListRow.rows(outline: outline, expanded: [], pinnedCollapsed: true, isDragging: true) { _ in nil }
        #expect(none[1] == .sectionEnd(.pinned, isEmpty: true), "nothing selected: Pinned is empty and offers the placeholder")
    }

    // MARK: Diff

    /// Applies `diff` the way the table does: removals at old indexes, then
    /// insertions at new ones.
    private func apply(_ diff: SidebarListDiff, from old: [SidebarListRow], to new: [SidebarListRow]) -> [SidebarListRow] {
        var rows = old
        for index in diff.removed.reversed() { rows.remove(at: index) }
        for index in diff.inserted { rows.insert(new[index], at: index) }
        for index in diff.reloaded { rows[index] = new[index] }
        return rows
    }

    @Test func diffInsertsRemovesAndReloads() {
        let a = tab(), b = tab(), c = tab()
        func item(_ node: SidebarOutlineNode, _ depth: Int = 0) -> SidebarListRow {
            .item(SidebarOutlineRow(node: node, depth: depth), section: .unpinned)
        }
        let old: [SidebarListRow] = [.header, .todayDivider, .newTab, item(a), item(b)]
        #expect(SidebarListDiff.between(old, old).isEmpty)

        let closed = SidebarListDiff.between(old, [.header, .todayDivider, .newTab, item(b)])
        #expect(closed == SidebarListDiff(removed: [3]))

        let opened = SidebarListDiff.between(old, [.header, .todayDivider, .newTab, item(c), item(a), item(b)])
        #expect(opened == SidebarListDiff(inserted: [3]))

        // Moved into a folder: same place, one level in.
        let nested = SidebarListDiff.between(old, [.header, .todayDivider, .newTab, item(a), item(b, 1)])
        #expect(nested == SidebarListDiff(reloaded: [4]))

        let reordered = [SidebarListRow.header, .todayDivider, .newTab, item(b), item(a)]
        let moved = SidebarListDiff.between(old, reordered)
        #expect(moved.structuralCount == 2 && moved.reloaded.isEmpty)
        #expect(apply(moved, from: old, to: reordered) == reordered)

        let dragging = [SidebarListRow.header, .sectionEnd(.pinned, isEmpty: true), .todayDivider, .newTab, item(a), item(b)]
        #expect(SidebarListDiff.between(old, dragging) == SidebarListDiff(inserted: [1]))
        let filled = [SidebarListRow.header, .sectionEnd(.pinned, isEmpty: false), .todayDivider, .newTab, item(a), item(b)]
        #expect(SidebarListDiff.between(dragging, filled) == SidebarListDiff(reloaded: [1]))
    }

    @Test func randomEditsApplyToTheNewList() {
        var generator = SystemRandomNumberGenerator()
        let pool = (0 ..< 40).map { _ in tab() }
        func randomRows() -> [SidebarListRow] {
            let nodes = pool.shuffled(using: &generator).prefix(Int.random(in: 0 ... pool.count, using: &generator))
            return [.header, .todayDivider, .newTab] + nodes.map {
                .item(SidebarOutlineRow(node: $0, depth: Int.random(in: 0 ... 1, using: &generator)), section: .unpinned)
            }
        }
        for _ in 0 ..< 300 {
            let old = randomRows(), new = randomRows()
            let diff = SidebarListDiff.between(old, new)
            #expect(apply(diff, from: old, to: new) == new)
            #expect(diff.removed.allSatisfy { old.indices.contains($0) })
            #expect(diff.inserted.allSatisfy { new.indices.contains($0) })
            #expect(diff.reloaded.allSatisfy { !diff.inserted.contains($0) })
        }
    }

    // MARK: Heights

    @Test func heightsByKind() {
        let heights = SidebarListHeights()
        func item(_ kind: SidebarOutlineNode.Kind) -> SidebarListRow {
            .item(SidebarOutlineRow(node: SidebarOutlineNode(id: UUID(), kind: kind), depth: 0), section: .pinned)
        }
        #expect(heights.fixed(.header) == 35.5)
        #expect(heights.fixed(.newTab) == 41)
        #expect(heights.fixed(.todayDivider) == 17)
        #expect(heights.fixed(item(.tab)) == 41)
        #expect(heights.fixed(item(.folder)) == 41)
        #expect(heights.fixed(.sectionEnd(.pinned, isEmpty: false)) == 10)
        #expect(heights.fixed(item(.split)) == nil)
        #expect(heights.fixed(item(.easel)) == nil)
        #expect(heights.fixed(.sectionEnd(.unpinned, isEmpty: true)) == nil)

        #expect(heights.height(item(.split), measured: nil) == heights.splitEstimate)
        #expect(heights.height(item(.easel), measured: nil) == heights.easelEstimate)
        #expect(heights.height(.sectionEnd(.pinned, isEmpty: true), measured: nil) == heights.placeholderEstimate)
        #expect(heights.height(item(.split), measured: 97) == 97)
        #expect(heights.height(item(.split), measured: 0) == heights.splitEstimate, "a row is never 0 tall")
        #expect(heights.height(item(.tab), measured: 12) == 41, "a fixed row ignores a measurement")
    }
}
