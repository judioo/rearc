import Foundation

/// A tab's camera and microphone use, for Arc's call card (the Google Meet
/// card with camera and mic toggles). On Chromium it comes from
/// `ReArcEngineSetMediaCaptureCallback` (ABI 1.46, `media_capture`): whether
/// the page holds a live camera, microphone or screen-share stream
/// (Chromium's MediaStreamCaptureIndicator), and the page's own on/off report
/// for each device from its media session. WebKit reports nothing: `.idle`.
public struct MediaCaptureState: Equatable, Sendable {
    /// The page's report for one device (`navigator.mediaSession.setCameraActive`
    /// / `setMicrophoneActive`).
    public enum DeviceState: Equatable, Sendable {
        /// The page reports nothing.
        case unknown
        case on
        case off

        /// `REARC_CAPTURE_DEVICE_*`: 0 unknown, 1 on, 2 off; anything else unknown.
        public init(engineValue: UInt32) {
            switch engineValue {
            case 1: self = .on
            case 2: self = .off
            default: self = .unknown
            }
        }
    }

    public enum Device: UInt32, Equatable, Sendable {
        case camera = 0
        case microphone = 1
    }

    public var isCapturingVideo: Bool
    public var isCapturingAudio: Bool
    /// A screen, window or tab share.
    public var isCapturingDisplay: Bool
    public var camera: DeviceState
    public var microphone: DeviceState
    /// The page handles the "togglecamera" / "togglemicrophone" media session actions.
    public var canToggleCamera: Bool
    public var canToggleMicrophone: Bool

    public static let idle = MediaCaptureState()

    public init(isCapturingVideo: Bool = false, isCapturingAudio: Bool = false, isCapturingDisplay: Bool = false,
                camera: DeviceState = .unknown, microphone: DeviceState = .unknown,
                canToggleCamera: Bool = false, canToggleMicrophone: Bool = false) {
        self.isCapturingVideo = isCapturingVideo
        self.isCapturingAudio = isCapturingAudio
        self.isCapturingDisplay = isCapturingDisplay
        self.camera = camera
        self.microphone = microphone
        self.canToggleCamera = canToggleCamera
        self.canToggleMicrophone = canToggleMicrophone
    }

    /// The call card shows: the page uses the camera or microphone, or reports
    /// either (a call with both turned off still holds the card, as in Arc).
    public var isInCall: Bool {
        isCapturingVideo || isCapturingAudio || camera != .unknown || microphone != .unknown
    }

    /// A live camera or microphone stream: leaving the tab puts its video in
    /// Picture in Picture (Arc's Meet auto-PiP). Reports alone don't count.
    public var isCapturingCallMedia: Bool {
        isCapturingVideo || isCapturingAudio
    }

    /// A live capture always wins over the page's untrusted muted report.
    public func isOff(_ device: Device) -> Bool {
        if device == .camera ? isCapturingVideo : isCapturingAudio { return false }
        return switch state(of: device) {
        case .on: false
        case .off: true
        case .unknown: !(device == .camera ? isCapturingVideo : isCapturingAudio)
        }
    }

    /// The page reports the device off while its stream is still live.
    public func pageReportsOffWhileLive(_ device: Device) -> Bool {
        state(of: device) == .off && (device == .camera ? isCapturingVideo : isCapturingAudio)
    }

    /// The toggle works: the page handles the action and reports the state it flips.
    public func canToggle(_ device: Device) -> Bool {
        state(of: device) != .unknown && (device == .camera ? canToggleCamera : canToggleMicrophone)
    }

    public func state(of device: Device) -> DeviceState {
        device == .camera ? camera : microphone
    }

    /// What a toggle press asks for: `muted` for `ReArcTabSetCaptureMuted`, nil
    /// when the toggle does nothing.
    public func toggleRequest(_ device: Device) -> Bool? {
        canToggle(device) ? state(of: device) == .on : nil
    }
}
