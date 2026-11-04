import Foundation
import SidebarModel

/// Media fields of a `ReArcServiceEvent` of kind 1, copied out of the callback.
struct ChromiumMediaSnapshot: Equatable {
    /// 0 playing, 1 paused, 2 stopped, 3 unknown.
    var playback: UInt32
    var audible: Bool
    var hasMetadata: Bool
    var title: String?
    var artist: String?
    var album: String?
    /// ABI 1.30 with a PiP callback registered; false otherwise.
    var pipAvailable = false
    var pipActive = false
    /// ABI 1.43 `ReArcTabGetMediaActions` bits; nil before (track buttons stay enabled).
    var actions: UInt32?
}

/// Maps engine media events onto `WebMediaState` (C-ABI.md "Services
/// functions and callbacks"): has_metadata=false leaves the previous metadata
/// untouched; has_metadata=true replaces title, artist and album together,
/// and an empty (or null) string clears that field.
enum ChromiumMediaMapping {
    static func apply(_ snapshot: ChromiumMediaSnapshot, to state: WebMediaState) -> WebMediaState {
        var next = state
        next.isPlaying = snapshot.playback == 0
        next.isPaused = snapshot.playback == 1
        if let actions = snapshot.actions {
            next.canPreviousTrack = actions & previousTrackBit != 0
            next.canNextTrack = actions & nextTrackBit != 0
        } else {
            // No availability before ABI 1.43: the engine rejects an unsupported skip itself.
            next.canPreviousTrack = true
            next.canNextTrack = true
        }
        next.isAudible = snapshot.audible
        // Real only while the shell's PiP callback is registered (ABI 1.30); false before.
        next.canPictureInPicture = snapshot.pipAvailable
        next.isPictureInPicture = snapshot.pipActive
        if snapshot.hasMetadata {
            next.title = nonEmpty(snapshot.title)
            next.artist = nonEmpty(snapshot.artist)
            next.album = nonEmpty(snapshot.album)
        }
        return next
    }

    /// `REARC_MEDIA_ACTION_PREVIOUS_TRACK` / `_NEXT_TRACK` (rearc_engine_abi.h).
    static let previousTrackBit: UInt32 = 1 << 2
    static let nextTrackBit: UInt32 = 1 << 3

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
