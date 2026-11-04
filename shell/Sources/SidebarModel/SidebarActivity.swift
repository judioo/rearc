import Foundation

/// Per-window collapse of a space's Pinned section (Arc `expandPinnedSection`
/// / `collapsePinnedSection`, event `pinned_section_toggled`; SIDEBAR-SPEC
/// §3.1.3, §6). Each window keeps its own flag per space, like Arc's window
/// state; it is not saved, because ReArc does not restore windows yet.
public struct PinnedSectionCollapseState: Equatable {
    public struct Key: Hashable {
        public var window: SidebarWindowID?
        public var spaceID: Space.ID
    }

    public private(set) var collapsed: Set<Key> = []

    public init() {}

    public func isCollapsed(spaceID: Space.ID, window: SidebarWindowID?) -> Bool {
        collapsed.contains(Key(window: window, spaceID: spaceID))
    }

    public mutating func setCollapsed(_ isCollapsed: Bool, spaceID: Space.ID, window: SidebarWindowID?) {
        let key = Key(window: window, spaceID: spaceID)
        if isCollapsed { collapsed.insert(key) } else { collapsed.remove(key) }
    }

    public mutating func toggle(spaceID: Space.ID, window: SidebarWindowID?) {
        setCollapsed(!isCollapsed(spaceID: spaceID, window: window), spaceID: spaceID, window: window)
    }

    /// A closed window's flags go with it.
    public mutating func forgetWindow(_ window: SidebarWindowID) {
        collapsed = collapsed.filter { $0.window != window }
    }

    /// The pinned rows a section shows. Collapsed, it keeps only the selected
    /// item (a tab inside a folder comes out of it), as a collapsed folder does.
    public static func visibleEntries(_ pinned: [SidebarEntry], isCollapsed: Bool, selectedID: UUID?) -> [SidebarEntry] {
        guard isCollapsed else { return pinned }
        guard let selectedID, let leaf = SidebarTree.leaves(pinned).first(where: { $0.id == selectedID }) else { return [] }
        return [leaf]
    }
}

/// Copy URL formats (SIDEBAR-SPEC §4.9: plain, as Markdown, as Quote).
public enum PageLinkCopyFormat: String, CaseIterable, Sendable {
    case plain
    case markdown
    /// The page's selected text as a Markdown quote with its source link.
    case quote

    /// The text put on the pasteboard. `selection` is the page's selected
    /// text (only `quote` uses it); without one the quote is the link alone.
    public func text(url: URL, title: String, selection: String? = nil) -> String {
        switch self {
        case .plain:
            return url.absoluteString
        case .markdown:
            return Self.markdownLink(url: url, title: title)
        case .quote:
            let link = Self.markdownLink(url: url, title: title)
            let lines = (selection ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains(where: { !$0.isEmpty }) else { return "> \(link)" }
            let quoted = lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
            return "\(quoted)\n>\n> — \(link)"
        }
    }

    /// The confirmation toast.
    public var confirmation: String {
        switch self {
        case .plain: return "Copied URL"
        case .markdown: return "Copied URL as Markdown"
        case .quote: return "Copied as Quote"
        }
    }

    /// `[title](url)`, with the title's brackets and the URL's parentheses escaped.
    public static func markdownLink(url: URL, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
        let target = url.absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        return "[\(label)](\(target))"
    }
}

/// When a page's own activity marks its sidebar item unread (Arc
/// `isUnread`, SIDEBAR-SPEC §4.10): a pinned tab or favorite that is not on
/// screen changes its title after it finished loading (Gmail "(3) Inbox",
/// Slack, chat apps). Selecting the item clears the dot.
public enum UnreadActivityPolicy {
    /// Titles set while a page loads, or within this long after its last
    /// navigation, are the page settling, not new activity.
    public static let settleInterval: TimeInterval = 3

    public static func shouldMarkUnread(
        kind: Tab.Kind,
        isVisible: Bool,
        isLoading: Bool,
        secondsSinceNavigation: TimeInterval?,
        previousTitle: String?,
        newTitle: String?
    ) -> Bool {
        guard kind != .today, !isVisible, !isLoading else { return false }
        if let secondsSinceNavigation, secondsSinceNavigation < settleInterval { return false }
        let old = previousTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let new = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !old.isEmpty && !new.isEmpty && old != new
    }
}

/// What a tab's row and content area show about its page: loading (with
/// progress when the engine reports it) or a crashed renderer (Arc
/// `ARC_GlowProgressLoadingIndicator`, `ARC_SadTab`).
public enum TabActivity: Equatable, Sendable {
    case idle
    /// `progress` is 0…1, nil when unknown.
    case loading(progress: Double?)
    case crashed

    public init(isLoading: Bool, progress: Double?, isCrashed: Bool, isDiscarded: Bool = false) {
        if isCrashed {
            self = .crashed
        } else if isLoading, !isDiscarded {
            self = .loading(progress: progress.map { min(max($0, 0), 1) })
        } else {
            self = .idle
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The content bar's fill: never empty while loading, so it shows at once.
    public var barFraction: Double? {
        guard case .loading(let progress) = self else { return nil }
        return max(progress ?? 0.1, 0.1)
    }
}
