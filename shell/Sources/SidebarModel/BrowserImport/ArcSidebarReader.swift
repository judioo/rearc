import Foundation

/// Which Arc profile a space or favorites strip belongs to: Arc serializes
/// `{"default": true}` or, for another profile, a `custom` case naming its
/// Chromium directory (`directoryBasename`, DATA-SCHEMA §1.6; only `default`
/// has been seen on disk, so `custom` is read liberally).
public enum ArcProfileRef: Hashable, Sendable {
    case `default`
    case custom(directory: String)

    /// The profile's folder in Arc's `User Data`.
    public var directory: String {
        switch self {
        case .default: return "Default"
        case .custom(let directory): return directory
        }
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        if object["default"] != nil {
            self = .default
        } else if let custom = object["custom"] {
            guard let directory = Self.directoryName(in: custom) else { return nil }
            self = directory == "Default" ? .default : .custom(directory: directory)
        } else {
            return nil
        }
    }

    private static func directoryName(in value: Any) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["directoryBasename", "profile_directory_basename", "_0"] {
            if let found = object[key].flatMap(directoryName(in:)) { return found }
        }
        return object.values.lazy.compactMap(directoryName(in:)).first
    }
}

/// An Arc tab as saved in its sidebar (`data.tab.savedURL` / `savedTitle`,
/// the item `title` when renamed, `customInfo.iconType`).
public struct ArcSidebarTab: Equatable, Sendable {
    public var sourceID: String? = nil
    public var title: String
    public var url: URL
    public var customTitle: String?
    public var icon: SidebarItemIcon?
    public var isUnread: Bool
}

public indirect enum ArcSidebarNode: Equatable, Sendable {
    case tab(ArcSidebarTab)
    case folder(title: String, icon: SidebarItemIcon?, children: [ArcSidebarNode], sourceID: String? = nil)
    case split(title: String?, orientation: SplitLayoutOrientation, tabs: [ArcSidebarTab], sourceID: String? = nil)

    public var tabCount: Int {
        switch self {
        case .tab: return 1
        case .folder(_, _, let children, _): return children.reduce(0) { $0 + $1.tabCount }
        case .split(_, _, let tabs, _): return tabs.count
        }
    }

    public var folderCount: Int {
        guard case .folder(_, _, let children, _) = self else { return 0 }
        return 1 + children.reduce(0) { $0 + $1.folderCount }
    }
}

public struct ArcSidebarSpace: Identifiable, Equatable, Sendable {
    /// Arc's space id (stable across re-reads; used for the preview's choices).
    public var id: String
    public var name: String
    /// An emoji or SF Symbol name; nil when Arc shows its default glyph.
    public var icon: String?
    /// nil: Arc's built-in theme.
    public var theme: SpaceTheme?
    public var profile: ArcProfileRef
    public var pinned: [ArcSidebarNode]
    public var today: [ArcSidebarNode]

    public var pinnedTabCount: Int { pinned.reduce(0) { $0 + $1.tabCount } }
    public var todayTabCount: Int { today.reduce(0) { $0 + $1.tabCount } }
    public var folderCount: Int { pinned.reduce(0) { $0 + $1.folderCount } }
}

/// What the reader skipped because ReArc cannot hold it, by count.
public struct ArcSidebarDropped: Equatable, Sendable {
    /// Easels are references; their content is in Arc's cloud, not this file.
    public var easels = 0
    /// Tabs whose saved URL is not a web page (arc://, file:, chrome-extension:).
    public var nonWebTabs = 0
    /// Splits inside folders become their tabs (ReArc keeps splits at section level).
    public var splitsFlattened = 0
    /// Item kinds the reader does not know (live folders and the like).
    public var unknownItems = 0

    public var isEmpty: Bool { self == ArcSidebarDropped() }
}

/// Everything importable from `StorableSidebar.json`.
public struct ArcSidebarExport: Equatable, Sendable {
    public var spaces: [ArcSidebarSpace]
    public var favorites: [ArcProfileRef: [ArcSidebarTab]]
    /// Profiles in first-seen order (spaces first, then favorites).
    public var profiles: [ArcProfileRef]
    public var dropped: ArcSidebarDropped
}

/// Reads Arc's sidebar store (DATA-SCHEMA §0–1): JSON whose UUID-keyed
/// dictionaries are flat `[key, value, key, value, …]` arrays and whose
/// enums are single-key objects. Only the live `sidebar` is read; the sync
/// mirrors are consulted for the space order alone.
public enum ArcSidebarReader {
    public static let fileName = "StorableSidebar.json"

    public enum ReadError: Error, Equatable {
        case notArcSidebar
    }

    public static func read(_ url: URL) throws -> ArcSidebarExport {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> ArcSidebarExport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else {
            throw ReadError.notArcSidebar
        }
        var reader = Reader(items: pairs(main["items"]))
        let spaceModels = pairs(main["spaces"])
        var spaces: [ArcSidebarSpace] = []
        for id in spaceOrder(root: root, spaceIDs: spaceModels.keys.map { $0 }, fallback: orderedKeys(main["spaces"])) {
            guard let model = spaceModels[id] else { continue }
            spaces.append(reader.space(id: id, model: model))
        }
        var favorites: [ArcProfileRef: [ArcSidebarTab]] = [:]
        var favoriteOrder: [ArcProfileRef] = []
        let topApps = main["topAppsContainerIDs"] as? [Any] ?? []
        for index in stride(from: 0, to: topApps.count - 1, by: 2) {
            guard let profile = ArcProfileRef(json: topApps[index]), let containerID = topApps[index + 1] as? String else { continue }
            favorites[profile] = reader.nodes(under: containerID, allowFolders: false, allowSplits: false).compactMap {
                if case .tab(let tab) = $0 { return tab }
                return nil
            }
            favoriteOrder.append(profile)
        }
        var profiles: [ArcProfileRef] = []
        for profile in spaces.map(\.profile) + favoriteOrder where !profiles.contains(profile) {
            profiles.append(profile)
        }
        return ArcSidebarExport(spaces: spaces, favorites: favorites, profiles: profiles, dropped: reader.dropped)
    }

    /// A flat `[key, value, …]` dictionary keyed by string ids.
    static func pairs(_ value: Any?) -> [String: [String: Any]] {
        guard let flat = value as? [Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for index in stride(from: 0, to: flat.count - 1, by: 2) {
            if let key = flat[index] as? String, let object = flat[index + 1] as? [String: Any] { out[key] = object }
        }
        return out
    }

    static func orderedKeys(_ value: Any?) -> [String] {
        guard let flat = value as? [Any] else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).compactMap { flat[$0] as? String }
    }

    /// The sidebar has no space order of its own. The sync mirrors do
    /// (`orderedSpaceIDs`), and either can be stale: the one covering the
    /// most live spaces wins, and spaces it lacks follow in file order.
    static func spaceOrder(root: [String: Any], spaceIDs: [String], fallback: [String]) -> [String] {
        let live = Set(spaceIDs)
        let cloudKit = ((root["sidebarSyncState"] as? [String: Any])?["container"] as? [String: Any])
            .flatMap { ($0["value"] as? [String: Any])?["orderedSpaceIDs"] as? [String] } ?? []
        let firebase = (((root["firebaseSyncState"] as? [String: Any])?["syncData"] as? [String: Any])?["orderedSpaceIDs"] as? [String: Any])
            .flatMap { $0["value"] as? [String] } ?? []
        let best = [cloudKit, firebase].max { a, b in a.filter(live.contains).count < b.filter(live.contains).count } ?? []
        var order: [String] = []
        for id in best + fallback where live.contains(id) && !order.contains(id) {
            order.append(id)
        }
        return order
    }

    struct Reader {
        let items: [String: [String: Any]]
        var dropped = ArcSidebarDropped()

        init(items: [String: [String: Any]]) {
            self.items = items
        }

        mutating func space(id: String, model: [String: Any]) -> ArcSidebarSpace {
            let custom = model["customInfo"] as? [String: Any]
            var pinnedID: String?
            var unpinnedID: String?
            // The current `newContainerIDs` first, then the legacy `containerIDs`.
            for key in ["newContainerIDs", "containerIDs"] {
                let flat = model[key] as? [Any] ?? []
                for index in stride(from: 0, to: flat.count - 1, by: 2) {
                    guard let container = flat[index + 1] as? String, items[container] != nil else { continue }
                    switch ArcSidebarReader.caseName(flat[index]) {
                    case "pinned": pinnedID = pinnedID ?? container
                    case "unpinned": unpinnedID = unpinnedID ?? container
                    default: break
                    }
                }
            }
            let title = (model["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ArcSidebarSpace(
                id: id,
                name: title.isEmpty ? "Space" : title,
                icon: ArcSidebarReader.icon(custom?["iconType"]).map { icon -> String in
                    switch icon {
                    case .emoji(let emoji): return emoji
                    case .sfSymbol(let name): return name
                    }
                },
                theme: ArcSidebarReader.theme(custom?["windowTheme"]),
                profile: ArcProfileRef(json: model["profile"]) ?? .default,
                pinned: pinnedID.map { nodes(under: $0, allowFolders: true, allowSplits: true) } ?? [],
                today: unpinnedID.map { nodes(under: $0, allowFolders: false, allowSplits: true) } ?? []
            )
        }

        /// The children of `parentID` in `childrenIds` order.
        mutating func nodes(under parentID: String, allowFolders: Bool, allowSplits: Bool, depth: Int = 0) -> [ArcSidebarNode] {
            guard depth < 64, let parent = items[parentID] else { return [] }
            var out: [ArcSidebarNode] = []
            for childID in parent["childrenIds"] as? [String] ?? [] {
                guard let item = items[childID], let data = item["data"] as? [String: Any] else { continue }
                let customTitle = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let tabData = data["tab"] as? [String: Any] {
                    if let tab = tab(id: childID, item: item, data: tabData) { out.append(.tab(tab)) }
                } else if data["list"] != nil {
                    let children = nodes(under: childID, allowFolders: true, allowSplits: false, depth: depth + 1)
                    if allowFolders {
                        out.append(.folder(title: customTitle ?? "Folder", icon: nil, children: children, sourceID: childID))
                    } else {
                        out += children
                    }
                } else if let split = data["splitView"] as? [String: Any] {
                    let tabs = (item["childrenIds"] as? [String] ?? []).compactMap { id -> ArcSidebarTab? in
                        guard let child = items[id], let tabData = (child["data"] as? [String: Any])?["tab"] as? [String: Any] else { return nil }
                        return tab(id: id, item: child, data: tabData)
                    }
                    if allowSplits, (2 ... 4).contains(tabs.count) {
                        let vertical = (split["layoutOrientation"] as? String) == "vertical"
                        out.append(.split(title: customTitle, orientation: vertical ? .vertical : .horizontal, tabs: tabs, sourceID: childID))
                    } else {
                        if tabs.count > 1 { dropped.splitsFlattened += 1 }
                        out += tabs.map(ArcSidebarNode.tab)
                    }
                } else if data["easel"] != nil {
                    dropped.easels += 1
                } else {
                    dropped.unknownItems += 1
                }
            }
            return out
        }

        mutating func tab(id: String, item: [String: Any], data: [String: Any]) -> ArcSidebarTab? {
            guard let saved = data["savedURL"] as? String, let url = URL(string: saved),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else {
                dropped.nonWebTabs += 1
                return nil
            }
            let savedTitle = (data["savedTitle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rename = (item["title"] as? String).flatMap { $0.isEmpty || $0 == savedTitle ? nil : $0 }
            return ArcSidebarTab(
                sourceID: id,
                title: savedTitle.isEmpty ? (url.host() ?? saved) : savedTitle,
                url: url,
                customTitle: rename,
                icon: ArcSidebarReader.icon((data["customInfo"] as? [String: Any])?["iconType"]),
                isUnread: item["isUnread"] as? Bool ?? false
            )
        }
    }

    /// `"pinned"` or `{"pinned": {}}` / `{"unpinned": {"_0": …}}`.
    static func caseName(_ value: Any) -> String? {
        if let string = value as? String { return string }
        return (value as? [String: Any])?.keys.first
    }

    /// `{"emoji_v2": "🌿", "emoji": n}` or `{"icon": "name"}`. Arc's named
    /// icons are kept only when they are SF Symbol-shaped names.
    static func icon(_ value: Any?) -> SidebarItemIcon? {
        guard let object = value as? [String: Any] else { return nil }
        if let emoji = object["emoji_v2"] as? String, !emoji.isEmpty { return .emoji(emoji) }
        if let name = object["icon"] as? String, Space.isSymbolName(name) { return .sfSymbol(name: name) }
        return nil
    }

    /// `windowTheme.background.single._0.style.color._0`: a
    /// `blendedSingleColor` or a `blendedGradient` (two `baseColors`, the
    /// third colour as the second `overlayColors` entry), with `modifiers`
    /// for intensity, grain and texture (THEMES §2.2). The palettes Arc
    /// stores beside it are derived, and ReArc derives its own.
    static func theme(_ value: Any?) -> SpaceTheme? {
        guard let windowTheme = value as? [String: Any],
              let single = ((windowTheme["background"] as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any],
              let blend = ((single["style"] as? [String: Any])?["color"] as? [String: Any])?["_0"] as? [String: Any] else { return nil }
        var colors: [SpaceColor] = []
        var payload: [String: Any] = [:]
        if let one = (blend["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any] {
            payload = one
            colors = [color(one["color"])].compactMap { $0 }
        } else if let gradient = (blend["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any] {
            payload = gradient
            colors = (gradient["baseColors"] as? [Any] ?? []).compactMap(color)
            // The overlay's first stop is clear; a visible second one is colour 3.
            let overlay = gradient["overlayColors"] as? [Any] ?? []
            if overlay.count > 1, let third = color(overlay[1]), alpha(overlay[1]) > 0 { colors.append(third) }
        } else if let basic = (blend["basicColor"] as? [String: Any])?["_0"] {
            colors = [color(basic) ?? color((basic as? [String: Any])?["color"])].compactMap { $0 }
        }
        guard let first = colors.first else { return nil }
        let modifiers = payload["modifiers"] as? [String: Any] ?? [:]
        return SpaceTheme(
            red: first.red, green: first.green, blue: first.blue,
            gradientColors: Array(colors.dropFirst()),
            noise: number(modifiers["noiseFactor"]) ?? 0,
            appearance: .automatic,
            intensity: number(modifiers["intensityFactor"]) ?? SpaceTheme.defaultIntensity,
            texture: (modifiers["overlay"] as? String).flatMap(SpaceTexture.init(rawValue:)) ?? .grain
        )
    }

    static func color(_ value: Any?) -> SpaceColor? {
        guard let object = value as? [String: Any],
              let red = number(object["red"]), let green = number(object["green"]), let blue = number(object["blue"]) else { return nil }
        return SpaceColor(red: red, green: green, blue: blue)
    }

    static func alpha(_ value: Any?) -> Double {
        number((value as? [String: Any])?["alpha"]) ?? 1
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
    }
}
