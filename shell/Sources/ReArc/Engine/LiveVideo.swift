import AppKit

/// `ReArcVideoOverlayAction` actions (ABI 1.43, `pip_embedded`).
enum LiveVideoAction: UInt32 {
    case togglePlayPause = 0, nextTrack, previousTrack, skipAd
    case toggleMicrophone, toggleCamera, hangUp
    /// Ends the session and shows the tab (PiP phase 2 follows).
    case backToTab
    case close, closeAndPause, play, pause, mute, unmute
}

/// A tab's Picture in Picture video, rendered by the engine into a view the
/// shell places (Chromium's video-PiP surface, MINI-PLAYER.md option b). The
/// same view moves between the sidebar card and the floating panel. Main thread only.
protocol LiveVideoHandle: AnyObject {
    var overlayID: UInt64 { get }
    var view: NSView { get }
    /// Video pixels; nil until the engine reports them.
    var naturalSize: CGSize? { get }
    var isPlaying: Bool { get }
    var hasEnded: Bool { get }
    var isMuted: Bool { get }
    var canSkipTracks: (previous: Bool, next: Bool) { get }
    /// Seconds; nil without a position (or a live stream).
    var duration: Double? { get }
    func position(at date: Date) -> Double?
    /// The first frame arrived since the session started.
    var hasFirstFrame: Bool { get }
    /// The centre pixel of the composited view as 0xRRGGBBAA, nil when it is
    /// not drawing (self-test, diagnostics). Asynchronous; main thread.
    func readPixel(_ completion: @escaping (UInt32?) -> Void)
    func perform(_ action: LiveVideoAction)
    func seek(to seconds: Double)
    /// The view's rect in screen points, top-left origin (sizes the decoded video).
    func reportScreenFrame(_ rect: CGRect)
}

/// Engines whose PiP video plays in a shell view (Chromium `pip_embedded`).
protocol LiveVideoProviding: AnyObject {
    var liveVideo: (any LiveVideoHandle)? { get }
}
