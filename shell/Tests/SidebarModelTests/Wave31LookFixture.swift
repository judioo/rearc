import XCTest
@testable import SidebarModel

/// Writes a `sidebar.json` shaped like the user's Arc capture (one space on
/// the default theme, pinned tabs and folders, a Today section, nothing
/// selected) for the side-by-side in docs/observations/rearc-vs-arc/.
/// Runs only when `REARC_LOOK_FIXTURE` names the file to write.
final class Wave31LookFixture: XCTestCase {
    /// The capture's Today rows, top to bottom.
    static let todayTopToBottom: [(String, String)] = [
        ("Alex Rivera", "https://linkedin.com/in/a"), ("Status", "https://status.example.com"),
        ("Activity | API Dashboard", "https://example.com/activity"), ("Spending", "https://example.com/spending"),
        ("Usage", "https://example.com/usage"), ("Download Arc", "https://arc.net"),
        ("Sam Taylor", "https://google.com/search?q=dana"), ("Sam Taylor", "https://linkedin.com/in/b"),
        ("Field Notes", "https://example.com/rtr"), ("Jordan Lee", "https://linkedin.com/in/c"),
    ]

    func testFixtureTodayMatchesTheCaptureTopToBottom() {
        let store = Self.makeStore()
        let titles = store.sectionEntries(for: .unpinned, spaceID: store.activeSpaceID).compactMap { entry -> String? in
            if case .tab(let tab) = entry { return tab.title }
            return nil
        }
        XCTAssertEqual(titles, Self.todayTopToBottom.map(\.0))
    }

    func testWriteLookFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["REARC_LOOK_FIXTURE"] else {
            throw XCTSkip("set REARC_LOOK_FIXTURE to write the fixture")
        }
        let store = Self.makeStore()
        // The capture's bottom bar shows 14 spaces; Imara is the second.
        for index in 0 ..< 13 {
            let other = store.addSpace(name: "Space \(index + 2)", theme: .arcDefault, iconName: "circle.fill")
            if index == 0 { _ = store.moveSpace(other.id, toIndex: 0) }
        }
        store.selectedItemID = nil
        var snapshot = store.makeSnapshot()
        snapshot.selectedItemID = nil
        snapshot.selectionBySpace = [:]
        let data = try JSONEncoder().encode(snapshot)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func makeStore() -> SidebarStore {
        let store = SidebarStore()
        let space = store.spaces[0].id
        store.spaces[0].name = "Imara"
        store.spaces[0].iconName = "🪴"
        store.spaces[0].theme = .arcDefault
        func tab(_ title: String, _ url: String, _ kind: Tab.Kind = .pinned) {
            _ = store.addTab(kind: kind, title: title, url: URL(string: url)!, in: space)
        }
        func folder(_ title: String) {
            _ = store.createFolder(title: title, in: space)
        }
        tab("Gmail - Email Service", "https://mail.google.com")
        tab("Calendar", "https://calendar.google.com")
        tab("Calendly", "https://calendly.com")
        folder("Company & Tax")
        folder("Legacy")
        folder("Projects")
        tab("Projects are becoming…", "https://claude.ai")
        folder("Billing")
        folder("SaaS management")
        folder("convex PR")
        folder("Designs")
        folder("Research")
        tab("example/notes: Reverse engineering", "https://github.com/example/notes")
        folder("hack")
        tab("Weekend Game – Puzzle night", "https://example.com/beast")
        folder("Field Notes")
        tab("Codebase notes", "https://example.com/fallow")
        // Arc lists Today newest first, so build it oldest first: the last
        // row of the capture is the oldest tab.
        for (title, url) in Self.todayTopToBottom.reversed() {
            tab(title, url, .today)
        }
        return store
    }
}
