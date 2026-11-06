import Foundation

/// The spaces in Arc's `~/Library/Application Support/Arc/StorableSidebar.json`,
/// read only. `sidebar.containers[1].spaces` alternates id strings and space
/// objects in sidebar order; `items` alternates ids and items, a space's
/// `containerIDs` alternate a kind ("pinned", "unpinned") and a container id,
/// and `topAppsContainerIDs` alternate a profile and its Favorites container.
public struct ArcSpace: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case tab
        case folder
        case other
    }

    public var id: String
    public var title: String
    /// 0-based position in the sidebar (⌃n is `index + 1` for the first nine).
    public var index: Int
    public var favorites: Int
    /// Top-level items in the pinned and unpinned containers.
    public var pinned: Int
    public var unpinned: Int
    public var defaultProfile: Bool
    /// What ⌘1… address, in order: the profile's Favorites, then the pinned
    /// and the unpinned (Today) top-level items.
    public var sidebarItems: [Item] = []

    public var items: Int { pinned + unpinned }

    /// ⌘n numbers that land on a plain tab (not a folder). ⌘9 is "the last
    /// item", so it counts only when there are at most nine.
    public var tabNumbers: [Int] {
        sidebarItems.enumerated().compactMap { offset, item in
            let number = offset + 1
            guard item == .tab, number <= 8 || (number == 9 && sidebarItems.count == 9) else { return nil }
            return number
        }
    }
}

public enum ArcSidebar {
    public static let defaultPath = "Library/Application Support/Arc/StorableSidebar.json"

    public static func spaces(from data: Data) throws -> [ArcSpace] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["spaces"] != nil }),
              let entries = main["spaces"] as? [Any] else {
            throw ParseError(description: "no sidebar.containers[].spaces")
        }
        var items: [String: [String: Any]] = [:]
        if let list = main["items"] as? [Any] {
            for case let item as [String: Any] in list {
                if let id = item["id"] as? String { items[id] = item }
            }
        }
        func children(_ id: String) -> [String] { items[id]?["childrenIds"] as? [String] ?? [] }
        func kind(_ id: String) -> ArcSpace.Item {
            guard let data = items[id]?["data"] as? [String: Any] else { return .other }
            if data["tab"] != nil { return .tab }
            if data["list"] != nil { return .folder }
            return .other
        }
        func key(_ profile: Any?) -> String {
            guard let profile, let data = try? JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var favoritesByProfile: [String: [String]] = [:]
        let topApps = main["topAppsContainerIDs"] as? [Any] ?? []
        for index in stride(from: 0, to: topApps.count - 1, by: 2) {
            if let container = topApps[index + 1] as? String { favoritesByProfile[key(topApps[index])] = children(container) }
        }
        var spaces: [ArcSpace] = []
        for case let space as [String: Any] in entries {
            guard let id = space["id"] as? String else { continue }
            var pinned: [String] = []
            var unpinned: [String] = []
            let ids = space["containerIDs"] as? [Any] ?? []
            for index in stride(from: 0, to: ids.count - 1, by: 2) {
                guard let role = ids[index] as? String, let container = ids[index + 1] as? String else { continue }
                if role == "pinned" { pinned += children(container) }
                if role == "unpinned" { unpinned += children(container) }
            }
            let favorites = favoritesByProfile[key(space["profile"])] ?? []
            let profile = space["profile"] as? [String: Any]
            spaces.append(ArcSpace(id: id, title: space["title"] as? String ?? "", index: spaces.count, favorites: favorites.count,
                                   pinned: pinned.count, unpinned: unpinned.count, defaultProfile: profile?["default"] as? Bool ?? false,
                                   sidebarItems: favorites.map { _ in .tab } + (pinned + unpinned).map(kind)))
        }
        return spaces
    }

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }
}
