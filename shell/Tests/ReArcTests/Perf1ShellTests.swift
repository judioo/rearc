import AppKit
import Observation
import XCTest
@testable import ReArc
@testable import SidebarModel

/// perf-1: sidebar rows laid out from the outline match the entry rows they
/// replace, and engine and favicon lookups notify per key.
@MainActor
final class Perf1ShellTests: XCTestCase {

    private func url(_ host: String) -> URL { URL(string: "https://\(host).test")! }

    private final class Probe {
        private(set) var fired = 0
        func watch(_ read: @escaping () -> Void) {
            withObservationTracking(read) { [weak self] in self?.fired += 1 }
        }
    }

    func testOutlineRowsMatchEntryRows() throws {
        let store = SidebarStore()
        let a = store.addTab(kind: .pinned, title: "A", url: url("a"))
        let b = store.addTab(kind: .pinned, title: "B", url: url("b"))
        let c = store.addTab(kind: .pinned, title: "C", url: url("c"))
        let outer = try XCTUnwrap(store.createFolder(title: "Outer", containing: [a.id, b.id]))
        let inner = try XCTUnwrap(store.createFolder(title: "Inner", parentFolderID: outer.id, containing: [c.id]))
        let space = store.activeSpaceID
        let content = store.content(for: space), outline = store.outline(for: space)
        let ids = [a.id, b.id, c.id, outer.id, inner.id]
        for expanded in [Set<UUID>(), [outer.id], [outer.id, inner.id], [inner.id]] {
            for selected in [nil] + ids {
                let entries = SidebarRowItem.rows(content.pinned, expanded: expanded, selected: selected)
                let rows = SidebarOutlineRow.rows(outline.pinned, expanded: expanded, selected: selected)
                XCTAssertEqual(rows.map(\.id), entries.map(\.id), "expanded \(expanded.count), selected \(String(describing: selected))")
                XCTAssertEqual(rows.map(\.depth), entries.map(\.depth))
            }
        }
        XCTAssertEqual(Set(SidebarOutlineRow.peekCandidates(outline.pinned, expanded: [])), [a.id, b.id, c.id])
        XCTAssertEqual(SidebarOutlineRow.peekCandidates(outline.pinned, expanded: [outer.id]), [c.id])
        XCTAssertTrue(SidebarOutlineRow.peekCandidates(outline.pinned, expanded: [outer.id, inner.id]).isEmpty)
    }

    func testEngineLookupsNotifyPerTab() {
        let host = EngineHost()
        let profile = UUID()
        let a = Tab(kind: .today, title: "A", url: url("a")), b = Tab(kind: .today, title: "B", url: url("b"))
        let probe = Probe()
        probe.watch { _ = host.engine(forTabID: a.id, profileID: profile) }
        _ = host.engine(for: b, profileID: profile)
        XCTAssertEqual(probe.fired, 0, "another tab's engine")
        host.pruneTabEngines(retaining: [.init(tabID: b.id, profileID: profile)])
        XCTAssertEqual(probe.fired, 0, "a prune that keeps everything changes nothing")
        _ = host.engine(for: a, profileID: profile)
        XCTAssertEqual(probe.fired, 1)
        XCTAssertNotNil(host.engine(forTabID: a.id, profileID: profile))
        host.pruneTabEngines(retaining: [.init(tabID: a.id, profileID: profile)])
        XCTAssertNil(host.engine(forTabID: b.id, profileID: profile))
        XCTAssertNotNil(host.engine(forTabID: a.id, profileID: profile))
    }

    func testFaviconLookupsNotifyPerHost() throws {
        let store = FaviconStore(directory: nil)
        let probe = Probe()
        probe.watch { _ = store.image(for: self.url("a")) }
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        let png = try XCTUnwrap(image.tiffRepresentation)
        XCTAssertTrue(store.store(png, for: url("b"), persist: false))
        XCTAssertEqual(probe.fired, 0, "another host's icon")
        XCTAssertTrue(store.store(png, for: url("a"), persist: false))
        XCTAssertEqual(probe.fired, 1)
        XCTAssertNotNil(store.image(for: url("a")))
    }
}
