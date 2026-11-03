import Foundation

/// A single browser tab. Tabs come in three kinds, which determines where in
/// the sidebar they live and how they behave:
/// - `favorite`: per-profile icon row at the top of the sidebar, shared by the
///   profile's spaces; Cmd+W unloads it instead of deleting it.
/// - `pinned`: per-space section (folders included), text row, persists across
///   sessions. It keeps the URL it was pinned at (`savedURL`); Cmd+W unloads it
///   back to that URL instead of deleting it.
/// - `today`: per-space unpinned section, ephemeral browsing.
public struct Tab: Identifiable, Hashable, Codable {
    public enum Kind: String, CaseIterable, Codable {
        case favorite
        case pinned
        case today
    }

    public let id: UUID
    public var kind: Kind
    /// Page title, updated on every navigation.
    public var title: String
    /// User rename (Arc "Rename Current Item"); survives page title changes.
    public var customTitle: String?
    public var url: URL
    /// Letter glyph drawn when the shell has no site icon for this tab yet.
    /// Real icons come from the engine (Chromium `ReArcFaviconGet`, WebKit
    /// page `<link rel=icon>`) via the shell's favicon cache. Derived from the URL host.
    public var faviconToken: String
    /// True when the tab has new activity the user hasn't seen yet. Only ever
    /// cleared today; nothing sets it (no background-activity source yet).
    public var isUnread: Bool
    /// LexoRank fractional position for sync ordering (empty until migrated).
    public var sortRank: String
    /// Last time the tab was selected; drives Today-tab auto-archive. Nil on
    /// tabs saved before schema 10 (the store stamps them at load).
    public var lastActiveAt: Date?
    /// A pinned tab's original URL and title (Arc "Reset Tab to Original URL").
    /// Set when the tab becomes pinned, cleared when it leaves Pinned.
    public var savedURL: URL?
    public var savedTitle: String?

    /// A pinned tab that navigated away from the URL it was pinned at.
    public var isAwayFromSavedURL: Bool {
        guard kind == .pinned, let savedURL else { return false }
        return savedURL.absoluteString != url.absoluteString
    }

    /// Changes the kind, keeping `savedURL` in step: becoming pinned saves the
    /// current URL (unless one is saved), anything else forgets it.
    public mutating func setKind(_ newKind: Kind) {
        kind = newKind
        if newKind == .pinned {
            if savedURL == nil {
                savedURL = url
                savedTitle = title
            }
        } else {
            savedURL = nil
            savedTitle = nil
        }
    }

    /// The title the sidebar shows.
    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return title
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        url: URL,
        faviconToken: String? = nil,
        isUnread: Bool = false,
        sortRank: String = "",
        customTitle: String? = nil,
        lastActiveAt: Date? = Date(),
        savedURL: URL? = nil,
        savedTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.customTitle = customTitle
        self.url = url
        self.faviconToken = faviconToken ?? Tab.makeFaviconToken(for: url)
        self.isUnread = isUnread
        self.sortRank = sortRank
        self.lastActiveAt = lastActiveAt
        if kind == .pinned {
            self.savedURL = savedURL ?? url
            self.savedTitle = savedTitle ?? title
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, customTitle, url, faviconToken, isUnread, sortRank, lastActiveAt, savedURL, savedTitle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        faviconToken = try c.decodeIfPresent(String.self, forKey: .faviconToken)
            ?? Tab.makeFaviconToken(for: url)
        isUnread = try c.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank) ?? ""
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        if kind == .pinned {
            // Pinned tabs saved before wave 19 keep the URL they had.
            savedURL = try c.decodeIfPresent(URL.self, forKey: .savedURL) ?? url
            savedTitle = try c.decodeIfPresent(String.self, forKey: .savedTitle) ?? title
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(faviconToken, forKey: .faviconToken)
        try c.encode(isUnread, forKey: .isUnread)
        try c.encode(sortRank, forKey: .sortRank)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
        try c.encodeIfPresent(savedURL, forKey: .savedURL)
        try c.encodeIfPresent(savedTitle, forKey: .savedTitle)
    }

    public static func makeFaviconToken(for url: URL) -> String {
        guard let host = url.host() else { return "•" }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let first = stripped.first else { return "•" }
        return String(first).uppercased()
    }
}
