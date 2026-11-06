import Foundation
import SQLite3
@testable import SidebarModel

/// A made-up `~/Library/Application Support` holding Arc, Chrome and Brave
/// data in their real layouts. Every name, URL and title is invented.
struct BrowserImportFixture {
    let root: URL

    static let work = "11111111-1111-1111-1111-111111111111"
    static let side = "22222222-2222-2222-2222-222222222222"
    static let plain = "33333333-3333-3333-3333-333333333333"
    static let webStoreID = "abcdefghijklmnopabcdefghijklmnop"
    static let disabledID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let unpackedID = "cccccccccccccccccccccccccccccccc"
    static let componentID = "dddddddddddddddddddddddddddddddd"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReArcImportFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ object: Any, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    // MARK: Arc

    static func color(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> [String: Any] {
        ["red": red, "green": green, "blue": blue, "alpha": alpha, "colorSpace": "extendedSRGB"]
    }

    static func windowTheme(_ blend: [String: Any]) -> [String: Any] {
        ["background": ["single": ["_0": [
            "isVibrant": true, "contentOverBackgroundAppearance": "light",
            "style": ["color": ["_0": blend]],
        ]]]]
    }

    static func item(_ id: String, parent: String?, children: [String] = [], title: String? = nil, data: [String: Any],
                     unread: Bool = false) -> [String: Any] {
        var item: [String: Any] = ["id": id, "childrenIds": children, "createdAt": 700_000_000.0,
                                   "originatingDevice": "fixture", "data": data]
        item["parentID"] = parent ?? NSNull()
        if let title { item["title"] = title }
        if unread { item["isUnread"] = true }
        return item
    }

    static func tab(_ id: String, parent: String, url: String, title: String, rename: String? = nil,
                    icon: [String: Any]? = nil, unread: Bool = false) -> [String: Any] {
        var tab: [String: Any] = ["savedURL": url, "savedTitle": title, "savedMuteStatus": "allowAudio", "timeLastActiveAt": 700_000_100.0]
        if let icon { tab["customInfo"] = ["iconType": icon] }
        return item(id, parent: parent, title: rename, data: ["tab": tab], unread: unread)
    }

    static func container(_ id: String, children: [String], space: String?) -> [String: Any] {
        let type: [String: Any] = space.map { ["spaceItems": ["_0": $0]] } ?? ["topApps": ["_0": ["default": true]]]
        return item(id, parent: nil, children: children, data: ["itemContainer": ["containerType": type]])
    }

    /// Three spaces (Work and Plain in Arc's default profile, Side in
    /// "Profile 1"), favorites for both profiles, and one of each item kind.
    static func arcSidebar() -> [String: Any] {
        let items: [[String: Any]] = [
            container("P-WORK", children: ["T-A", "F-1", "SPLIT", "EASEL", "T-ARC"], space: work),
            tab("T-A", parent: "P-WORK", url: "https://docs.example.com/start", title: "Start Here", rename: "Handbook",
                icon: ["emoji": 1, "emoji_v2": "📘"], unread: true),
            item("F-1", parent: "P-WORK", children: ["T-B", "F-2"], title: "Projects", data: ["list": [:]]),
            tab("T-B", parent: "F-1", url: "https://tracker.example.org/board", title: "Board"),
            item("F-2", parent: "F-1", children: ["T-C"], title: "Archive", data: ["list": [:]]),
            tab("T-C", parent: "F-2", url: "https://wiki.example.net/old", title: "Old Notes"),
            item("SPLIT", parent: "P-WORK", children: ["T-D", "T-E"], data: ["splitView": [
                "layoutOrientation": "horizontal", "focusItemID": "T-D", "itemWidthFactors": ["T-D", 0.5, "T-E", 0.5],
                "timeLastActiveAt": 700_000_200.0, "customInfo": NSNull(),
            ]]),
            tab("T-D", parent: "SPLIT", url: "https://mail.example.com/", title: "Mail"),
            tab("T-E", parent: "SPLIT", url: "https://calendar.example.com/", title: "Calendar"),
            item("EASEL", parent: "P-WORK", data: ["easel": ["easelID": "E", "creatorID": "x", "title": "Sketch",
                                                              "shareStatus": "readOnly", "timeLastActiveAt": 700_000_000.0]]),
            tab("T-ARC", parent: "P-WORK", url: "arc://settings", title: "Settings"),
            container("U-WORK", children: ["T-TODAY"], space: work),
            tab("T-TODAY", parent: "U-WORK", url: "https://news.example.com/today", title: "Morning Read"),
            container("P-SIDE", children: ["T-G"], space: side),
            tab("T-G", parent: "P-SIDE", url: "https://garden.example.com/", title: "Garden Log"),
            container("U-SIDE", children: [], space: side),
            container("P-PLAIN", children: [], space: plain),
            container("U-PLAIN", children: [], space: plain),
            container("TOP-DEFAULT", children: ["FAV-1", "FAV-2"], space: nil),
            tab("FAV-1", parent: "TOP-DEFAULT", url: "https://chat.example.com/", title: "Chat"),
            tab("FAV-2", parent: "TOP-DEFAULT", url: "https://music.example.com/", title: "Music"),
            container("TOP-SIDE", children: ["FAV-3"], space: nil),
            tab("FAV-3", parent: "TOP-SIDE", url: "https://recipes.example.com/", title: "Recipes"),
        ]
        func space(_ id: String, title: String, pinned: String, unpinned: String, profile: Any, custom: [String: Any]) -> [String: Any] {
            ["id": id, "title": title, "profile": profile,
             "containerIDs": ["unpinned", unpinned, "pinned", pinned],
             "newContainerIDs": [["unpinned": ["_0": ["shared": [:]]]], unpinned, ["pinned": [:]], pinned],
             "customInfo": custom]
        }
        let sideProfile: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
        let spaces: [Any] = [
            work, space(work, title: "Work", pinned: "P-WORK", unpinned: "U-WORK", profile: ["default": true], custom: [
                "iconType": ["emoji": 3, "emoji_v2": "🧪"],
                "windowTheme": windowTheme(["blendedGradient": ["_0": [
                    "baseColors": [color(0.4, 0.7, 0.85), color(0.5, 0.5, 0.86)],
                    "overlayColors": [color(0, 0, 0, alpha: 0), color(0.36, 0.85, 0.72)],
                    "wheel": ["analogous": [:]], "translucencyStyle": "light",
                    "modifiers": ["intensityFactor": 0.7, "noiseFactor": 0.25, "overlay": "sand"],
                ]]]),
            ]),
            side, space(side, title: "Side", pinned: "P-SIDE", unpinned: "U-SIDE", profile: sideProfile, custom: [
                "iconType": ["icon": "star.fill"],
                "windowTheme": windowTheme(["blendedSingleColor": ["_0": [
                    "color": color(0.95, 0.92, 0.89), "translucencyStyle": "light",
                    "modifiers": ["intensityFactor": 0.8, "noiseFactor": 0, "overlay": "grain"],
                ]]]),
            ]),
            plain, space(plain, title: "Plain", pinned: "P-PLAIN", unpinned: "U-PLAIN", profile: ["default": true], custom: [:]),
        ]
        let flatItems: [Any] = items.flatMap { [$0["id"]!, $0] }
        return [
            "version": 1,
            "sidebar": ["containers": [
                ["global": [:]],
                ["items": flatItems, "spaces": spaces,
                 "topAppsContainerIDs": [["default": true], "TOP-DEFAULT", sideProfile, "TOP-SIDE"]],
            ]],
            // CloudKit's order is stale; Firebase's covers more spaces.
            "sidebarSyncState": ["container": ["value": ["orderedSpaceIDs": [work], "version": 6]]],
            "firebaseSyncState": ["syncData": ["orderedSpaceIDs": ["value": [side, work, "44444444-0000-0000-0000-000000000000"]]]],
        ]
    }

    // MARK: Chromium profiles

    static func localState(_ profiles: [(String, String)]) -> [String: Any] {
        ["profile": [
            "info_cache": Dictionary(uniqueKeysWithValues: profiles.map { ($0.0, ["name": $0.1, "avatar_icon": "x"] as [String: Any]) }),
            "profiles_order": profiles.map(\.0),
        ]]
    }

    static let bookmarks: [String: Any] = [
        "version": 1, "checksum": "0",
        "roots": [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [
                ["type": "url", "name": "Reading List", "url": "https://read.example.com/"],
                ["type": "folder", "name": "Tools", "children": [
                    ["type": "url", "name": "Converter", "url": "https://convert.example.org/"],
                    ["type": "url", "name": "Local", "url": "file:///tmp/x.html"],
                ]],
                ["type": "folder", "name": "Empty", "children": []],
            ]],
            "other": ["type": "folder", "name": "Other bookmarks", "children": [
                ["type": "url", "name": "", "url": "https://untitled.example.net/page"],
            ]],
            "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
        ],
    ]

    static func preferences(pinned: [String] = []) -> [String: Any] {
        [
            "extensions": ["pinned_extensions": pinned, "theme": ["id": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]],
            "default_search_provider_data": ["template_url_data": [
                "short_name": "DuckDuckGo", "keyword": "duckduckgo.com", "url": "https://duckduckgo.com/?q={searchTerms}",
            ]],
            "session": ["restore_on_startup": 4, "startup_urls": ["https://start.example.com/", "https://second.example.com/"]],
        ]
    }

    func securePreferences(unpackedPath: String) -> [String: Any] {
        ["extensions": ["settings": [
            Self.webStoreID: ["location": 1, "from_webstore": true, "path": "\(Self.webStoreID)/1.2.0_0",
                              "manifest": ["name": "__MSG_appName__", "version": "1.2.0", "default_locale": "en"]],
            Self.disabledID: ["location": 1, "from_webstore": false, "disable_reasons": [1], "path": "\(Self.disabledID)/3.0_0",
                              "manifest": ["name": "Quiet Mode", "version": "3.0",
                                           "update_url": ExtensionInventoryReader.webStoreUpdateURL]],
            Self.unpackedID: ["location": 4, "from_webstore": false, "path": unpackedPath,
                              "manifest": ["name": "My Dev Tool", "version": "0.1"]],
            Self.componentID: ["location": 5, "from_webstore": false, "path": "/component",
                               "manifest": ["name": "Built In", "version": "1"]],
            // A leftover entry without a manifest (an uninstalled extension).
            "ffffffffffffffffffffffffffffffff": ["preferences": [:]],
        ]]]
    }

    /// History with three visible pages and one hidden.
    static func writeHistory(to url: URL, now: Date) throws {
        try sqlite(url, [
            "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)",
            "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('https://read.example.com/', 'Reading List', 12, \(ChromiumHistoryReader.chromiumTime(now.addingTimeInterval(-60))), 0)",
            "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('https://weather.example.org/today', 'Weather', 3, \(ChromiumHistoryReader.chromiumTime(now.addingTimeInterval(-3600))), 0)",
            "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('chrome://settings/', 'Settings', 2, \(ChromiumHistoryReader.chromiumTime(now)), 0)",
            "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES ('https://frame.example.com/ad', 'Frame', 1, \(ChromiumHistoryReader.chromiumTime(now)), 1)",
        ])
    }

    static func sqlite(_ url: URL, _ statements: [String], bind blob: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        for sql in statements {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            if let blob, sqlite3_bind_parameter_count(statement) > 0 {
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), nil) }
            }
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Arc (sidebar, Default and Profile 1) and Chrome (two named profiles).
    /// Brave is absent.
    func installBrowsers(now: Date = Date()) throws {
        try write(Self.arcSidebar(), to: "Arc/StorableSidebar.json")
        try write(Self.localState([("Default", "Home"), ("Profile 1", "Studio")]), to: "Arc/User Data/Local State")
        try write([:] as [String: Any], to: "Arc/User Data/Default/Preferences")
        try write([:] as [String: Any], to: "Arc/User Data/Profile 1/Preferences")

        try write(Self.localState([("Profile 2", "Weekend"), ("Default", "Everyday")]), to: "Google/Chrome/Local State")
        let unpacked = try folder("Developer/my-dev-tool")
        for directory in ["Default", "Profile 2"] {
            try write(Self.preferences(pinned: [Self.webStoreID]), to: "Google/Chrome/\(directory)/Preferences")
            try write(securePreferences(unpackedPath: unpacked.path), to: "Google/Chrome/\(directory)/Secure Preferences")
        }
        try write(Self.bookmarks, to: "Google/Chrome/Default/Bookmarks")
        try Self.writeHistory(to: root.appendingPathComponent("Google/Chrome/Default/History"), now: now)
        try write(["appName": ["message": "Tab Notes"]], to: "Google/Chrome/Default/Extensions/\(Self.webStoreID)/1.2.0_0/_locales/en/messages.json")
        // A folder that is not a profile, and one without Preferences.
        _ = try folder("Google/Chrome/Crashpad")
        _ = try folder("Google/Chrome/Profile 9")
    }
}
