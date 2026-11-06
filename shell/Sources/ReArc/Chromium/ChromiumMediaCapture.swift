#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Media capture per tab (ABI 1.46 `media_capture`, C-ABI.md "Media capture
// and search engines (1.46)"): the call card's camera and microphone. The
// callback is registered at ready, before any tab, so every change arrives
// as an event; mute goes through the page's own media session handlers.

/// Owned copy of `ReArcMediaCaptureState`.
struct ChromiumMediaCaptureEvent: Equatable {
    var profileID: UInt64
    var tabID: UInt64
    var contentGeneration: UInt64
    var state: MediaCaptureState

    init(_ e: ReArcMediaCaptureState) {
        profileID = e.profile_id
        tabID = e.tab_id
        contentGeneration = e.content_generation
        state = MediaCaptureState(
            isCapturingVideo: e.capturing_video, isCapturingAudio: e.capturing_audio,
            isCapturingDisplay: e.capturing_display,
            camera: .init(engineValue: e.camera), microphone: .init(engineValue: e.microphone),
            canToggleCamera: e.can_toggle_camera, canToggleMicrophone: e.can_toggle_microphone)
    }
}

private let mediaCaptureCallback: ReArcMediaCaptureCallback = { context, state in
    guard let context, let e = state?.pointee else { return }
    let copied = ChromiumMediaCaptureEvent(e)
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().handleMediaCapture(copied)
    }
}

extension ChromiumRuntime {
    /// Registered at `ready`, before any tab exists.
    func registerMediaCaptureChannel(context: UnsafeMutableRawPointer) {
        if capabilities.mediaCapture { ReArcEngineSetMediaCaptureCallback(mediaCaptureCallback, context) }
    }

    fileprivate func handleMediaCapture(_ event: ChromiumMediaCaptureEvent) {
        let s = event.state
        ChromiumLog.info("media_capture tab \(event.tabID) video \(s.isCapturingVideo) audio \(s.isCapturingAudio) "
            + "display \(s.isCapturingDisplay) camera \(s.camera) microphone \(s.microphone) "
            + "toggles \(s.canToggleCamera)/\(s.canToggleMicrophone)")
        engine(forTab: event.tabID)?.handleMediaCapture(event)
    }
}

#endif
