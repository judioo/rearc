import Foundation

/// Per-tab media snapshot reported by the web engine (WKWebView probe or
/// Chromium media service events).
public struct WebMediaState: Equatable, Codable, Sendable {
    public var isPlaying: Bool
    /// The page's media session is paused, not ended: Arc keeps its strip.
    public var isPaused: Bool
    public var isAudible: Bool
    public var title: String?
    public var artist: String?
    public var album: String?
    public var canPictureInPicture: Bool
    /// A video of this page plays in the Picture in Picture window.
    public var isPictureInPicture: Bool
    /// The page's media session offers previous / next track (Arc's
    /// `hasPreviousTrack` / `hasNextTrack`); the strip dims the button otherwise.
    public var canPreviousTrack: Bool
    public var canNextTrack: Bool
    /// The PiP video renders in a ReArc view (Chromium `pip_embedded`), not a system window.
    public var hasLiveVideo: Bool

    /// A live media session: playing, paused or still making sound.
    public var hasSession: Bool { isPlaying || isPaused || isAudible }

    public init(
        isPlaying: Bool = false,
        isPaused: Bool = false,
        isAudible: Bool = false,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        canPictureInPicture: Bool = false,
        isPictureInPicture: Bool = false,
        canPreviousTrack: Bool = false,
        canNextTrack: Bool = false,
        hasLiveVideo: Bool = false
    ) {
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.isAudible = isAudible
        self.title = title
        self.artist = artist
        self.album = album
        self.canPictureInPicture = canPictureInPicture
        self.isPictureInPicture = isPictureInPicture
        self.canPreviousTrack = canPreviousTrack
        self.canNextTrack = canNextTrack
        self.hasLiveVideo = hasLiveVideo
    }

    private enum CodingKeys: String, CodingKey {
        case isPlaying, isPaused, isAudible, title, artist, album, canPictureInPicture, isPictureInPicture
        case canPreviousTrack, canNextTrack, hasLiveVideo
    }

    /// Snapshots written before wave 24 have no `isPictureInPicture`, and
    /// before wave 32 none of `isPaused`, the track flags or `hasLiveVideo`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        isAudible = try c.decode(Bool.self, forKey: .isAudible)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        canPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .canPictureInPicture) ?? false
        isPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .isPictureInPicture) ?? false
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        canPreviousTrack = try c.decodeIfPresent(Bool.self, forKey: .canPreviousTrack) ?? false
        canNextTrack = try c.decodeIfPresent(Bool.self, forKey: .canNextTrack) ?? false
        hasLiveVideo = try c.decodeIfPresent(Bool.self, forKey: .hasLiveVideo) ?? false
    }

    public static let silent = WebMediaState()
}
