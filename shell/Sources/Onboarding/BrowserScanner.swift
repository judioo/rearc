import Foundation
import SQLite3
import SidebarModel

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
    /// The browser's name as Act 2 shows it ("Chrome").
    public var browser: String
    /// `ImportBrowser`'s raw value ("chrome", "edgeBeta").
    public var browserID: String
    public var directory: String
    public var profile: String
    public var colour: RGBA
    public var stats: ImportStats
    /// Arc's spaces, with their names, icons and colours.
    public var spaces: [SpaceSeed]
    /// The extensions `stats.extensions` counts, by id, so one installed in
    /// two profiles counts once; empty when only the count is known.
    public var extensionIDs: [String]
    /// Origins consented to at discovery, keyed by the counted IDs. The host
    /// intersects this snapshot with a fresh inventory before queuing work.
    public var extensionOrigins: [String: SourceExtension.Origin] = [:]
    /// Arc's bookmarks copy its sidebar, so `stats.bookmarks` counts only
    /// the ones its spaces don't bring; this is the count when its spaces
    /// stay behind (nil: the same).
    public var bookmarksWithoutSpaces: Int?

    public init(browser: String, directory: String, profile: String, colour: RGBA, stats: ImportStats, spaces: [SpaceSeed] = [],
                extensionIDs: [String] = [], bookmarksWithoutSpaces: Int? = nil) {
        self.browser = browser; self.directory = directory; self.profile = profile; self.colour = colour; self.stats = stats
        self.spaces = spaces; self.extensionIDs = extensionIDs; self.bookmarksWithoutSpaces = bookmarksWithoutSpaces
        browserID = ImportBrowser.allCases.first { $0.shortName == browser }?.rawValue ?? browser.lowercased()
    }

    public var importBrowser: ImportBrowser? { ImportBrowser(rawValue: browserID) }

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

/// A browser Act 2 shows on the trail but cannot bring over (yet).
public struct PendingBrowser: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        /// macOS keeps its data private until ReArc is allowed in System Settings.
        case needsPermission(ImportPermission)
        /// Installed, with nothing in it to bring.
        case noData
    }

    public var browser: ImportBrowser
    public var state: State
    public var colour: RGBA

    public var id: String { browser.rawValue }
    public var name: String { browser.shortName }
    public var needsPermission: Bool { if case .needsPermission = state { true } else { false } }

    public init(browser: ImportBrowser, state: State, colour: RGBA? = nil) {
        self.browser = browser; self.state = state; self.colour = colour ?? BrowserScanner.colour(of: browser)
    }
}

/// What Act 2 finds: profiles to bring, and the browsers it can only name.
public struct BrowserScan: Equatable, Sendable {
    public var sources: [ImportSource]
    public var pending: [PendingBrowser]

    public init(sources: [ImportSource] = [], pending: [PendingBrowser] = []) {
        self.sources = sources; self.pending = pending
    }

    /// Act 2's trail holds at most this many nodes; browsers with nothing in them go first.
    public static let maxNodes = 8

    /// Blocked browsers as discovery reports them, for `ImportAccessWatch`.
    public var discovered: [DiscoveredBrowser] {
        var out: [DiscoveredBrowser] = []
        for source in sources {
            if let browser = source.importBrowser, !out.contains(where: { $0.browser == browser }) {
                out.append(DiscoveredBrowser(browser: browser, status: .available))
            }
        }
        for item in pending {
            switch item.state {
            case .needsPermission(let permission): out.append(DiscoveredBrowser(browser: item.browser, status: .blocked(permission)))
            case .noData: out.append(DiscoveredBrowser(browser: item.browser, status: .noProfiles))
            }
        }
        return out
    }

    /// Keeps the trail to `maxNodes`: drops browsers without data first.
    public func trimmed() -> BrowserScan {
        var copy = self
        while copy.sources.count + copy.pending.count > Self.maxNodes, let i = copy.pending.lastIndex(where: { $0.state == .noData }) {
            copy.pending.remove(at: i)
        }
        return copy
    }
}

/// Finds every browser's profiles on this Mac and counts what each holds,
/// and names the browsers it cannot read: blocked by macOS privacy, or
/// installed with nothing in them. Read-only: SQLite files are counted from
/// a private temporary copy (the browser may hold them open), nothing is
/// decrypted, and nothing leaves the machine. Login Data is checked for
/// existence only; it is never copied or opened.
public enum BrowserScanner {
    static func colour(of browser: ImportBrowser) -> RGBA {
        switch browser {
        case .arc: return RGBA(hex: 0xEC4F99)
        case .chrome, .chromeBeta, .chromeDev, .chromeCanary: return RGBA(hex: 0x3B8AF6)
        case .brave, .braveBeta, .braveNightly: return RGBA(hex: 0xF5A524)
        case .edge, .edgeBeta, .edgeDev, .edgeCanary: return RGBA(hex: 0x1BA9B5)
        case .vivaldi, .vivaldiSnapshot: return RGBA(hex: 0xE5484D)
        case .opera, .operaGX: return RGBA(hex: 0xD6336C)
        case .chromium: return RGBA(hex: 0x5B8DEF)
        case .safari: return RGBA(hex: 0x2F9BF0)
        case .firefox: return RGBA(hex: 0xF97316)
        }
    }

    public static func scan(applicationSupport: URL = BrowserImportDiscovery.applicationSupport) -> [ImportSource] {
        survey(applicationSupport: applicationSupport).sources
    }

    /// Every browser: its profiles with something in them, or why not.
    public static func survey(applicationSupport: URL = BrowserImportDiscovery.applicationSupport,
                              installed: (ImportBrowser) -> Bool = { $0.isInstalledAtStandardLocation },
                              probe: ImportAccessProbe = ImportAccessProbes.system) -> BrowserScan {
        var scan = BrowserScan()
        for found in BrowserImportDiscovery.discover(in: applicationSupport, installed: installed, probe: probe) {
            switch found.status {
            case .blocked(let permission):
                scan.pending.append(PendingBrowser(browser: found.browser, state: .needsPermission(permission)))
                continue
            case .noProfiles:
                scan.pending.append(PendingBrowser(browser: found.browser, state: .noData))
                continue
            case .available:
                break
            }
            let sources = self.sources(found, applicationSupport: applicationSupport)
            if sources.isEmpty {
                scan.pending.append(PendingBrowser(browser: found.browser, state: .noData))
            }
            scan.sources += sources
        }
        return scan
    }

    static func sources(_ found: DiscoveredBrowser, applicationSupport: URL) -> [ImportSource] {
        let b = found.browser
        let state = b.family == .chromium
            ? json(b.dataFolder(in: applicationSupport).appendingPathComponent("Local State")) as? [String: Any] : nil
        let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        let arc = b == .arc ? arcSidebar(applicationSupport.appendingPathComponent("Arc/StorableSidebar.json")) : [:]
        var out: [ImportSource] = []
        for profile in found.profiles.sorted(by: { b.family == .chromium ? $0.directory < $1.directory : false }) {
            let dir = profile.directory
            let info = cache[dir] as? [String: Any] ?? [:]
            var stats = ImportStats()
            var extensionItems: [SourceExtension] = []
            if b.family == .chromium {
                stats.bookmarks = bookmarks(profile.url.appendingPathComponent("Bookmarks"))
                stats.pages = count(profile.url.appendingPathComponent("History"))
                // Presence only, for the "passwords stay behind" message; never a login count.
                stats.passwords = FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("Login Data").path) ? 1 : 0
                extensionItems = ExtensionConsolidation(ExtensionInventoryReader.read(profile: profile.url)).candidates
                stats.extensions = extensionItems.count
            } else {
                let inventory = BrowserImportDiscovery.inventory(of: profile)
                stats.bookmarks = inventory.bookmarks
                stats.pages = inventory.historyPages ?? 0
                stats.passwords = inventory.hasPasswords ? 1 : 0
            }
            var seeds: [SpaceSeed] = []
            if let a = arc[dir] {
                stats.spaces = a.spaces.count; stats.tabs = a.tabs
                let name = info["name"] as? String
                seeds = a.spaces.map { var s = $0; s.profile = dir == "Default" ? nil : name; return s }
            }
            // A profile with nothing in it is not worth asking about.
            guard stats != ImportStats() else { continue }
            let colour = (info["profile_highlight_color"] as? Int).map { RGBA(hex: UInt32(truncatingIfNeeded: $0) & 0xFFFFFF) } ?? colour(of: b)
            var source = ImportSource(browser: b.shortName, directory: dir, profile: info["name"] as? String ?? profile.name,
                                      colour: colour, stats: stats, spaces: seeds, extensionIDs: extensionItems.map(\.id))
            source.browserID = b.rawValue
            source.extensionOrigins = Dictionary(extensionItems.map { ($0.id, $0.origin) }, uniquingKeysWith: { first, _ in first })
            out.append(source)
        }
        return out
    }

    /// Never through a link, size-capped and depth-checked (RC-0.1.0-602 T-08).
    static func json(_ url: URL) -> Any? {
        try? ImportFile.json(url)
    }

    static func bookmarks(_ url: URL) -> Int {
        guard let roots = (json(url) as? [String: Any])?["roots"] as? [String: Any] else { return 0 }
        func walk(_ node: Any, depth: Int) -> Int {
            guard depth < ImportFile.maxFolderWalkDepth, let node = node as? [String: Any] else { return 0 }
            if node["type"] as? String == "url" { return 1 }
            return (node["children"] as? [Any] ?? []).reduce(0) { $0 + walk($1, depth: depth + 1) }
        }
        return roots.values.reduce(0) { $0 + walk($1, depth: 0) }
    }

    /// One number from a copy of `url` (and its journal) in a private
    /// temporary folder: the browser's own file is never opened, so nothing
    /// locks it and a write in progress cannot be half-read. The copy is
    /// `SQLiteSnapshot`'s, which refuses links (RC-0.1.0-602 T-08).
    static func count(_ url: URL) -> Int {
        guard url.lastPathComponent == "History", let snapshot = try? SQLiteSnapshot(copying: url) else { return 0 }
        defer { snapshot.remove() }
        guard let db = ImportFile.openDatabase(snapshot.url) else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM urls", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
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
