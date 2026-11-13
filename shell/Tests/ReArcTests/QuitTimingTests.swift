import Foundation
import Testing
@testable import ReArc
@testable import SidebarModel

/// The shell's share of a quit on a large sidebar: 4 profiles, 20 spaces,
/// 2000 tabs (about the size of the owner's 1.8 MB sidebar.json) and a full
/// visit history. Prints each step's time; run alone for numbers
/// (`swift test --filter QuitTimingTests`).
@MainActor
struct QuitTimingTests {
    static func largeStore() -> SidebarStore {
        let store = SidebarStore()
        var profiles = [store.profiles[0].id]
        for index in 1 ..< 4 { profiles.append(store.addProfile(name: "Quit Profile \(index + 1)").id) }
        var page = 0
        for (index, profile) in profiles.enumerated() {
            for space in 0 ..< 5 {
                let spaceID: Space.ID
                if space == 0, let first = store.spaces(in: profile).first {
                    spaceID = first.id
                } else {
                    var draft = SpaceDraft.suggested(in: store, profileID: profile)
                    draft.name = "Quit \(index + 1).\(space + 1)"
                    guard let created = store.createSpace(from: draft) else { continue }
                    spaceID = created.id
                }
                for tab in 0 ..< 100 {
                    page += 1
                    let url = URL(string: "https://site\(page % 97).quit.invalid/articles/\(page)/a-long-readable-slug-for-page-\(page)?ref=sidebar&utm_source=rearc")!
                    _ = store.addTab(kind: tab < 10 ? .pinned : .today, title: "Quit fixture page \(page) — a title of ordinary length", url: url, in: spaceID)
                }
            }
        }
        return store
    }

    static func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @Test func prepareForQuitOnALargeSidebar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-quit-timing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = SidebarFilePersistence(fileURL: folder.appendingPathComponent("sidebar.json"))
        let model = BrowserViewModel(store: Self.largeStore(), persistence: persistence, faviconStore: FaviconStore(directory: nil))
        for index in 0 ..< VisitHistory.capacity {
            model.visitHistory.recordVisit(url: URL(string: "https://history\(index % 211).quit.invalid/visit/\(index)")!,
                                           title: "Visited page \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        // The first save writes the files; the timed quit is the common one, after nothing changed.
        model.prepareForQuit()
        let size = try FileManager.default.attributesOfItem(atPath: persistence.fileURL.path)[.size] as? Int ?? 0
        #expect(size > 1_000_000, "the fixture is the size of a large real sidebar")

        // What changed since the last save is on disk when prepareForQuit returns.
        let lastTab = try #require(model.store.displayTabs().first)
        model.store.updateTab(lastTab.id, title: "Renamed just before the quit", url: lastTab.url)
        model.visitHistory.recordVisit(url: URL(string: "https://last.quit.invalid/")!, title: "Last visit", at: Date())
        model.prepareForQuit()
        let saved = try String(contentsOf: persistence.fileURL, encoding: .utf8)
        #expect(saved.contains("Renamed just before the quit"))
        let history = VisitHistoryFile.load(from: try #require(model.historyFileURL))
        #expect(history.records.values.contains { $0.title == "Last visit" })

        let flush = Self.time { model.persistence.flush() }
        let historySave = Self.time { model.saveVisitHistory() }
        let downloads = Self.time { model.downloads.save() }
        let quit = Self.time { model.prepareForQuit() }
        print("[quit-timing] sidebar.json \(size / 1024) KiB, \(model.store.spaces.count) spaces: "
            + String(format: "sidebar flush %.1f ms, history save %.1f ms, downloads save %.1f ms; prepareForQuit %.1f ms on the main thread",
                     flush, historySave, downloads, quit))
    }
}
