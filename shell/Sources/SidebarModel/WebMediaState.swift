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

    public init(
        isPlaying: Bool = false,
        isAudible: Bool = false,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        canPictureInPicture: Bool = false
    ) {
        self.isPlaying = isPlaying
        self.isAudible = isAudible
        self.title = title
        self.artist = artist
        self.album = album
        self.canPictureInPicture = canPictureInPicture
    }

    public static let silent = WebMediaState()
}
