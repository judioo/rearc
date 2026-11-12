import Foundation

/// One Air Traffic Control rule (Arc `LinkRouting`: `LinkRoutingURLMatchType`,
/// `LinkRoutingWindowType`, `StorableLinkRoutingState`; MEDIA §3.4): links
/// from other apps that match go to a space, or to a Little Arc in a profile.
public struct LinkRoutingRule: Codable, Identifiable, Equatable, Sendable {
    public enum MatchType: String, Codable, CaseIterable, Sendable {
        /// The host or any subdomain of it ("github.com" matches gist.github.com).
        case domain
        /// The URL contains the text (case-insensitive).
        case contains
        /// A pattern with `*` wildcards over the URL without its scheme
        /// ("*.atlassian.net/*", "github.com/rearc/*").
        case pattern

        public var title: String {
            switch self {
            case .domain: return "Domain is"
            case .contains: return "URL contains"
            case .pattern: return "URL matches"
            }
        }

        public var placeholder: String {
            switch self {
            case .domain: return "github.com"
            case .contains: return "meet.google"
            case .pattern: return "*.atlassian.net/*"
            }
        }
    }

    public enum Destination: Codable, Equatable, Hashable, Sendable {
        /// A new tab in that space (and its profile).
        case space(Space.ID)
        /// A Little Arc window using that profile.
        case littleArc(Profile.ID)
    }

    public var id: UUID
    public var matchType: MatchType
    public var pattern: String
    public var destination: Destination
    public var isEnabled: Bool

    public init(id: UUID = UUID(), matchType: MatchType = .domain, pattern: String = "", destination: Destination, isEnabled: Bool = true) {
        self.id = id
        self.matchType = matchType
        self.pattern = pattern
        self.destination = destination
        self.isEnabled = isEnabled
    }

    /// The pattern as matched: trimmed and lowercased; a domain loses any
    /// scheme, "www.", path and port the user pasted with it.
    public var normalizedPattern: String {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard matchType != .contains else { return text }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        guard matchType == .domain else { return text }
        if let cut = text.firstIndex(where: { "/?#:".contains($0) }) { text = String(text[..<cut]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        return text
    }

    /// An empty or malformed pattern matches nothing.
    public var isValid: Bool {
        let text = normalizedPattern
        guard !text.isEmpty else { return false }
        switch matchType {
        case .domain: return !text.contains(" ") && !text.contains("*")
        case .contains: return true
        case .pattern: return text.contains(where: { $0 != "*" })
        }
    }

    public func matches(_ url: URL) -> Bool {
        guard isEnabled, isValid else { return false }
        let needle = normalizedPattern
        switch matchType {
        case .domain:
            guard let host = url.host()?.lowercased() else { return false }
            return host == needle || host.hasSuffix("." + needle)
        case .contains:
            return url.absoluteString.lowercased().contains(needle)
        case .pattern:
            return Self.glob(needle, matches: Self.schemeless(url))
        }
    }

    /// The URL as patterns see it: "host/path?query", lowercased.
    static func schemeless(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        return text
    }

    /// `*` matches any run of characters; everything else literally; the
    /// whole text must match.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == text }
        guard text.hasPrefix(parts[0]) else { return false }
        var rest = text.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        let last = parts[parts.count - 1]
        return last.isEmpty || (rest.hasSuffix(last) && rest.count >= last.count)
    }
}

/// The ordered rules; the first enabled match wins (`StorableLinkRoutingState`).
public struct LinkRoutingState: Codable, Equatable, Sendable {
    public var rules: [LinkRoutingRule]

    public init(rules: [LinkRoutingRule] = []) { self.rules = rules }

    public static let defaultsKey = "ReArcLinkRoutingRules"

    /// Rules whose space or profile still exists, so a deleted target never catches links.
    public func firstMatch(for url: URL, in store: SidebarStore) -> LinkRoutingRule? {
        rules.first { $0.matches(url) && Self.destinationExists($0.destination, in: store) }
    }

    public static func destinationExists(_ destination: LinkRoutingRule.Destination, in store: SidebarStore) -> Bool {
        switch destination {
        case .space(let id): return store.space(withID: id) != nil
        case .littleArc(let id): return store.profile(withID: id) != nil
        }
    }

    public static func load(from defaults: UserDefaults) -> LinkRoutingState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(LinkRoutingState.self, from: data) else { return LinkRoutingState() }
        return state
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public mutating func move(_ id: LinkRoutingRule.ID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), rules.count - 1)
        guard target != index else { return }
        rules.insert(rules.remove(at: index), at: target)
    }
}

extension ExternalLinkRouting {
    /// Where a route sends a link, in the settings' link tester's words.
    public static func describe(_ route: Route, in store: SidebarStore) -> String {
        switch route {
        case .littleArc(_, let profileID):
            return "Little ReArc (\(store.profile(withID: profileID)?.name ?? "profile"))"
        case .newTab(_, let spaceID):
            return "New tab in \(store.space(withID: spaceID)?.name ?? "a space")"
        case .focusTab(let id):
            return "The open tab “\(store.tab(withID: id)?.displayTitle ?? "tab")”"
        case .rejected:
            return "Not a web link: ReArc ignores it"
        }
    }

    /// The destination's name for menus.
    public static func describe(_ destination: LinkRoutingRule.Destination, in store: SidebarStore) -> String {
        switch destination {
        case .space(let id):
            guard let space = store.space(withID: id) else { return "Deleted space" }
            let owner = store.profile(withID: store.owningProfileID(of: space.profileID))
            let profile = store.listedProfiles.count > 1 ? owner.map { " (\($0.name))" } ?? "" : ""
            return space.name + profile + (store.isContainer(space.profileID) ? " · Container" : "")
        case .littleArc(let id):
            // A container's Little ReArc uses its session: named by its space.
            let name = store.isContainer(id) ? store.containerTitle(id) : store.profile(withID: id)?.name
            return "Little ReArc (\(name ?? "deleted profile"))"
        }
    }
}
