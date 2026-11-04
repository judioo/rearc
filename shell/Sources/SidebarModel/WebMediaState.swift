import Foundation

/// Per-tab media snapshot reported by the web engine (WKWebView probe or
/// Chromium media service events).
public struct WebMediaState: Equatable, Codable, Sendable {
    public var isPlaying: Bool
    public var isAudible: Bool
    public var title: String?
    public var artist: String?
    public var album: String?
    public var canPictureInPicture: Bool
    /// A video of this page plays in the Picture in Picture window.
    public var isPictureInPicture: Bool

    public init(
        isPlaying: Bool = false,
        isAudible: Bool = false,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        canPictureInPicture: Bool = false,
        isPictureInPicture: Bool = false
    ) {
        self.isPlaying = isPlaying
        self.isAudible = isAudible
        self.title = title
        self.artist = artist
        self.album = album
        self.canPictureInPicture = canPictureInPicture
        self.isPictureInPicture = isPictureInPicture
    }

    private enum CodingKeys: String, CodingKey {
        case isPlaying, isAudible, title, artist, album, canPictureInPicture, isPictureInPicture
    }

    /// Snapshots written before wave 24 have no `isPictureInPicture`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        isAudible = try c.decode(Bool.self, forKey: .isAudible)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        canPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .canPictureInPicture) ?? false
        isPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .isPictureInPicture) ?? false
    }

    public static let silent = WebMediaState()
}
