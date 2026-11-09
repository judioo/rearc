import Foundation
import SQLite3

public struct ImportStats: Equatable, Sendable {
    public var spaces = 0
    public var tabs = 0
    public var bookmarks = 0
    public var pages = 0
    public var passwords = 0
    public var extensions = 0

    public init(spaces: Int = 0, tabs: Int = 0, bookmarks: Int = 0, pages: Int = 0, passwords: Int = 0, extensions: Int = 0) {
        self.spaces = spaces; self.tabs = tabs; self.bookmarks = bookmarks
        self.pages = pages; self.passwords = passwords; self.extensions = extensions
    }

    public static func + (a: ImportStats, b: ImportStats) -> ImportStats {
        ImportStats(spaces: a.spaces + b.spaces, tabs: a.tabs + b.tabs, bookmarks: a.bookmarks + b.bookmarks,
                    pages: a.pages + b.pages, passwords: a.passwords + b.passwords, extensions: a.extensions + b.extensions)
    }
}

/// A space as it arrives in Act 3: from Arc, or suggested.
public struct SpaceSeed: Equatable, Sendable {
    public var name: String
    public var icon: String
    public var colour: RGBA
    /// The profile it came from, when that is not the main one.
    public var profile: String?
    /// The host's id for a space that already exists (it was imported).
    public var hostID: String?

    public init(name: String, icon: String, colour: RGBA, profile: String? = nil, hostID: String? = nil) {
        self.name = name; self.icon = icon; self.colour = colour; self.profile = profile; self.hostID = hostID
    }
}

/// One profile in another browser that Act 2 offers to bring over.
public struct ImportSource: Equatable, Identifiable, Sendable {
    public var id: String { "\(browser)/\(directory)" }
    public var browser: String
    public var directory: String
    public var profile: String
    public var colour: RGBA
    public var stats: ImportStats
    /// Arc's spaces, with their names, icons and colours.
    public var spaces: [SpaceSeed]
    /// The extensions `stats.extensions` counts, by id, so one installed in
    /// two profiles counts once; empty when only the count is known.
    public var extensionIDs: [String]
    /// Arc's bookmarks copy its sidebar, so `stats.bookmarks` counts only
    /// the ones its spaces don't bring; this is the count when its spaces
    /// stay behind (nil: the same).
    public var bookmarksWithoutSpaces: Int?

    public init(browser: String, directory: String, profile: String, colour: RGBA, stats: ImportStats, spaces: [SpaceSeed] = [],
                extensionIDs: [String] = [], bookmarksWithoutSpaces: Int? = nil) {
        self.browser = browser; self.directory = directory; self.profile = profile; self.colour = colour; self.stats = stats
        self.spaces = spaces; self.extensionIDs = extensionIDs; self.bookmarksWithoutSpaces = bookmarksWithoutSpaces
    }

    /// What `sources` bring in `categories`: Act 2's line, and the host's
    /// rehearsal, from the same sum. Passwords never come over.
    public static func totals(_ sources: [ImportSource], categories: [ImportCategory]) -> ImportStats {
        var sum = sources.map(\.stats).reduce(ImportStats(), +)
        if !categories.contains(.spaces) {
            sum.spaces = 0; sum.tabs = 0
            sum.bookmarks = sources.reduce(0) { $0 + ($1.bookmarksWithoutSpaces ?? $1.stats.bookmarks) }
        }
        if !categories.contains(.bookmarks) { sum.bookmarks = 0 }
        if !categories.contains(.history) { sum.pages = 0 }
        sum.passwords = 0
        if categories.contains(.extensions) {
            let unknown = sources.filter(\.extensionIDs.isEmpty).reduce(0) { $0 + $1.stats.extensions }
            sum.extensions = Set(sources.flatMap(\.extensionIDs)).count + unknown
        } else {
            sum.extensions = 0
        }
        return sum
    }

    /// For previews: someone with Arc and two Chrome profiles.
    public static let demo: [ImportSource] = [
        ImportSource(browser: "Arc", directory: "Default", profile: "Personal", colour: RGBA(hex: 0xEC4F99),
                     stats: ImportStats(spaces: 6, tabs: 84, bookmarks: 0, pages: 41_208, passwords: 212, extensions: 9),
                     spaces: [SpaceSeed(name: "Home", icon: "🏠", colour: RGBA(hex: 0xFF8A65)),
                              SpaceSeed(name: "Work", icon: "💼", colour: RGBA(hex: 0x3B8AF6)),
                              SpaceSeed(name: "Reading", icon: "📚", colour: RGBA(hex: 0x5DB884)),
                              SpaceSeed(name: "Travel", icon: "✈️", colour: RGBA(hex: 0x1BA9B5)),
                              SpaceSeed(name: "Music", icon: "🎵", colour: RGBA(hex: 0x8B5CF6)),
                              SpaceSeed(name: "Health", icon: "🌿", colour: RGBA(hex: 0x7CB342))]),
        ImportSource(browser: "Arc", directory: "Profile 1", profile: "Studio", colour: RGBA(hex: 0x8B5CF6),
                     stats: ImportStats(spaces: 3, tabs: 27, bookmarks: 0, pages: 6_310, passwords: 40, extensions: 4),
                     spaces: [SpaceSeed(name: "Clients", icon: "🎨", colour: RGBA(hex: 0xEC4F99), profile: "Studio"),
                              SpaceSeed(name: "Ideas", icon: "💡", colour: RGBA(hex: 0xF5A524), profile: "Studio"),
                              SpaceSeed(name: "Archive", icon: "🗂️", colour: RGBA(hex: 0x8D99AE), profile: "Studio")]),
        ImportSource(browser: "Chrome", directory: "Default", profile: "Kai", colour: RGBA(hex: 0x3B8AF6),
                     stats: ImportStats(spaces: 0, tabs: 0, bookmarks: 1_204, pages: 38_112, passwords: 318, extensions: 14)),
        ImportSource(browser: "Brave", directory: "Default", profile: "Default", colour: RGBA(hex: 0xF5A524),
                     stats: ImportStats(spaces: 0, tabs: 0, bookmarks: 96, pages: 2_941, passwords: 12, extensions: 2)),
    ]
}

/// Finds Arc, Chrome and Brave profiles on this Mac and counts what each holds.
/// Read-only: SQLite files are counted from a private temporary copy (the
/// browser may hold them open), nothing is decrypted, and nothing leaves the
/// machine. Counting logins reads no row of them, let alone a password.
public enum BrowserScanner {
    struct Browser { let name: String; let path: String; let colour: RGBA }
    static let browsers = [
        Browser(name: "Arc", path: "Arc/User Data", colour: RGBA(hex: 0xEC4F99)),
        Browser(name: "Chrome", path: "Google/Chrome", colour: RGBA(hex: 0x3B8AF6)),
        Browser(name: "Brave", path: "BraveSoftware/Brave-Browser", colour: RGBA(hex: 0xF5A524)),
    ]

    public static func scan(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> [ImportSource] {
        var found: [ImportSource] = []
        for b in browsers {
            let root = applicationSupport.appendingPathComponent(b.path)
            guard let state = json(root.appendingPathComponent("Local State")) as? [String: Any],
                  let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
            else { continue }
            let arc = b.name == "Arc" ? arcSidebar(applicationSupport.appendingPathComponent("Arc/StorableSidebar.json")) : [:]
            for (dir, info) in cache.sorted(by: { $0.key < $1.key }) {
                let profileDir = root.appendingPathComponent(dir)
                guard FileManager.default.fileExists(atPath: profileDir.path) else { continue }
                let info = info as? [String: Any] ?? [:]
                var stats = ImportStats()
                stats.bookmarks = bookmarks(profileDir.appendingPathComponent("Bookmarks"))
                stats.pages = count(profileDir.appendingPathComponent("History"), "SELECT COUNT(*) FROM urls")
                stats.passwords = count(profileDir.appendingPathComponent("Login Data"), "SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0")
                let extensionIDs = extensions(profileDir.appendingPathComponent("Extensions"))
                stats.extensions = extensionIDs.count
                var seeds: [SpaceSeed] = []
                if let a = arc[dir] {
                    stats.spaces = a.spaces.count; stats.tabs = a.tabs
                    let name = info["name"] as? String
                    seeds = a.spaces.map { var s = $0; s.profile = dir == "Default" ? nil : name; return s }
                }
                // A profile with nothing in it is not worth asking about.
                guard stats != ImportStats() else { continue }
                let colour = (info["profile_highlight_color"] as? Int).map { RGBA(hex: UInt32(truncatingIfNeeded: $0) & 0xFFFFFF) } ?? b.colour
                found.append(ImportSource(browser: b.name, directory: dir, profile: info["name"] as? String ?? dir,
                                          colour: colour, stats: stats, spaces: seeds, extensionIDs: extensionIDs))
            }
        }
        return found
    }

    static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func bookmarks(_ url: URL) -> Int {
        guard let roots = (json(url) as? [String: Any])?["roots"] as? [String: Any] else { return 0 }
        func walk(_ node: Any) -> Int {
            guard let node = node as? [String: Any] else { return 0 }
            if node["type"] as? String == "url" { return 1 }
            return (node["children"] as? [Any] ?? []).reduce(0) { $0 + walk($1) }
        }
        return roots.values.reduce(0) { $0 + walk($1) }
    }

    /// One number from a copy of `url` (and its journal) in a private
    /// temporary folder: the browser's own file is never opened, so nothing
    /// locks it and a write in progress cannot be half-read.
    static func count(_ url: URL, _ sql: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let folder = fm.temporaryDirectory.appendingPathComponent("ReArcScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
        } catch { return 0 }
        for suffix in ["-wal", "-journal"] where fm.fileExists(atPath: url.path + suffix) {
            try? fm.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Extension folders, by id (32 letters a–p).
    static func extensions(_ url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.count == 32 && $0.allSatisfy { ("a" ... "p").contains($0) } }.sorted()
    }

    /// Arc keeps spaces and tabs in its sidebar file, each space tagged with
    /// the profile directory it belongs to.
    static func arcSidebar(_ url: URL) -> [String: (spaces: [SpaceSeed], tabs: Int)] {
        guard let root = json(url) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil })
        else { return [:] }
        var result: [String: (spaces: [SpaceSeed], tabs: Int)] = [:]
        var spaceOfContainer: [String: String] = [:]
        for case let space as [String: Any] in main["spaces"] as? [Any] ?? [] {
            let profile = space["profile"] as? [String: Any]
            let custom = (profile?["custom"] as? [String: Any])?["_0"] as? [String: Any]
            let dir = custom?["directoryBasename"] as? String ?? "Default"
            let info = space["customInfo"] as? [String: Any]
            let icon = (info?["iconType"] as? [String: Any])?["emoji_v2"] as? String
            let tone = ((info?["windowTheme"] as? [String: Any])?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any]
            let colour = tone.flatMap { t -> RGBA? in
                guard let r = t["red"] as? Double, let g = t["green"] as? Double, let b = t["blue"] as? Double else { return nil }
                return RGBA(r, g, b)
            }
            let index = result[dir]?.spaces.count ?? 0
            result[dir, default: ([], 0)].spaces.append(SpaceSeed(
                name: space["title"] as? String ?? "Space \(index + 1)",
                icon: icon ?? Act3Timeline.icons[index % Act3Timeline.icons.count],
                colour: colour ?? ProfilePalette.colours[index % ProfilePalette.colours.count].rgba))
            for case let id as String in space["containerIDs"] as? [Any] ?? [] { spaceOfContainer[id] = dir }
        }
        // Tabs: items holding a tab, credited to the space whose container they sit under.
        var items: [String: [String: Any]] = [:]
        for case let item as [String: Any] in main["items"] as? [Any] ?? [] {
            if let id = item["id"] as? String { items[id] = item }
        }
        func profile(of id: String, depth: Int = 0) -> String? {
            if let dir = spaceOfContainer[id] { return dir }
            guard depth < 32, let parent = items[id]?["parentID"] as? String else { return nil }
            return profile(of: parent, depth: depth + 1)
        }
        for (id, item) in items where (item["data"] as? [String: Any])?["tab"] != nil {
            if let dir = profile(of: id) { result[dir, default: ([], 0)].tabs += 1 }
        }
        return result
    }
}
