import XCTest
@testable import SidebarModel

/// ABI 1.46 `media_capture`: the call card's camera and microphone state.
final class MediaCaptureStateTests: XCTestCase {
    /// A conferencing page in a call: camera and mic live, both reported, both toggleable.
    private let meet = MediaCaptureState(isCapturingVideo: true, isCapturingAudio: true, camera: .on, microphone: .on,
                                         canToggleCamera: true, canToggleMicrophone: true)

    func testEngineDeviceValuesMapAndUnknownValuesStayUnknown() {
        XCTAssertEqual(MediaCaptureState.DeviceState(engineValue: 0), .unknown)
        XCTAssertEqual(MediaCaptureState.DeviceState(engineValue: 1), .on)
        XCTAssertEqual(MediaCaptureState.DeviceState(engineValue: 2), .off)
        XCTAssertEqual(MediaCaptureState.DeviceState(engineValue: 7), .unknown, "a later engine's value")
        XCTAssertEqual(MediaCaptureState.Device.camera.rawValue, 0, "ReArcTabSetCaptureMuted device 0")
        XCTAssertEqual(MediaCaptureState.Device.microphone.rawValue, 1)
    }

    func testIdleIsNoCall() {
        XCTAssertFalse(MediaCaptureState.idle.isInCall)
        XCTAssertEqual(MediaCaptureState(), .idle)
        XCTAssertFalse(MediaCaptureState(isCapturingDisplay: true).isInCall, "a screen share alone is not a call")
    }

    func testACallWithBothDevicesOffStillShowsTheCard() {
        XCTAssertTrue(MediaCaptureState(isCapturingAudio: true).isInCall)
        XCTAssertTrue(MediaCaptureState(isCapturingVideo: true).isInCall)
        // A page may stop both streams and keep reporting the devices off.
        XCTAssertTrue(MediaCaptureState(camera: .off, microphone: .off).isInCall)
    }

    func testLiveCaptureWinsOverThePageReport() {
        var state = meet
        state.microphone = .off
        XCTAssertFalse(state.isOff(.microphone), "a page cannot hide live capture with its muted report")
        XCTAssertTrue(state.pageReportsOffWhileLive(.microphone))
        XCTAssertFalse(meet.pageReportsOffWhileLive(.microphone))
        state.camera = .off
        XCTAssertFalse(state.isOff(.camera))
        state.isCapturingVideo = false
        XCTAssertTrue(state.isOff(.camera))
    }

    func testWithoutAReportTheStreamDecides() {
        let state = MediaCaptureState(isCapturingAudio: true)
        XCTAssertFalse(state.isOff(.microphone))
        XCTAssertTrue(state.isOff(.camera), "no camera stream")
    }

    func testTogglesNeedTheActionAndAReportedState() {
        XCTAssertTrue(meet.canToggle(.camera))
        XCTAssertTrue(meet.canToggle(.microphone))
        XCTAssertFalse(MediaCaptureState(isCapturingVideo: true, isCapturingAudio: true).canToggle(.camera),
                       "a page without media session handlers: the engine cannot mute it")
        XCTAssertFalse(MediaCaptureState(isCapturingAudio: true, canToggleMicrophone: true).canToggle(.microphone),
                       "handler but no reported state: engine invalid_state")
        XCTAssertFalse(MediaCaptureState(microphone: .on, canToggleCamera: true).canToggle(.microphone))
    }

    func testAToggleStillUsesThePagesReportedState() {
        XCTAssertEqual(meet.toggleRequest(.camera), true, "on: mute")
        var muted = meet
        muted.microphone = .off
        XCTAssertEqual(muted.toggleRequest(.microphone), false, "off: unmute")
        XCTAssertNil(MediaCaptureState(isCapturingAudio: true).toggleRequest(.microphone))
    }
}
