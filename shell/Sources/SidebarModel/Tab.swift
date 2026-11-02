import Foundation

/// A single browser tab. Tabs come in three kinds, which determines where in
/// the sidebar they live and how they behave:
/// - `favorite`: global icon row at the top of the sidebar, no close button.
/// - `pinned`: per-space section, text row, persists across sessions.
/// - `today`: per-space unpinned section, ephemeral browsing.
public struct Tab: Identifiable, Hashable, Codable {
    public enum Kind: String, CaseIterable, Codable {
        case favorite
        case pinned
        case today
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var url: URL
    /// Placeholder glyph standing in for a real favicon until the engine
    /// layer can fetch site icons. Derived from the URL host by default.
    public var faviconToken: String
    /// True when the tab has new activity the user hasn't seen yet.
    public var isUnread: Bool
    /// LexoRank fractional position for sync ordering (empty until migrated).
    public var sortRank: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        url: URL,
        faviconToken: String? = nil,
        isUnread: Bool = false,
        sortRank: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.faviconToken = faviconToken ?? Tab.makeFaviconToken(for: url)
        self.isUnread = isUnread
        self.sortRank = sortRank
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, url, faviconToken, isUnread, sortRank
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
    }

    public static func makeFaviconToken(for url: URL) -> String {
        guard let host = url.host() else { return "•" }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let first = stripped.first else { return "•" }
        return String(first).uppercased()
    }
}
