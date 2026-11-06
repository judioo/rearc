#if REARC_CHROMIUM
import AppKit
import ReArcEngine
import SidebarModel

/// Owned copy of `ReArcVideoOverlayEvent` (ABI 1.43, `pip_embedded`).
struct ChromiumVideoOverlayEvent {
    enum Kind: UInt32 {
        case created = 0, shown, hidden, closed, naturalSize, state, position, sourceTitle, firstFrame
    }

    var profileID, tabID, contentGeneration, overlayID: UInt64
    var kind: Kind
    /// `created` only: +1, released by the overlay after `closed`.
    var view: NSView?
    var width, height: Double
    var playback, buttons: UInt32
    var muted: Bool
    var duration, position, rate: Double
    var title: String
}

/// Context for one `ReArcVideoOverlayReadPixel`: +1 across the call, released by its callback.
final class PixelReadBox {
    let body: (UInt32?) -> Void
    init(_ body: @escaping (UInt32?) -> Void) { self.body = body }
}

/// One engine video overlay (`HostVideoOverlay`): the view Chromium renders
/// the tab's PiP video into, and the session state the engine reports. It
/// outlives sessions (shown → hidden → shown) until `closed`.
@Observable
final class ChromiumVideoOverlay: LiveVideoHandle {
    let overlayID: UInt64
    let tabID: UInt64
    let view: NSView
    private(set) var isShown = false
    private(set) var naturalSize: CGSize?
    /// 0 playing, 1 paused, 2 ended.
    private(set) var playback: UInt32 = 0
    private(set) var buttons: UInt32 = 0
    private(set) var isMuted = false
    private(set) var sourceTitle = ""
    private(set) var hasFirstFrame = false
    private(set) var duration: Double?
    @ObservationIgnored private var positionSample: (position: Double, rate: Double, at: Date)?
    @ObservationIgnored private var lastReportedFrame: CGRect?

    init(overlayID: UInt64, tabID: UInt64, view: NSView) {
        self.overlayID = overlayID
        self.tabID = tabID
        self.view = view
    }

    var isPlaying: Bool { playback == 0 }
    var hasEnded: Bool { playback == 2 }
    var canSkipTracks: (previous: Bool, next: Bool) {
        (buttons & UInt32(REARC_VIDEO_OVERLAY_BUTTON_PREVIOUS_TRACK) != 0,
         buttons & UInt32(REARC_VIDEO_OVERLAY_BUTTON_NEXT_TRACK) != 0)
    }
    var canHangUp: Bool { buttons & UInt32(REARC_VIDEO_OVERLAY_BUTTON_HANG_UP) != 0 }

    func position(at date: Date) -> Double? {
        guard let sample = positionSample else { return nil }
        let value = sample.position + sample.rate * date.timeIntervalSince(sample.at)
        return duration.map { min(max(0, value), $0) } ?? max(0, value)
    }

    func readPixel(_ completion: @escaping (UInt32?) -> Void) {
        let box = Unmanaged.passRetained(PixelReadBox(completion)).toOpaque()
        let status = ReArcVideoOverlayReadPixel(overlayID, { context, status, rgba in
            let box = Unmanaged<PixelReadBox>.fromOpaque(context!).takeRetainedValue()
            MainActor.assumeIsolated { box.body(status == .rearcOK ? rgba : nil) }
        }, box)
        if status != .rearcOK {
            Unmanaged<PixelReadBox>.fromOpaque(box).release()
            completion(nil)
        }
    }

    func perform(_ action: LiveVideoAction) {
        let status = ReArcVideoOverlayAction(overlayID, action.rawValue)
        if status != .rearcOK {
            ChromiumLog.info("video overlay \(overlayID) action \(action) rejected: \(status.rearcName)")
        }
    }

    func seek(to seconds: Double) {
        _ = ReArcVideoOverlaySeek(overlayID, seconds)
    }

    func reportScreenFrame(_ rect: CGRect) {
        guard rect.width >= 1, rect.height >= 1, rect != lastReportedFrame else { return }
        lastReportedFrame = rect
        _ = ReArcVideoOverlaySetBounds(overlayID, rect.minX, rect.minY, rect.width, rect.height)
    }

    /// Applies an event for this overlay; `created` and `closed` are the runtime's.
    func apply(_ event: ChromiumVideoOverlayEvent) {
        switch event.kind {
        case .shown:
            isShown = true
            hasFirstFrame = false
            lastReportedFrame = nil
        case .hidden:
            isShown = false
            hasFirstFrame = false
        case .naturalSize where event.width > 0 && event.height > 0:
            naturalSize = CGSize(width: event.width, height: event.height)
        case .state:
            playback = event.playback
            buttons = event.buttons
            isMuted = event.muted
        case .position:
            duration = event.duration >= 0 && event.duration.isFinite ? event.duration : nil
            positionSample = (event.position, event.rate, Date())
        case .sourceTitle:
            sourceTitle = event.title
        case .firstFrame:
            hasFirstFrame = true
        default:
            break
        }
    }
}

#endif
