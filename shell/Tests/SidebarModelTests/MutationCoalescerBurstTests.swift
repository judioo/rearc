@testable import SidebarModel
import XCTest

/// The coalescer squashes each entry into what is pending, so a burst (the
/// onboarding's import of thousands of rows, on the main thread) stays
/// linear. It must squash exactly as a whole-list squash did.
final class MutationCoalescerBurstTests: XCTestCase {
    /// The whole-list squash the coalescer used to re-run on every entry.
    static func reference(_ entries: [SidebarJournalEntry]) -> [SidebarJournalEntry] {
        func movedID(_ e: SidebarJournalEntry) -> UUID? {
            switch e.mutation {
            case .moveItem(let id, _, _, _), .placeItemInFolder(let id, _, _): id
            default: nil
            }
        }
        var output: [SidebarJournalEntry] = []
        for entry in entries {
            switch entry.mutation {
            case .moveItem(let id, _, _, _):
                if let i = output.lastIndex(where: { movedID($0) == id }), case .moveItem = output[i].mutation {
                    output[i] = SidebarJournalEntry(sequence: output[i].sequence, timestamp: entry.timestamp, deviceID: entry.deviceID, mutation: entry.mutation)
                    continue
                }
            case .placeItemInFolder(let id, _, _):
                if let i = output.lastIndex(where: { movedID($0) == id }), case .placeItemInFolder = output[i].mutation {
                    output[i] = SidebarJournalEntry(sequence: output[i].sequence, timestamp: entry.timestamp, deviceID: entry.deviceID, mutation: entry.mutation)
                    continue
                }
            case .upsertItem(let id):
                if let i = output.lastIndex(where: { if case .upsertItem(let o) = $0.mutation { return o == id }; return false }) {
                    output[i] = entry
                    continue
                }
            default: break
            }
            output.append(entry)
        }
        var inserted = Set<UUID>()
        var result: [SidebarJournalEntry] = []
        for entry in output {
            switch entry.mutation {
            case .insertItem(let id, _, _, _):
                inserted.insert(id)
                result.append(entry)
            case .deleteItem(let id) where inserted.contains(id):
                inserted.remove(id)
                if let i = result.lastIndex(where: { if case .insertItem(let o, _, _, _) = $0.mutation { return o == id }; return false }) {
                    result.remove(at: i)
                }
            default:
                result.append(entry)
            }
        }
        return result
    }

    func testSquashesAsTheWholeListSquashDid() {
        var rng = SystemRandomNumberGenerator()
        let ids = (0 ..< 6).map { _ in UUID() }
        let space = UUID(), folder = UUID(), device = UUID()
        for _ in 0 ..< 400 {
            var entries: [SidebarJournalEntry] = []
            for seq in 0 ..< Int.random(in: 1 ... 40, using: &rng) {
                let id = ids.randomElement(using: &rng)!
                let rank = "r\(seq)"
                let mutation: SidebarJournalMutation = switch Int.random(in: 0 ..< 7, using: &rng) {
                case 0: .insertItem(id: id, spaceID: space, container: .pinned, sortRank: rank)
                case 1: .deleteItem(id: id)
                case 2: .upsertItem(id: id)
                case 3: .placeItemInFolder(id: id, folderID: folder, sortRank: rank)
                case 4: .focusSpace(spaceID: space)
                default: .moveItem(id: id, spaceID: space, container: .unpinned, sortRank: rank)
                }
                entries.append(SidebarJournalEntry(sequence: UInt64(seq + 1), timestamp: Date(timeIntervalSince1970: Double(seq)), deviceID: device, mutation: mutation))
            }
            let expected = Self.reference(entries)
            XCTAssertEqual(MutationCoalescer.squash(entries), expected)
            // One entry at a time through the coalescer, as the store sends them.
            let coalescer = MutationCoalescer(window: 60)
            let got = Locked<[SidebarJournalEntry]>([])
            coalescer.setHandler { batch in got.set(batch) }
            for entry in entries { coalescer.enqueue([entry]) }
            coalescer.flushNow()
            XCTAssertEqual(got.value, expected)
        }
    }

    /// An import's burst: 20,000 inserts and folder placements.
    func testABurstStaysLinear() {
        let coalescer = MutationCoalescer(window: 60)
        let device = UUID(), space = UUID(), folder = UUID()
        let start = Date()
        for seq in 0 ..< 10_000 {
            let id = UUID()
            coalescer.enqueue([SidebarJournalEntry(sequence: UInt64(2 * seq), timestamp: start, deviceID: device,
                                                   mutation: .insertItem(id: id, spaceID: space, container: .pinned, sortRank: "a"))])
            coalescer.enqueue([SidebarJournalEntry(sequence: UInt64(2 * seq + 1), timestamp: start, deviceID: device,
                                                   mutation: .placeItemInFolder(id: id, folderID: folder, sortRank: "b"))])
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "an import's burst must not stall the main thread")
        let count = Locked(0)
        coalescer.setHandler { batch in count.set(batch.count) }
        coalescer.flushNow()
        XCTAssertEqual(count.value, 20_000)
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

/// A real bookmarks file has thousands of links; the import sets them once.
@MainActor
final class LargeBookmarkImportTests: XCTestCase {
    func testThousandsOfBookmarksImportAtOnceInOrder() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let folders: [BookmarkNode] = (0 ..< 50).map { f in
            .folder(title: "F\(f)", children: (0 ..< 100).map { .link(title: "L\(f)-\($0)", url: URL(string: "https://example.com/\(f)/\($0)")!) }
                + [.folder(title: " ", children: [.link(title: "deep", url: URL(string: "https://example.com/deep/\(f)")!)])])
        }
        let start = Date()
        let result = try XCTUnwrap(store.importBookmarks(folders + [.link(title: "top", url: URL(string: "https://example.com/top")!)], spaceName: "Chrome – Person 1"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(result.tabs, 50 * 101 + 1)
        let pinned = store.content(for: result.space.id).pinned
        XCTAssertEqual(pinned.count, 51)
        XCTAssertEqual(pinned.map(\.id).count, Set(pinned.map(\.id)).count)
        guard case .folder(let first) = pinned[0], case .tab(let last) = pinned[50] else { return XCTFail("folders, then the loose link") }
        XCTAssertEqual(first.title, "F0")
        XCTAssertEqual(first.children.count, 101)
        XCTAssertEqual(last.title, "top")
        XCTAssertEqual(last.kind, .pinned)
        guard case .folder(let unnamed) = first.children[100] else { return XCTFail("the nested folder") }
        XCTAssertEqual(unnamed.title, "New Folder")
        let ranks = pinned.map { store.rank(of: $0) }
        XCTAssertEqual(ranks, ranks.sorted(), "file order is rank order")
        XCTAssertFalse(store.expandedFolderIDs.contains(first.id), "imported folders start closed")
        XCTAssertNotNil(store.tab(withID: last.id))
    }
}
