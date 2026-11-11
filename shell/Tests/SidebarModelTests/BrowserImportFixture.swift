import Foundation
import SQLite3
@testable import SidebarModel

/// A made-up `~/Library/Application Support` holding Arc, Chrome and Brave
/// data in their real layouts. Every name, URL and title is invented.
struct BrowserImportFixture {
    /// `<home>/Library/Application Support`.
    let root: URL
    /// The fixture's home folder; Safari's data is in `Library/Safari` under it.
    let home: URL

    static let work = "11111111-1111-1111-1111-111111111111"
    static let side = "22222222-2222-2222-2222-222222222222"
    static let plain = "33333333-3333-3333-3333-333333333333"
    static let webStoreID = "abcdefghijklmnopabcdefghijklmnop"
    static let disabledID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let unpackedID = "cccccccccccccccccccccccccccccccc"
    static let componentID = "dddddddddddddddddddddddddddddddd"

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ReArcImportFixture-\(UUID().uuidString)", isDirectory: true)
        root = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
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

    // MARK: Safari and Firefox

    /// `~/Library/Safari`: a Favorites bar with a folder, a Bookmarks menu,
    /// the Reading List, and the History proxy, which is not a list.
    static let safariBookmarks: [String: Any] = [
        "WebBookmarkType": "WebBookmarkTypeList", "Title": "",
        "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                leaf("https://bar.example.com/", "Bar Link"),
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Recipes", "Children": [
                    leaf("https://soup.example.org/", "Soup"),
                    leaf("javascript:alert(1)", "Bookmarklet"),
                ]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": [
                leaf("https://menu.example.net/", ""),
                leaf("https://user:secret@private.example.com/", "Signed In"),
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                leaf("https://long.example.com/essay", "An Essay", readingList: true),
            ]],
        ],
    ]

    static func leaf(_ url: String, _ title: String, readingList: Bool = false) -> [String: Any] {
        var leaf: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title]]
        if readingList { leaf["ReadingList"] = ["PreviewText": "Invented."] }
        return leaf
    }

    var safari: URL { home.appendingPathComponent("Library/Safari", isDirectory: true) }

    /// Safari's history: two pages, the first visited twice (renamed since), and a file URL.
    static func writeSafariHistory(to url: URL, now: Date) throws {
        let t = now.timeIntervalSinceReferenceDate
        try sqlite(url, [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL, visit_count INTEGER NOT NULL)",
            "CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL, load_successful BOOLEAN NOT NULL DEFAULT 1)",
            "INSERT INTO history_items(url, visit_count) VALUES ('https://news.example.com/', 2)",
            "INSERT INTO history_items(url, visit_count) VALUES ('https://maps.example.org/route', 1)",
            "INSERT INTO history_items(url, visit_count) VALUES ('file:///Users/x/notes.html', 1)",
            "INSERT INTO history_visits(history_item, visit_time, title) VALUES (1, \(t - 7200), 'Old Title')",
            "INSERT INTO history_visits(history_item, visit_time, title) VALUES (1, \(t - 60), 'Front Page')",
            "INSERT INTO history_visits(history_item, visit_time, title) VALUES (2, \(t - 3600), 'Route')",
            "INSERT INTO history_visits(history_item, visit_time, title) VALUES (3, \(t), 'Notes')",
        ])
    }

    func installSafari(now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: Self.safariBookmarks, format: .binary, options: 0)
            .write(to: safari.appendingPathComponent("Bookmarks.plist"))
        try Self.writeSafariHistory(to: safari.appendingPathComponent("History.db"), now: now)
    }

    static let profilesINI = """
        [Profile1]
        Name=old
        IsRelative=1
        Path=Profiles/bbbb.old

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/aaaa.default-release

        [Profile2]
        Name=gone
        IsRelative=1
        Path=Profiles/cccc.gone

        [General]
        StartWithLastProfile=1
        Version=2

        [Install4F96D1932A9F858E]
        Default=Profiles/aaaa.default-release
        Locked=1
        """

    /// Firefox's places: a toolbar link and folder, a menu link, an unfiled
    /// link, a tag (not a bookmark) and history with a hidden page.
    static func writePlaces(to url: URL, now: Date) throws {
        let us = { (d: Date) in Int64(d.timeIntervalSince1970 * 1_000_000) }
        try sqlite(url, [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER, guid TEXT)",
            "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT)",
            "CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER, visit_date INTEGER, visit_type INTEGER)",
            "INSERT INTO moz_places VALUES (1, 'https://fox.example.com/', 'Fox Home', 5, 0, \(us(now.addingTimeInterval(-60))), 'p1')",
            "INSERT INTO moz_places VALUES (2, 'https://docs.example.org/guide', 'Guide', 1, 0, \(us(now.addingTimeInterval(-3600))), 'p2')",
            "INSERT INTO moz_places VALUES (3, 'https://menu.example.net/', 'Menu Link', 0, 0, NULL, 'p3')",
            "INSERT INTO moz_places VALUES (4, 'https://frame.example.com/ad', 'Frame', 1, 1, \(us(now)), 'p4')",
            "INSERT INTO moz_places VALUES (5, 'place:sort=8&maxResults=10', 'Most Visited', 0, 0, NULL, 'p5')",
            "INSERT INTO moz_historyvisits VALUES (1, 0, 1, \(us(now.addingTimeInterval(-86400))), 1)",
            "INSERT INTO moz_historyvisits VALUES (2, 0, 1, \(us(now.addingTimeInterval(-60))), 1)",
            "INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________')",
            "INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'menu', 'menu________')",
            "INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____')",
            "INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 2, 'tags', 'tags________')",
            "INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____')",
            "INSERT INTO moz_bookmarks VALUES (6, 2, NULL, 1, 4, 'mobile', 'mobile______')",
            "INSERT INTO moz_bookmarks VALUES (10, 1, 1, 3, 0, 'Fox', 'b10')",
            "INSERT INTO moz_bookmarks VALUES (11, 2, NULL, 3, 1, 'Work', 'b11')",
            "INSERT INTO moz_bookmarks VALUES (12, 1, 2, 11, 0, 'The Guide', 'b12')",
            "INSERT INTO moz_bookmarks VALUES (13, 1, 5, 3, 2, 'Most Visited', 'b13')",
            "INSERT INTO moz_bookmarks VALUES (14, 3, NULL, 3, 3, '', 'b14')",
            "INSERT INTO moz_bookmarks VALUES (20, 1, 3, 2, 0, 'Menu Link', 'b20')",
            "INSERT INTO moz_bookmarks VALUES (30, 2, NULL, 4, 0, 'a-tag', 'b30')",
            "INSERT INTO moz_bookmarks VALUES (31, 1, 2, 30, 0, '', 'b31')",
            "INSERT INTO moz_bookmarks VALUES (40, 1, 1, 5, 0, 'Unsorted Fox', 'b40')",
        ])
    }

    func installFirefox(now: Date = Date()) throws {
        let firefox = try folder("Firefox")
        try Self.profilesINI.write(to: firefox.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        try Self.writePlaces(to: firefox.appendingPathComponent("Profiles/aaaa.default-release/places.sqlite"), now: now)
        try Self.writePlaces(to: firefox.appendingPathComponent("Profiles/bbbb.old/places.sqlite"), now: now)
        // Profile2's folder is gone.
    }
}
