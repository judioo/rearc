import AppKit
import Foundation
import MediaPlayer
import SidebarModel

/// Routes macOS Now Playing / media-key events to the active tab engine.
/// WK-LIMIT: MPRemoteCommandCenter delivery varies by macOS version and sandbox;
/// the Chromium engine will own media keys in production.
protocol MediaKeyRouting: AnyObject {
    var onPlayPause: (() -> Void)? { get set }
    var onNext: (() -> Void)? { get set }
    var onPrevious: (() -> Void)? { get set }
    func updateNowPlaying(state: WebMediaState, tabTitle: String)
    func clearNowPlaying()
}

final class NowPlayingController: MediaKeyRouting {
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var registered = false

    init() {
        registerCommandsIfNeeded()
    }

    private func registerCommandsIfNeeded() {
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        }
    }

    func updateNowPlaying(state: WebMediaState, tabTitle: String) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = state.title ?? tabTitle
        if let artist = state.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
