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
}

/// Maps engine media events onto `WebMediaState` (C-ABI.md "Services
/// functions and callbacks"): has_metadata=false leaves the previous metadata
/// untouched; has_metadata=true replaces title, artist and album together,
/// and an empty (or null) string clears that field.
enum ChromiumMediaMapping {
    static func apply(_ snapshot: ChromiumMediaSnapshot, to state: WebMediaState) -> WebMediaState {
        var next = state
        next.isPlaying = snapshot.playback == 0
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
